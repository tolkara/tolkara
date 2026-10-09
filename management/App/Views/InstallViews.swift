import SwiftUI

struct InstallView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        StepPage(step: .install, summary: "Tolkara is built on this Mac with your developer account and installed on your \(model.deviceWord). Only Tolkara's own code is built and signed; your game is read to see what it needs, never changed.") {
            AdoptCallout()
            Form {
                Section("What happens") {
                    CheckRow("Build Tolkara with \(model.state.team?.name ?? "your team")",
                             detail: model.installIsCurrent ? builtDetail : "Takes 5 to 15 minutes the first time.",
                             status: model.installIsCurrent ? .ok : .waiting)
                    CheckRow("Install it on \(model.selectedDevice?.name ?? model.state.deviceName ?? "your \(model.deviceWord)")",
                             detail: "Replaces an earlier Tolkara and keeps its data.",
                             status: model.installIsCurrent ? .ok : .waiting)
                    CheckRow("Connect Tolkara to the \(model.deviceWord)'s developer service",
                             detail: "Once. Afterwards the \(model.deviceWord) prepares games by itself, without this Mac.",
                             status: model.enrolmentIsCurrent ? .ok : .waiting)
                    if model.installIsCurrent, let expiry = model.profileExpiry {
                        let soon = expiry.timeIntervalSinceNow < 30 * 86400
                        CheckRow(soon ? "Tolkara stops opening on \(expiry.formatted(date: .long, time: .omitted))" : "Valid until \(expiry.formatted(date: .long, time: .omitted))",
                                 detail: "Apple's signature for your build lasts a year. Build and install again before then; your games stay on the \(model.deviceWord).",
                                 status: soon ? .warning : .ok)
                    }
                }
            }
            .pageForm()

            if let job = model.lastJobs[.install] {
                JobPanel(job: job)
            }
            if model.lastJobs[.install]?.isRunning != true {
                HStack {
                    if model.isComplete(.install) {
                        Button("Build and Install Again") { model.installTolkara(force: true) }
                            .help("For example after your provisioning profile expired, a year after the first install.")
                    } else {
                        Button(model.installIsCurrent ? "Connect to the Developer Service" : "Install Tolkara") { model.installTolkara() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.job?.isRunning == true || model.selectedDevice?.available != true)
                    }
                    if model.selectedDevice?.available != true {
                        Text("Connect your \(model.deviceWord) first.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var builtDetail: String {
        guard let installed = model.state.installed else { return "" }
        return "Built \(installed.date.formatted(date: .abbreviated, time: .shortened)) from Tolkara \(model.source?.version ?? "")."
    }
}

struct CopyView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        StepPage(step: .copy, summary: "Your game's files go into Tolkara's folder on your \(model.deviceWord), unchanged. Your account settings, saved passwords and add-ons stay on this Mac.") {
            if let device = model.selectedDevice, !device.wired {
                Callout(.info, "Use a cable", message: "Games are tens of gigabytes. Over the network the copy can take hours; over a cable it is much faster.")
            }
            ForEach(model.chosenProfiles) { profile in
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        CheckRow(model.copyIsCurrent(profile) ? "On your \(model.deviceWord)" : "Not copied yet",
                                 detail: copyDetail(profile),
                                 status: model.copyIsCurrent(profile) ? .ok : .waiting) {
                            if model.lastJobs[.copy(profile.id)]?.isRunning != true {
                                Button(model.copyIsCurrent(profile) ? "Copy Again" : "Copy to \(model.deviceWord)") { model.copy(profile) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.job?.isRunning == true || model.selectedDevice?.available != true)
                            }
                        }
                        if let job = model.lastJobs[.copy(profile.id)] { JobPanel(job: job) }
                    }
                    .padding(6)
                } label: {
                    Text(profile.name).font(.title3.weight(.semibold))
                }
            }
            Text("Copy again after the game updates on this Mac. Files that did not change are skipped.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func copyDetail(_ profile: AppProfile) -> String {
        if let copy = model.state.copied[profile.id], model.copyIsCurrent(profile) {
            return "Copied \(copy.date.formatted(date: .abbreviated, time: .shortened)) from \(copy.source)."
        }
        return "From \(model.sourceFolder(for: profile)?.path ?? "this Mac") to On My \(model.deviceWord) › Tolkara › \(profile.destination)."
    }
}

struct PlayView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        StepPage(step: .play, summary: "Everything is set up. From now on you only need your \(model.deviceWord).") {
            Callout(.success, "Ready to play") {
                NumberedSteps(steps: [
                    "Open **Tolkara** on your \(model.deviceWord). You can unplug the cable.",
                    "Tap \(model.chosenProfiles.map { "**\($0.name)**" }.formatted(.list(type: .or))) in the library.",
                    "The first time, iPadOS asks to add a VPN configuration. Tap **Allow**: it is Tolkara's own on-device connection to the \(model.deviceWord)'s developer service, and no traffic leaves the \(model.deviceWord).",
                    "Keep Tolkara open while it prepares the game. This takes a minute or two at every start.",
                    "Log in inside the game as usual. Start with modest graphics settings.",
                ] + (model.deviceWord == "iPhone"
                     ? ["On iPhone, use the on-screen keyboard and touch trackpad, or a Bluetooth keyboard. The hand button in Tolkara's library turns the on-screen controls on or off."]
                     : []))
                Button("Open Tolkara on \(model.deviceWord)") { model.openOnDevice() }
                    .disabled(model.job?.isRunning == true || model.selectedDevice?.available != true)
            }
            if let job = model.lastJobs[.launch], job.failure != nil || job.isRunning { JobPanel(job: job) }

