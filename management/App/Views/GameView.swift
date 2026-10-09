import SwiftUI
import UniformTypeIdentifiers

struct GameView: View {
    @Environment(SetupModel.self) private var model
    @State private var riskProfile: AppProfile?
    @State private var showDownload = false
    @State private var importError: String?

    var body: some View {
        StepPage(step: .game, summary: "Choose the game to set up. A profile tells Tolkara where the game is on this Mac and where it goes on your iPad or iPhone. You can add more games later.") {
            if let error = model.sourceError {
                Callout(.error, "Tolkara's source is not available", message: error)
            }
            Form {
                Section {
                    ForEach(model.setupProfiles) { profile in
                        ProfileRow(profile: profile, chosen: model.state.profiles.contains(profile.id)) { chosen in
                            if chosen, profile.risk != nil, !model.riskAccepted(profile) { riskProfile = profile }
                            else { model.toggle(profile) }
                        }
                        .contextMenu {
                            if profile.isImported { Button("Remove Profile", role: .destructive) { model.removeImported(profile) } }
                        }
                    }
                } header: {
                    Text("Games")
                } footer: {
                    HStack {
                        Menu("Add a Profile") {
                            Button("From a File…", action: importFile)
                            Button("From a Link…") { showDownload = true }
                        }
                        .fixedSize()
                        Spacer()
                        if !model.commandLineProfiles.isEmpty {
                            Text("Also tested, set up from the command line: \(model.commandLineProfiles.map(\.name).formatted()).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .pageForm()

            if let importError {
                Callout(.error, "The profile was not added", message: importError)
            }
            ForEach(model.chosenProfiles) { profile in
                ProfileSetup(profile: profile) { riskProfile = profile }
            }
        }
        .sheet(item: $riskProfile) { profile in
            RiskSheet(profile: profile)
        }
        .sheet(isPresented: $showDownload) {
            DownloadProfileSheet()
        }
        .onAppear {
            // `-showRisk wow-forever` opens a profile's disclaimer directly (for screenshots).
            if let id = UserDefaults.standard.string(forKey: "showRisk") { riskProfile = model.profiles.first { $0.id == id } }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Tolkara profile (a .json file)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try model.importProfile(data: try Data(contentsOf: url))
            importError = nil
            if !model.state.profiles.contains(profile.id) {
                if profile.risk != nil { riskProfile = profile } else { model.toggle(profile) }
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ProfileRow: View {
    var profile: AppProfile
    var chosen: Bool
    var toggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { chosen }, set: toggle)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline)
                    if profile.risk != nil {
                        Label("Online · account risk", systemImage: "exclamationmark.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if profile.isImported {
                        Text("Added by you").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let tested = profile.tested {
                    Text("Tested: \(tested)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Getting and finding one chosen game.
private struct ProfileSetup: View {
    @Environment(SetupModel.self) private var model
    var profile: AppProfile
    var reviewRisk: () -> Void
    @State private var size: Int64?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let getApp = profile.getApp, !model.executableFound(for: profile) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Get the game").font(.headline)
                        NumberedSteps(steps: getApp.steps)
                        HStack {
                            if let path = getApp.path, FileManager.default.fileExists(atPath: path) {
                                Button("Open \(getApp.name)") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            } else {
                                Link("Get \(getApp.name)", destination: getApp.url)
                            }
                        }
                    }
                    Divider()
                }
                found
                if let risk = profile.risk {
                    CheckRow("Account risk", detail: model.riskAccepted(profile) ? "You accepted the risk of playing online." : String(risk.summary.prefix(140)) + "…",
                             status: model.riskAccepted(profile) ? .ok : .warning) {
                        Button(model.riskAccepted(profile) ? "Review" : "Review and Accept…", action: reviewRisk)
                    }
                }
                if let notes = profile.notes, profile.isImported {
                    Text(notes).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Text(profile.name).font(.title3.weight(.semibold))
        }
        .task(id: model.sourceFolder(for: profile)) {
            size = nil
            guard let folder = model.sourceFolder(for: profile), model.executableFound(for: profile) else { return }
            size = await Task.detached(priority: .utility) { folderSize(folder) }.value
        }
    }

    @ViewBuilder private var found: some View {
        let folder = model.sourceFolder(for: profile)
        if model.executableFound(for: profile), let folder {
            let app = profile.executable(inSource: folder).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
            CheckRow("Found on this Mac",
                     detail: [folder.path, version.map { "version \($0)" }, size.map { "\($0.bytes) folder" }].compactMap { $0 }.joined(separator: " · "),
                     status: .ok) {
                Button("Choose Another Folder…", action: choose)
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
            }
        } else {
            CheckRow("Not found on this Mac",
                     detail: folder.map { "Looked for \(profile.executableInSource) in \($0.path)." } ?? "Choose the folder the game is installed in.",
                     status: .waiting) {
                Button("Choose Folder…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that holds \(profile.name) — for World of Warcraft, the “World of Warcraft” folder."
        if let folder = model.sourceFolder(for: profile) { panel.directoryURL = folder.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setSource(url, for: profile)
    }
}

private func folderSize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
        total += Int64(values.totalFileAllocatedSize ?? 0)
    }
    return total
}

/// The disclaimer shown before a game with an account risk is set up.
struct RiskSheet: View {
    @Environment(SetupModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var profile: AppProfile
    @State private var understood = false

    var body: some View {
        let risk = profile.risk!
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your account is at risk").font(.title2.weight(.semibold))
                    Text("Read this before you play \(profile.name) with Tolkara.").foregroundStyle(.secondary)
                }
            }
            Text(risk.summary).fixedSize(horizontal: false, vertical: true)
            if !risk.history.isEmpty {
                GroupBox("What history shows") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(risk.history, id: \.self) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.when).font(.callout.weight(.semibold)).frame(width: 44, alignment: .leading)
                                Text(entry.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(4)
                }
            }
            if !risk.links.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(risk.links, id: \.self) { link in
                        Link(link.title, destination: link.url).font(.callout)
                    }
                }
            }
            Toggle(isOn: $understood) {
                Text("I understand that my account could be suspended or banned, and that this risk is mine alone. The Tolkara authors are not responsible.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(model.riskAccepted(profile))
            HStack {
                Spacer()
                if model.riskAccepted(profile) {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Accept and Continue") {
                        model.acceptRisk(profile)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!understood)
                }
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear { understood = model.riskAccepted(profile) }
    }
}

private struct DownloadProfileSheet: View {
    @Environment(SetupModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Profile from a Link").font(.title2.weight(.semibold))
            Text("Paste the https link of a Tolkara profile (a .json file). Add profiles only from people you trust: a profile cannot run any code, but it decides which folder is copied to your iPad or iPhone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Link", text: $link, prompt: Text("https://…/profile.json"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(download)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Profile", action: download)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!link.hasPrefix("https://") || loading)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func download() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            error = "Enter an https link."
            return
        }
        loading = true
        Task {
            defer { loading = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProfileError(message: "The link did not return a file.") }
                guard data.count <= 65536 else { throw ProfileError(message: "This file is too large to be a profile.") }
                let profile = try model.importProfile(data: data)
                if profile.risk == nil, !model.state.profiles.contains(profile.id) { model.toggle(profile) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
