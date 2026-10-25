import XCTest

/// Prints what the window controls look like to UI automation, so the full-screen test can use them.
final class DiscoverTests: XCTestCase {
    func testDiscoverWindowControls() throws {
        let host = XCUIApplication(bundleIdentifier: Bundle(for: DiscoverTests.self).object(forInfoDictionaryKey: "ProbeHostID") as? String ?? "")
        host.launch()
        sleep(3)
        print("HOST TREE\n\(host.debugDescription)")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("BOARD BUTTONS\n" + board.buttons.allElementsBoundByIndex.map { "\($0.identifier) | \($0.label) | \($0.frame)" }.joined(separator: "\n"))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
