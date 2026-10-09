import AppKit
import Observation

enum StepStatus { case done, attention, current, pending }

/// Everything the window shows: live checks of this Mac and the iPad, what the
/// user set up, and the job that is running.
@MainActor @Observable
final class SetupModel {
    var state = SetupState.load() { didSet { if state != oldValue { state.save() } } }
    var selection: SetupStep = .welcome

    // Source and profiles
    var source: SourceTree?
    var sourceError: String?
    var profiles: [AppProfile] = []
    var profileProblems: [String] = []

    // Membership
    var teams: [DeveloperTeam] = []
    var scannedTeams = false

    // This Mac
    var xcode: XcodeInstallation?
    var xcodeReady: Bool?
    var sdkVersion: String?
    var python: String?
    var xcodegen: String?
    var freeSpace: Int64?
    var checkedMac = false

    // iPad
    var devices: [Device] = []
    var deviceError: String?
    var scannedDevices = false
    var tolkaraOnDevice: Bool?
    /// Tolkara installed on the device under another bundle ID (by hand, say).
    var otherTolkara: [String] = []
    var profileExpiry: Date?

    // Library: what Tolkara has on the device
    var library: DeviceLibrary?
    var libraryError: String?
    var readingLibrary = false

    // Jobs
    var job: Job?
    var lastJobs: [Job.Kind: Job] = [:]

    var update: (version: String, url: URL)?

    init() {
        if state.welcomed { selection = firstIncompleteStep }
    }

    /// "iPad" or "iPhone": what the user connected, in the words of every page.
    var deviceWord: String { selectedDevice?.type ?? state.deviceType ?? "iPad" }
    var deviceName: String { selectedDevice?.name ?? state.deviceName ?? "your \(deviceWord)" }

    // MARK: Derived state

    var selectedDevice: Device? { devices.first { $0.id == state.device } }
    var chosenProfiles: [AppProfile] { state.profiles.compactMap { id in profiles.first { $0.id == id } } }
    /// The games this app sets up, the one most people come for first.
    var setupProfiles: [AppProfile] {
        profiles.filter { $0.hasSetup || $0.isImported }.sorted { ($0.id == "wow-forever" ? 0 : 1) < ($1.id == "wow-forever" ? 0 : 1) }
    }
    var commandLineProfiles: [AppProfile] { profiles.filter { !$0.hasSetup && !$0.isImported } }

    func sourceFolder(for profile: AppProfile) -> URL? {
        (state.sources[profile.id] ?? profile.source).map { URL(fileURLWithPath: $0) }
    }

    func executableFound(for profile: AppProfile) -> Bool {
        guard let folder = sourceFolder(for: profile) else { return false }
        return FileManager.default.isExecutableFile(atPath: profile.executable(inSource: folder).path)
    }

    func riskAccepted(_ profile: AppProfile) -> Bool {
        guard let risk = profile.risk else { return true }
        return state.riskAccepted[profile.id]?.digest == risk.digest
    }

    func isReady(_ profile: AppProfile) -> Bool { executableFound(for: profile) && riskAccepted(profile) }

    var installIsCurrent: Bool {
        guard let installed = state.installed, let source, let team = state.team, let device = state.device else { return false }
        return installed.commit == source.identity && installed.team == team.id && installed.bundleID == state.effectiveBundleID
            && installed.device == device && Set(installed.profiles).isSuperset(of: state.profiles)
    }

    var enrolmentIsCurrent: Bool {
        guard let enrolled = state.enrolled else { return false }
        return enrolled.device == state.device && enrolled.bundleID == state.effectiveBundleID
    }

    func copyIsCurrent(_ profile: AppProfile) -> Bool {
        guard let copy = state.copied[profile.id] else { return false }
        return copy.device == state.device && copy.bundleID == state.effectiveBundleID && copy.source == sourceFolder(for: profile)?.path
    }

