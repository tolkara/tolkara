import SwiftUI

struct ContentView: View {
    @Environment(SetupModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { if let step = $0 { model.selection = step } })) {
                Section("Setup") {
                    ForEach(SetupStep.setup) { step in
                        SidebarRow(step: step, status: model.status(step))
                            .tag(step)
                            .disabled(!model.isReachable(step) && !model.isComplete(step))
                    }
                }
                Section("Your \(model.deviceWord)") {
                    SidebarRow(step: .library, status: model.status(.library))
                        .tag(SetupStep.library)
                        .disabled(!model.isReachable(.library))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                if let update = model.update {
                    Link(destination: update.url) {
                        Label("Version \(update.version) is available", systemImage: "arrow.down.circle")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } detail: {
            Group {
                switch model.selection {
                case .welcome: WelcomeView()
                case .membership: MembershipView()
                case .mac: MacView()
                case .iPad: IPadView()
                case .game: GameView()
                case .install: InstallView()
                case .copy: CopyView()
                case .play: PlayView()
                case .library: LibraryView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .help("Check everything again (⌘R)")
                    .disabled(model.job?.isRunning == true)
                }
            }
        }
        .navigationTitle("Tolkara Management")
        .task {
            // Unit tests host the app; they test the logic, not this Mac.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            await model.refreshAll()
            if model.state.welcomed { model.selection = model.firstIncompleteStep }
            // `-showStep game` on the command line opens a step directly (for screenshots).
            if let step = UserDefaults.standard.string(forKey: "showStep").flatMap(SetupStep.init(rawValue:)) { model.selection = step }
            await model.checkForUpdate()
        }
    }
}

private struct SidebarRow: View {
    var step: SetupStep
    var status: StepStatus

    var body: some View {
        Label {
            Text(step.title)
        } icon: {
            switch status {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .current: Image(systemName: step.symbol)
            case .pending: Image(systemName: step.symbol).foregroundStyle(.tertiary)
            }
        }
        .accessibilityValue(status == .done ? "Done" : status == .attention ? "Needs attention" : "")
    }
}
