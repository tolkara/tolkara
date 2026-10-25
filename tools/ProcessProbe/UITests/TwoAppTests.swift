import XCTest

/// Tolkara's two builds on screen together (docs/MULTIPROCESS.md, "Two apps"): the second as
/// slot host, then the first with a profile whose named processes it hands over. Both stay in
/// windows, so neither is suspended, for TwoAppMinutes. Settings come from the build
/// (TWO_APP_*); "@GROUP@" in an override stands for ${Group}, the shared App Group folder.
final class TwoAppTests: XCTestCase {
    private func setting(_ key: String) -> String { Bundle(for: TwoAppTests.self).object(forInfoDictionaryKey: key) as? String ?? "" }
    private func overrides(_ key: String) -> [String] {
        setting(key).split(separator: "|").map { "--guest-environment=" + $0.replacingOccurrences(of: "@GROUP@", with: "${Group}") }
    }
    private func step(_ name: String) {
        print("STEP \(ISO8601DateFormatter().string(from: Date())) \(name)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// A full-screen app is the only one running: its own window controls (Zoom) put it back in
    /// a window, beside the other.
    private func windowed(_ app: XCUIApplication, _ id: String) {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let screen = XCUIScreen.main.screenshot().image.size
        let frame = app.windows.firstMatch.frame
        print("WINDOW \(id.hasSuffix(".browser") ? "second" : "first") \(frame) of \(screen)")
        guard frame.width >= screen.width - 1 || frame.height >= screen.height - 1 else { return }
        let controls = board.buttons["window-controls:\(id)"]
        guard controls.waitForExistence(timeout: 5) else { print("no window controls"); return }
        controls.tap(); sleep(1)
        let zoom = board.buttons["Zoom-button"]
        if zoom.waitForExistence(timeout: 3) { zoom.tap(); sleep(2) }
        print("WINDOW now \(app.windows.firstMatch.frame)")
    }

    func testTwoApps() throws {
        // A busy app (preparing its memory) can time out a UI query; the run goes on.
        continueAfterFailure = true
        let profile = setting("TwoAppProfile"), minutes = Int(setting("TwoAppMinutes")) ?? 5
        let common = ["--native-startup", "--app=\(profile)", "--local-native-authorization", "--window-fraction=0.5"]
        let second = XCUIApplication(bundleIdentifier: setting("TolkaraSecondID"))
        second.launchArguments = common + ["--guest-environment=TOLKARA_SLOT_HOST=1"] + overrides("TwoAppSecondEnv")
        second.launch(); step("second app launched")
        sleep(UInt32(Int(setting("TwoAppSecondWait")) ?? 75))
        let first = XCUIApplication(bundleIdentifier: setting("TolkaraFirstID"))
        first.launchArguments = common + overrides("TwoAppFirstEnv")
        // TWO_APP_FIRST_ARGUMENTS: the program's own arguments, separated by commas.
        if !setting("TwoAppFirstArguments").isEmpty {
            first.launchArguments.append("--guest-arguments=" + setting("TwoAppFirstArguments").split(separator: ",").joined(separator: "\t"))
        }
        first.launch(); step("first app launched")
        for minute in 1...minutes { sleep(60); step("minute \(minute)") }
    }
}