    func isComplete(_ step: SetupStep) -> Bool {
        switch step {
        case .welcome: return state.welcomed
        case .membership: return state.team.map { $0.kind == .paid || $0.kind == .unknown } ?? false
        case .mac: return xcode != nil && xcodeReady == true && xcodegen != nil && python != nil
        case .iPad:
            guard let device = selectedDevice else { return false }
            return device.available && device.paired && device.developerMode == true
        case .game: return !chosenProfiles.isEmpty && chosenProfiles.allSatisfy(isReady)
        case .install: return installIsCurrent && enrolmentIsCurrent
        case .copy: return !chosenProfiles.isEmpty && chosenProfiles.allSatisfy(copyIsCurrent)
        case .play, .library: return false
        }
    }

    /// A step can be opened once every step before it is complete.
    func isReachable(_ step: SetupStep) -> Bool {
        if step == .library { return state.welcomed }
        return SetupStep.setup.prefix { $0 != step }.allSatisfy(isComplete)
    }

    var firstIncompleteStep: SetupStep {
        // Once everything is set up, the app opens on the library.
        SetupStep.setup.first { !isComplete($0) && $0 != .play } ?? .library
    }

    func status(_ step: SetupStep) -> StepStatus {
        if step == .play || step == .library { return isReachable(step) ? .current : .pending }
        if isComplete(step) { return .done }
        if !isReachable(step) { return .pending }
        return attentionNeeded(step) ? .attention : .current
    }

    private func attentionNeeded(_ step: SetupStep) -> Bool {
        switch step {
        case .membership: return scannedTeams && state.team?.kind != .paid && !teams.contains { $0.kind == .paid }
        case .mac: return checkedMac
        case .iPad: return scannedDevices
        default: return lastFailedJob(for: step) != nil
        }
    }

    private func lastFailedJob(for step: SetupStep) -> Job? {
        lastJobs.values.first { job in
            guard job.failure != nil else { return false }
            switch (job.kind, step) {
            case (.install, .install), (.copy, .copy): return true
            default: return false
            }
        }
    }

    var next: SetupStep? {
        guard let index = SetupStep.setup.firstIndex(of: selection), index + 1 < SetupStep.setup.count else { return nil }
        return SetupStep.setup[index + 1]
    }

    var previous: SetupStep? {
        guard let index = SetupStep.setup.firstIndex(of: selection), index > 0 else { return nil }
        return SetupStep.setup[index - 1]
    }

    func goNext() {
        if selection == .welcome { state.welcomed = true }
        if let next, isComplete(selection) { selection = next }
    }

    // MARK: Checks

    func refreshAll() async {
        await prepareSource()
        scanMembership()
        await checkMac()
        await refreshDevices()
        await checkTolkaraOnDevice()
        if selection == .library { await readLibrary() }
    }

    func prepareSource() async {
        do {
            source = try await Workspace.prepare(overridePath: state.sourceOverride)
            sourceError = nil
        } catch {
            source = nil
            sourceError = error.localizedDescription
        }
        reloadProfiles()
    }

    func reloadProfiles() {
        let catalog = ProfileParser.catalog(source: source?.root)
        profiles = catalog.profiles
        profileProblems = catalog.problems
        state.profiles.removeAll { id in !profiles.contains { $0.id == id } }
    }

    func scanMembership() {
        teams = MembershipScanner.scan()
        if let team = state.team, let bundleID = state.effectiveBundleID {
            profileExpiry = MembershipScanner.expiry(team: team.id, bundleID: bundleID, in: MembershipScanner.provisioningProfiles())
        }
        scannedTeams = true
        // Keep the chosen team current; choose the only paid team by itself.
        if let chosen = state.team, let fresh = teams.first(where: { $0.id == chosen.id }) {
            if chosen.kind != .unknown || fresh.kind != .unknown { state.team = fresh }
        } else if state.team == nil, let paid = teams.filter({ $0.kind == .paid }).first, teams.filter({ $0.kind == .paid }).count == 1 {
            state.team = paid
        }
    }

    func chooseTeam(_ team: DeveloperTeam) { state.team = team }