            GroupBox("If something goes wrong") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tolkara writes what happened at each start into a log on the \(model.deviceWord). Save it to this Mac to look at it or to attach it to a report.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Save \(model.deviceWord) Log…", action: saveLog)
                            .disabled(model.job?.isRunning == true || model.selectedDevice?.available != true)
                        Link("Compatibility List", destination: Links.compatibility)
                        Link("Report a Problem", destination: Links.issues)
                    }
                    if let job = model.lastJobs[.log] { JobPanel(job: job) }
                }
                .padding(6)
            }
            GroupBox("Keep it working") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("A year after installing, your provisioning profile expires: open this app and choose Build and Install Again.", systemImage: "calendar")
                    Label("Deleting Tolkara from the \(model.deviceWord) also deletes the copied game. Installing again keeps it.", systemImage: "trash")
                    Label("Never attach Xcode's debugger to Tolkara while a game runs.", systemImage: "ant")
                }
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "native-guest.log"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveLog(to: url)
    }
}

struct SettingsView: View {
    @Environment(SetupModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Toggle("Check for new versions of Tolkara Management", isOn: $model.state.checkForUpdates)
                LabeledContent("Tolkara version", value: model.source?.version ?? "–")
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    TextField("App identifier", text: Binding(get: { model.state.effectiveBundleID ?? "" },
                                                              set: { model.state.bundleID = $0.isEmpty ? nil : $0 }))
                } footer: {
                    Text("The bundle identifier Tolkara is installed under. Change it only if Apple says it is taken: a different identifier installs a separate Tolkara without your copied games.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Tolkara folder") {
                        Text(model.state.sourceOverride ?? "The copy inside this app").lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Choose Folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.message = "Choose a Tolkara checkout (the folder with tools/install.sh)."
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            model.state.sourceOverride = url.path
                            Task { await model.prepareSource() }
                        }
                        Button("Use Built-in Copy") {
                            model.state.sourceOverride = nil
                            Task { await model.prepareSource() }
                        }
                        .disabled(model.state.sourceOverride == nil)
                        Button("Show Work Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.source?.root ?? AppPaths.support])
                        }
                    }
                } footer: {
                    Text("For developers: build from your own Tolkara checkout instead. The work folder holds local.env and the build output, so you can also run Tolkara's scripts there by hand.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Start Over…", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Forgets your choices in this app. Nothing is removed from your iPad or iPhone.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
        .confirmationDialog("Start over?", isPresented: $confirmReset) {
            Button("Start Over", role: .destructive) { model.startOver() }
        } message: {
            Text("Tolkara Management forgets your team, device and game choices. Tolkara and your games stay on the device.")
        }
    }
}
