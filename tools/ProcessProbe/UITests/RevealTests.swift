import XCTest

/// How a full-screen app's window controls appear to UI automation.
final class RevealTests: XCTestCase {
    func testReveal() throws {
        let id = Bundle(for: RevealTests.self).object(forInfoDictionaryKey: "TolkaraFirstID") as? String ?? ""
        let app = XCUIApplication(bundleIdentifier: id)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launch(); sleep(3)
        func show(_ label: String) {
            print("REVEAL \(label): " + board.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }.joined(separator: ", "))
        }
        show("after launch")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 6)).tap(); sleep(1); show("tap top center")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 30, dy: 10)).tap(); sleep(1); show("tap top left")
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 3))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))); sleep(1); show("drag from top")
        app.typeKey("f", modifierFlags: .function); sleep(2); show("globe+f")
        print("REVEAL frame \(app.windows.firstMatch.frame)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "end"; shot.lifetime = .keepAlways; add(shot)
    }
}