    /// A team ID typed in by the user, checked for real by the first build.
    func enterTeam(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces).uppercased()
        guard id.wholeMatch(of: MembershipScanner.teamID) != nil else { return }
        state.team = teams.first { $0.id == id } ?? DeveloperTeam(id: id, name: "Team \(id)", kind: .unknown, evidence: "Entered by you")
    }

    func checkMac() async {
        xcode = Toolchain.findXcode()
        xcodegen = Toolchain.xcodegen
        freeSpace = Toolchain.freeSpace(at: AppPaths.support)
        if let xcode {
            xcodeReady = await Toolchain.firstLaunchDone(xcode)
            sdkVersion = await Toolchain.iosSDKVersion(xcode)
        } else {
            xcodeReady = nil
            sdkVersion = nil
        }
        python = await Toolchain.pythonVersion(xcode)
        checkedMac = true
    }

    func refreshDevices() async {
        guard let xcode else {
            devices = []
            deviceError = "Xcode is needed to talk to your \(deviceWord)."
            return
        }
        do {
            devices = try await Devices.list(xcode: xcode)
            deviceError = nil
        } catch {
            deviceError = error.localizedDescription
        }
        scannedDevices = true
        if state.device == nil || !devices.contains(where: { $0.id == state.device }),
           let only = devices.filter({ $0.available }).first, devices.filter({ $0.available }).count == 1 {
            if state.device == nil { chooseDevice(only) }
        }
        if let device = selectedDevice { state.deviceName = device.name; state.deviceType = device.type }
    }

    func chooseDevice(_ device: Device) {
        state.device = device.id
        state.deviceName = device.name
        state.deviceType = device.type
        tolkaraOnDevice = nil
        library = nil
    }

    func checkTolkaraOnDevice() async {
        guard let xcode, let device = selectedDevice, device.available, device.paired, let bundleID = state.effectiveBundleID else { return }
        let installs = await Devices.tolkaraInstalls(on: device, xcode: xcode)
        tolkaraOnDevice = installs.contains(bundleID) ? true : await Devices.isInstalled(bundleID: bundleID, on: device, xcode: xcode)
        otherTolkara = installs.filter { $0 != bundleID }
    }

    /// Manage the Tolkara already on the device: its games, enrolment and
    /// settings stay. The next build installs over it under the same ID.
    func adoptTolkara(_ bundleID: String) {
        state.bundleID = bundleID
        otherTolkara.removeAll { $0 == bundleID }
        tolkaraOnDevice = true
        library = nil
        Task { await readLibrary() }
    }

    /// iPadOS on the device must not be newer than the SDK Xcode builds with.
    var xcodeTooOldForDevice: Bool {
        guard let device = selectedDevice, let sdk = sdkVersion, let major = Int(sdk.split(separator: ".").first ?? "") else { return false }
        return device.osMajor > major
    }

    // MARK: Games

    func toggle(_ profile: AppProfile) {
        if let index = state.profiles.firstIndex(of: profile.id) { state.profiles.remove(at: index) }
        else { state.profiles.append(profile.id) }
    }

    func acceptRisk(_ profile: AppProfile) {
        guard let risk = profile.risk else { return }
        state.riskAccepted[profile.id] = .init(digest: risk.digest, date: Date())
        if !state.profiles.contains(profile.id) { state.profiles.append(profile.id) }
    }

    func setSource(_ url: URL, for profile: AppProfile) {
        // Accept the folder itself, or a folder inside it that holds the executable.
        var folder = url
        if !FileManager.default.isExecutableFile(atPath: profile.executable(inSource: folder).path) {
            var candidate = url
            while candidate.path != "/" {
                if FileManager.default.isExecutableFile(atPath: profile.executable(inSource: candidate).path) { folder = candidate; break }
                candidate.deleteLastPathComponent()
            }
        }
        state.sources[profile.id] = folder.path
    }

    func importProfile(data: Data) throws -> AppProfile {
        let probe = try ProfileParser.parse(data, origin: .imported(file: URL(fileURLWithPath: "/")))
        if let existing = profiles.first(where: { $0.id == probe.id }), !existing.isImported {
            throw ProfileError(message: "Tolkara already includes a profile for “\(existing.name)”.")
        }
        let profile = try ProfileParser.importProfile(data)
        reloadProfiles()
        return profile
    }

    func removeImported(_ profile: AppProfile) {
        guard case .imported(let file) = profile.origin else { return }
        try? FileManager.default.removeItem(at: file)
        state.profiles.removeAll { $0 == profile.id }
        reloadProfiles()
    }

    // MARK: Jobs

    private func start(_ kind: Job.Kind, title: String, phase: String,
                       _ work: @escaping @MainActor (Job) async throws -> Void) {
        guard job?.isRunning != true else { return }
        let job = Job(kind: kind, title: title, phase: phase)
        self.job = job
        lastJobs[kind] = job
        job.task = Task { @MainActor in
            do {
                try await work(job)
            } catch is CancellationError {
                job.failure = "Stopped."
            } catch {
                job.failure = error.localizedDescription
                job.diagnosis = Diagnoser.diagnose(job.output + "\n" + error.localizedDescription, source: source?.root)
            }
            if Task.isCancelled && job.failure == nil { job.failure = "Stopped." }
            job.finished = Date()
            job.hint = nil
            job.detail = nil
            if self.job === job { self.job = nil }
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func cancelJob() { job?.task?.cancel() }

    func installXcodegen() {
        start(.xcodegen, title: "Installing XcodeGen", phase: "Installing XcodeGen…") { job in
            try await Toolchain.installXcodegen(line: job.sink())
            await self.checkMac()
        }
    }

    func pair(_ device: Device) {
        guard let xcode else { return }
        start(.pair, title: "Pairing", phase: "Waiting for you to tap Trust on \(device.name)…") { job in
            job.hint = "Unlock your \(device.type) and tap Trust, then enter its passcode."
            try await Devices.pair(device, xcode: xcode)
            await self.refreshDevices()
        }
    }

    /// local.env for the current choices; nil with a reason when something is missing.
    func environmentValues() throws -> LocalEnv.Values {
        guard let team = state.team else { throw ProfileError(message: "Choose your developer team first.") }
        guard let bundleID = state.effectiveBundleID else { throw ProfileError(message: "No app identifier.") }
        guard let device = state.device else { throw ProfileError(message: "Choose your \(deviceWord) first.") }
        let chosen = chosenProfiles
        let executables = try chosen.map { profile -> String in
            guard let folder = sourceFolder(for: profile) else { throw ProfileError(message: "Choose where “\(profile.name)” is on this Mac.") }
            return profile.executable(inSource: folder).path
        }
        let own = chosen.filter(\.isImported).map(\.profileFile.path)
        return .init(team: team.id, bundleID: bundleID, device: device, executables: executables, ownProfiles: own)
    }

    func installTolkara(force: Bool = false) {
        start(.install, title: "Installing Tolkara", phase: "Preparing…") { job in
            try await self.performInstall(job, force: force)
            job.phase = "Tolkara is installed and ready."
        }
    }

    /// Builds and installs when the build is not current (or `force`), then
    /// enrols once. Shared by the Install step and game updates.
    private func performInstall(_ job: Job, force: Bool) async throws {
        guard let xcode else { throw ProfileError(message: "Xcode is needed.") }
        if source == nil { await prepareSource() }
        guard let source else { throw ProfileError(message: sourceError ?? "No Tolkara source.") }
        let values = try environmentValues()
        try LocalEnv.write(values, to: source)
        let environment = Toolchain.environment(xcode: xcode)
        let script = { (name: String) in source.root.appendingPathComponent("tools/\(name)").path }

        if force || !installIsCurrent {
            job.phase = "Building Tolkara for your \(deviceWord)…"
            job.hint = "The first build takes a while. Keep your \(deviceWord) connected and unlocked."
            let started = Date()
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if let activity = BuildActivity.current(logs: source.root.appendingPathComponent("logs"), since: started) {
                        job.detail = activity
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { watcher.cancel() }
            let sink = job.sink()
            let word = deviceWord
            try await Shell.check("/bin/bash", [script("install.sh")], environment: environment, directory: source.root) { line in
                sink(line)
                if line.contains("App installed") || line.hasPrefix("Installed") {
                    DispatchQueue.main.async { MainActor.assumeIsolated { job.phase = "Installed on your \(word)."; job.detail = nil } }
                }
            }
            watcher.cancel()
            let executables = await hashes(of: chosenProfiles)
            state.installed = .init(commit: source.identity, team: values.team, bundleID: values.bundleID, device: values.device,
                                    profiles: state.profiles, date: Date(), executables: executables)
            // The build proved the membership; remember it.
            if var team = state.team, team.kind == .unknown { team.kind = .paid; team.evidence = "Built Tolkara"; state.team = team }
        }
        if !enrolmentIsCurrent {
            job.phase = "Connecting Tolkara to your \(deviceWord)'s developer service…"
            job.hint = "Unlock your \(deviceWord). If it asks for permission, allow it."
            job.detail = nil
            try await Shell.check("/bin/bash", [script("enroll.sh")], environment: environment, directory: source.root, line: job.sink())
            state.enrolled = .init(bundleID: values.bundleID, device: values.device, date: Date())
        }
        tolkaraOnDevice = true
        scanMembership()
    }

    /// SHA-256 of each game's executable on this Mac.
    private func hashes(of profiles: [AppProfile]) async -> [String: String] {
        let files = profiles.compactMap { profile in sourceFolder(for: profile).map { (profile.id, profile.executable(inSource: $0)) } }
        return await Task.detached(priority: .userInitiated) {
            Dictionary(files.compactMap { id, url in FileHash.sha256(url).map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        }.value
    }

    func copy(_ profile: AppProfile) {
        start(.copy(profile.id), title: "Copying \(profile.name)", phase: "Preparing…") { job in
            try await self.performCopy(profile, job: job)
            job.phase = "\(profile.name) is on your \(self.deviceWord)."
        }
    }

    private func performCopy(_ profile: AppProfile, job: Job) async throws {
        guard let xcode else { throw ProfileError(message: "Xcode is needed.") }
        guard let source else { throw ProfileError(message: sourceError ?? "No Tolkara source.") }
        guard let folder = sourceFolder(for: profile), executableFound(for: profile) else {
            throw ProfileError(message: "“\(profile.name)” was not found on this Mac.")
        }
        let values = try environmentValues()
        try LocalEnv.write(values, to: source)
        guard let device = selectedDevice else { throw ProfileError(message: "Connect your \(deviceWord).") }
        job.phase = "Copying \(profile.name) to \(device.name)…"
        job.hint = device.wired ? "Keep your \(deviceWord) connected and unlocked. Files that did not change are skipped."
            : "This is much faster over a cable. Keep your \(deviceWord) unlocked."
        if let installer = profile.installerURL {
            try await Shell.check("/usr/bin/env", ["python3", installer.path, "--source", folder.path, "--device", values.device],
                                  environment: Toolchain.environment(xcode: xcode), directory: source.root, line: job.sink())
        } else {
            try await Devices.copyToApp(folder, destination: "Documents/" + profile.destination, bundleID: values.bundleID,
                                        device: device, xcode: xcode, line: job.sink())
        }
        state.copied[profile.id] = .init(bundleID: values.bundleID, device: values.device, source: folder.path, date: Date())
    }

    /// After the game was updated on this Mac (by Battle.net, say): a new build
    /// when its executable changed since the last one, then the copy, which
    /// skips files that did not change.
    func updateGame(_ profile: AppProfile) {
        start(.copy(profile.id), title: "Updating \(profile.name)", phase: "Checking what changed…") { job in
            if !self.state.profiles.contains(profile.id) { self.state.profiles.append(profile.id) }
            let current = await self.hashes(of: [profile])[profile.id]
            let built = self.state.installed?.executables?[profile.id]
            try await self.performInstall(job, force: current == nil || current != built)
            try await self.performCopy(profile, job: job)
            job.phase = "\(profile.name) is up to date on your \(self.deviceWord)."
            await self.readLibrary()
        }
    }

    /// The games Tolkara has on the device.
    func readLibrary() async {
        guard let xcode, let device = selectedDevice, device.available, device.paired, let bundleID = state.effectiveBundleID else {
            libraryError = "Connect your \(deviceWord) to see its games."
            return
        }
        readingLibrary = true
        defer { readingLibrary = false }
        do {
            var read = try await DeviceLibraryReader.read(profiles: profiles, bundleID: bundleID, device: device, xcode: xcode)
            // The games this app sets up first, then the others by name.
            let managed = Set(setupProfiles.map(\.id))
            read.folders.sort { a, b in
                let first = (a.games.contains { managed.contains($0.id) } ? 0 : 1, a.name), second = (b.games.contains { managed.contains($0.id) } ? 0 : 1, b.name)
                return first < second
            }
            library = read
            libraryError = nil
            tolkaraOnDevice = true
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// The device's launcher can remove only with a build made by this app's
    /// source: older builds do not know the request.
    var canRemoveFromDevice: Bool { installIsCurrent && enrolmentIsCurrent }

    /// Deletes a folder of games from the device, through Tolkara itself:
    /// devicectl cannot delete. Tolkara checks the folder holds an application.
    func remove(_ folder: DeviceFolder) {
        guard let xcode, let device = selectedDevice, let bundleID = state.effectiveBundleID, let source else { return }
        start(.remove(folder.name), title: "Removing \(folder.name)", phase: "Removing \(folder.name) from \(device.name)…") { job in
            job.hint = "Unlock your \(self.deviceWord)."
            // A fresh result file, so an old one is never mistaken for this one.
            let pending = source.root.appendingPathComponent("build/management-result.txt")
            try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "pending".write(to: pending, atomically: true, encoding: .utf8)
            try await Devices.copyToApp(pending, destination: "Documents/management-result.txt", bundleID: bundleID, device: device, xcode: xcode, line: job.sink())
            try await Devices.launch(bundleID: bundleID, arguments: ["--remove-app-folder", folder.name], on: device, xcode: xcode)
            var result = "pending"
            for _ in 0..<30 where result == "pending" {
                try await Task.sleep(for: .seconds(1))
                if let data = await Devices.readFromApp("Documents/management-result.txt", bundleID: bundleID, device: device, xcode: xcode) {
                    result = String(decoding: data, as: UTF8.self)
                }
            }
            job.append(result)
            // Back to the library on the device.
            try? await Devices.launch(bundleID: bundleID, on: device, xcode: xcode)
            guard result.hasPrefix("Removed") else {
                throw ProfileError(message: result == "pending" ? "Tolkara did not answer. Unlock your \(self.deviceWord) and try again." : result)
            }
            for game in folder.games { if let id = game.profile?.id { self.state.copied[id] = nil } }
            job.phase = "\(folder.name) was removed from \(device.name)."
            await self.readLibrary()
        }
    }

    func openOnDevice() {
        guard let xcode, let device = selectedDevice, let bundleID = state.effectiveBundleID else { return }
        start(.launch, title: "Opening Tolkara", phase: "Opening Tolkara on \(device.name)…") { job in
            job.hint = "Unlock your \(self.deviceWord)."
            try await Devices.launch(bundleID: bundleID, on: device, xcode: xcode)
            job.phase = "Tolkara is open on \(device.name)."
        }
    }

    func saveLog(to url: URL) {
        guard let xcode, let device = selectedDevice, let bundleID = state.effectiveBundleID else { return }
        start(.log, title: "Saving the \(deviceWord) log", phase: "Copying the log from \(device.name)…") { job in
            try await Devices.copyFromApp("Documents/native-guest.log", to: url, bundleID: bundleID, device: device, xcode: xcode)
            job.phase = "Saved \(url.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func startOver() {
        let keep = (state.sourceOverride, state.checkForUpdates)
        state = SetupState()
        state.sourceOverride = keep.0
        state.checkForUpdates = keep.1
        lastJobs = [:]
        selection = .welcome
    }

    // MARK: Updates

    /// Asks GitHub for the newest release of this app.
    func checkForUpdate() async {
        guard state.checkForUpdates,
              let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              current.first?.isNumber == true, current != "0.0",
              let url = URL(string: "https://api.github.com/repos/tolkara/tolkara/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String, let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if latest.compare(current, options: .numeric) == .orderedDescending { update = (latest, page) }
    }
}
