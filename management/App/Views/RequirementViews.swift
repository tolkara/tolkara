import SwiftUI

struct WelcomeView: View {
    var body: some View {
        StepPage(step: .welcome,
                 summary: "Tolkara runs your own Mac games on your iPad or iPhone, unchanged. This app checks that you have everything, builds Tolkara for you and copies your game over.",
                 continueTitle: "Get Started") {
            HStack(alignment: .top, spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("What you need").font(.title2.weight(.semibold))
                    Requirement(symbol: "person.badge.key", title: "A paid Apple Developer Program membership",
                                detail: "Tolkara is built and signed with your own account. Apple charges $99 a year; a free account cannot sign what Tolkara needs.")
                    Requirement(symbol: "hammer", title: "Xcode on this Mac",
                                detail: "Free from the App Store. It is large, so start the download early.")
                    Requirement(symbol: "ipad.landscape", title: "An iPad or iPhone, and a cable",
                                detail: "Tested on iPad Pro (M5) with iPadOS 27, and on iPhone 16 Pro Max with iOS 27. iPhone support is newer and still experimental.")
                    Requirement(symbol: "gamecontroller", title: "Your game, installed on this Mac",
                                detail: "Your own copy, such as World of Warcraft from Battle.net. Nothing is downloaded for you, and the game is never changed.")
                }
            }
            Callout(.info, "Set aside about an hour",
                    message: "Most of it is waiting for downloads, the first build and the game copy. Each step checks itself, so you always know whether it worked.")
            Text("Tolkara is an independent open-source project. It is not affiliated with Apple or Blizzard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Requirement: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MembershipView: View {
    @Environment(SetupModel.self) private var model
    @State private var teamID = ""
    @State private var showManual = false

    private var paid: [DeveloperTeam] { model.teams.filter { $0.kind == .paid } }

    var body: some View {
        StepPage(step: .membership,
                 summary: "Tolkara is built on this Mac with your own Apple developer account. It needs a paid membership: only paid accounts can sign the VPN-style tunnel and larger memory Tolkara uses, and apps from free accounts stop working after seven days.") {
            if !model.scannedTeams {
                CheckRow("Looking for your developer account…", status: .checking)
            } else if let team = model.state.team, team.kind == .paid || team.kind == .unknown {
                Callout(team.kind == .paid ? .success : .info,
                        team.kind == .paid ? "You have a paid membership" : "Team \(team.id) will be confirmed when Tolkara is built",
                        message: team.kind == .paid
                            ? "Tolkara will be built with \(team.name) (\(team.id))."
                            : "This Mac has no record of the team yet. If the membership is not paid, the build will say so.")
            } else if !paid.isEmpty {
                Callout(.info, "Choose the team to build with", message: "This Mac knows several teams with a paid membership.")
            } else if model.teams.contains(where: { $0.kind == .free }) {
                Callout(.error, "Your account has a free membership only",
                        message: "Apple's free Personal Team cannot sign Tolkara. Join the Apple Developer Program with the same Apple Account, wait for Apple's confirmation email, then check again.") {
                    HStack {
                        Link("Join the Apple Developer Program", destination: Links.enroll)
                        Button("Check Again") { model.scanMembership() }
                    }
                }
            } else if model.teams.contains(where: { $0.kind == .expired }) {
                Callout(.error, "Your membership seems to have expired",
                        message: "Renew it at developer.apple.com, then check again.") {
                    HStack {
                        Link("Open Your Developer Account", destination: Links.membership)
                        Button("Check Again") { model.scanMembership() }
                    }
                }
            } else {
                Callout(.warning, "Sign in to Xcode with your developer account",
                        message: "This Mac does not know your developer account yet. If you do not have Xcode, get it on the This Mac step first, then come back.") {
                    NumberedSteps(steps: ["Open Xcode.", "Choose **Xcode › Settings…**, then **Apple Accounts** (or **Accounts**).",
                                          "Click **+** and sign in with the Apple Account of your developer membership.",
                                          "Come back here and click **Check Again**."])
                    HStack {
                        Button("Open Xcode") { if let xcode = model.xcode { NSWorkspace.shared.open(xcode.url) } }
                            .disabled(model.xcode == nil)
                        Button("Check Again") { model.scanMembership() }
                        Link("Join the Apple Developer Program", destination: Links.enroll)
                    }
                }
            }

            if !model.teams.isEmpty {
                Form {
                    Section("Teams on this Mac") {
                        ForEach(model.teams) { team in
                            CheckRow(team.name, detail: "\(team.id) · \(description(team.kind)) · \(team.evidence)",
                                     status: team.kind == .paid ? .ok : team.kind == .unknown ? .warning : .failed) {
                                if team.kind == .paid {
                                    if model.state.team?.id == team.id {
                                        Text("Selected").foregroundStyle(.secondary)
                                    } else {
                                        Button("Use This Team") { model.chooseTeam(team) }
                                    }
                                }
                            }
                        }
                    }
                }
                .pageForm()
            }

            DisclosureGroup("I have a paid membership, but it is not listed", isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find your Team ID at developer.apple.com › Account › Membership details. Make sure Xcode is signed in to the same account: it signs Tolkara.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Team ID", text: $teamID, prompt: Text("10 letters and digits"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit(useTyped)
                        Button("Use Team ID", action: useTyped)
                            .disabled(teamID.trimmingCharacters(in: .whitespaces).uppercased().wholeMatch(of: MembershipScanner.teamID) == nil)
                        Link("Membership Details", destination: Links.membership)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func useTyped() {
        model.enterTeam(teamID)
        showManual = false
    }

    private func description(_ kind: DeveloperTeam.Kind) -> String {
        switch kind {
        case .paid: "Paid membership"
        case .free: "Free Personal Team"
        case .expired: "Expired"
        case .unknown: "Not yet confirmed"
        }
    }
}

struct MacView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        StepPage(step: .mac, summary: "Tolkara is built by Apple's own developer tools on this Mac. Everything here is free.") {
            Form {
                Section {
                    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
                    CheckRow("macOS", detail: macOS, status: .ok)
                    xcodeRows
                    if model.xcode != nil {
                        CheckRow("XcodeGen", detail: model.xcodegen.map { "Installed at \($0)" } ?? "A small free tool that prepares Tolkara's Xcode project.",
                                 status: model.xcodegen != nil ? .ok : (model.checkedMac ? .failed : .checking)) {
                            if model.xcodegen == nil {
                                Button("Install") { model.installXcodegen() }
                                    .disabled(model.job?.isRunning == true)
                            }
                        }
                        CheckRow("Python 3", detail: model.python.map { "Version \($0)" } ?? "Comes with Xcode once it is set up.",
                                 status: model.python != nil ? .ok : (model.checkedMac ? .failed : .checking))
                    }
                    if let space = model.freeSpace {
                        CheckRow("Free space on this Mac", detail: "\(space.bytes) available. The build needs about 10 GB.",
                                 status: space > 10_000_000_000 ? .ok : .warning)
                    }
                }
            }
            .pageForm()
            if let job = model.lastJobs[.xcodegen] { JobPanel(job: job) }
        }
    }

    @ViewBuilder private var xcodeRows: some View {
        if let xcode = model.xcode {
            CheckRow("Xcode", detail: "Version \(xcode.version) at \(xcode.url.path)", status: .ok)
            CheckRow("Xcode is set up",
                     detail: model.xcodeReady == true ? "Licence accepted and components installed."
                        : "Open Xcode once: accept its licence and let it install its components. Then click Check Again.",
                     status: model.xcodeReady == true ? .ok : (model.xcodeReady == nil ? .checking : .failed)) {
                if model.xcodeReady == false {
                    Button("Open Xcode") { NSWorkspace.shared.open(xcode.url) }
                    Button("Check Again") { Task { await model.checkMac() } }
                }
            }
        } else {
            CheckRow("Xcode", detail: model.checkedMac ? "Not installed. It is free in the App Store; the download is large." : nil,
                     status: model.checkedMac ? .failed : .checking) {
                if model.checkedMac {
                    Button("Get Xcode") { NSWorkspace.shared.open(Toolchain.xcodeAppStore) }
                    Button("Check Again") { Task { await model.checkMac() } }
                }
            }
        }
    }
}

struct IPadView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        StepPage(step: .iPad, summary: "Tolkara is installed on your iPad or iPhone from this Mac. Connect it with a cable for setup; afterwards it works on its own.") {
            if model.devices.filter(\.available).count > 1 || (model.state.device != nil && model.selectedDevice == nil && !model.devices.isEmpty) {
                Picker("Device", selection: Binding(get: { model.state.device ?? "" },
                                                    set: { id in if let device = model.devices.first(where: { $0.id == id }) { model.chooseDevice(device) } })) {
                    ForEach(model.devices) { device in
                        Text("\(device.name) (\(device.model))\(device.available ? "" : " – not connected")").tag(device.id)
                    }
                }
                .frame(maxWidth: 420)
            }
            Form {
                Section {
                    let device = model.selectedDevice
                    CheckRow("Connected",
                             detail: device.map { "\($0.name), \($0.model), \($0.isIPad ? "iPadOS" : "iOS") \($0.osVersion)\($0.available && !$0.wired ? ", over the network. A cable is much faster for copying games." : "")" }
                                ?? "Connect your iPad or iPhone to this Mac with a cable and unlock it.",
                             status: device?.available == true ? .ok : (model.scannedDevices ? .waiting : .checking))
                    CheckRow("Trusts this Mac",
                             detail: device?.paired == true ? nil : "Unlock your \(model.deviceWord). When it asks whether to trust this computer, tap Trust and enter its passcode.",
                             status: device?.paired == true ? .ok : .waiting) {
                        if let device, device.available, !device.paired {
                            Button("Ask \(model.deviceWord) to Trust") { model.pair(device) }
                                .disabled(model.job?.isRunning == true)
                        }
                    }
                    CheckRow("Developer Mode", detail: developerModeDetail(device), status: device?.developerMode == true ? .ok : .waiting)
                    if let device, device.isIPad == false {
                        CheckRow("Playing on iPhone",
                                 detail: "Games run in landscape, with an on-screen keyboard and touch trackpad, or a Bluetooth keyboard. WoW Forever has been played on an iPhone 16 Pro Max with iOS 27; iPhone support is newer than iPad support.",
                                 status: .ok)
                    }
                    if model.xcodeTooOldForDevice, let device {
                        CheckRow("Xcode is older than \(device.isIPad ? "iPadOS" : "iOS") \(device.osVersion)",
                                 detail: "Update Xcode in the App Store so that it can install apps on this \(model.deviceWord).", status: .failed) {
                            Button("Update Xcode") { NSWorkspace.shared.open(Toolchain.xcodeAppStore) }
                        }
                    }
                }
            }
            .pageForm()

            if let device = model.selectedDevice, device.paired, device.developerMode == false {
                Callout(.info, "Turn on Developer Mode") {
                    NumberedSteps(steps: ["On your \(model.deviceWord), open **Settings › Privacy & Security**.",
                                          "Scroll to the bottom, tap **Developer Mode** and turn it on.",
                                          "Tap **Restart**. When the \(model.deviceWord) has restarted, unlock it and tap **Turn On**.",
                                          "This page notices by itself when it is done."])
                    Text("Don't see Developer Mode? Keep the \(model.deviceWord) connected, open Xcode and choose Window › Devices and Simulators once; the option then appears.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Xcode") { if let xcode = model.xcode { NSWorkspace.shared.open(xcode.url) } }
                }
            }
            if let error = model.deviceError, model.devices.isEmpty {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            if let job = model.lastJobs[.pair], job.failure != nil || job.isRunning { JobPanel(job: job) }
        }
        .task {
            // Watch the iPad while this page is open, so each change shows by itself.
            while !Task.isCancelled {
                await model.refreshDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func developerModeDetail(_ device: Device?) -> String? {
        switch device?.developerMode {
        case true: return nil
        case false: return "Needed to run apps you build yourself. See below."
        default: return "Shown once the \(model.deviceWord) trusts this Mac."
        }
    }
}
