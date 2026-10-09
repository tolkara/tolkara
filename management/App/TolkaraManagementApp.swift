import SwiftUI

@main
struct TolkaraManagementApp: App {
    @State private var model = SetupModel()

    var body: some Scene {
        Window("Tolkara Management", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Check Again") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("Tolkara Management Help", destination: Links.guide)
                Link("Building Tolkara by Hand", destination: Links.building)
                Link("Compatibility List", destination: Links.compatibility)
                Divider()
                Link("Report a Problem…", destination: Links.issues)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum Links {
    static let repository = URL(string: "https://github.com/tolkara/tolkara")!
    static let guide = URL(string: "https://github.com/tolkara/tolkara/blob/main/docs/MANAGEMENT.md")!
    static let building = URL(string: "https://github.com/tolkara/tolkara/blob/main/docs/BUILDING.md")!
    static let compatibility = URL(string: "https://github.com/tolkara/tolkara/blob/main/COMPATIBILITY.md")!
    static let issues = URL(string: "https://github.com/tolkara/tolkara/issues")!
    static let risk = URL(string: "https://github.com/tolkara/tolkara#online-games-and-account-risk")!
    static let enroll = URL(string: "https://developer.apple.com/programs/enroll/")!
    static let membership = URL(string: "https://developer.apple.com/account")!
}
