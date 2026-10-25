import XCTest

/// What is on screen now, without launching anything: a screenshot and SpringBoard's window controls.
final class ScreenTests: XCTestCase {
    func testScreen() throws {
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("BOARD BUTTONS\n" + board.buttons.allElementsBoundByIndex.map { "  \($0.identifier) | \($0.label) | \($0.frame)" }.joined(separator: "\n"))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "screen"; shot.lifetime = .keepAlways; add(shot)
    }
}

/// Taps on the running Tolkara app, as a person operating it would: TAP_POINTS lists
/// "x,y" fractions of the app's frame separated by ";" (a point with a third field
/// "d" is a double tap), TAP_WAIT the seconds between taps. Nothing is launched,
/// and nothing is tapped unless asked (TEST_RUNNER_TAP_POINTS on xcodebuild).
final class TapTests: XCTestCase {
    func testTap() throws {
        let environment = ProcessInfo.processInfo.environment
        let points = (environment["TAP_POINTS"] ?? "").split(separator: ";")
        let wait = Double(environment["TAP_WAIT"] ?? "") ?? 2
        let app = XCUIApplication(bundleIdentifier: environment["TAP_APP"] ?? "local.tolkara.yourname")
        print("TAP app state \(app.state.rawValue) frame \(app.frame)")
        for point in points {
            let fields = point.split(separator: ",")
            guard fields.count >= 2, let x = Double(fields[0]), let y = Double(fields[1]) else { continue }
            let target = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
            if fields.count > 2 && fields[2] == "d" { target.doubleTap() } else { target.tap() }
            print("TAP at \(x),\(y)")
            Thread.sleep(forTimeInterval: wait)
        }
    }
}
