import XCTest

/// The host goes full screen through its own window controls while the peer stays open
/// behind it; the host's pings (Documents/process-probe.log) show whether the peer runs.
final class FullScreenTests: XCTestCase {
    private func identifier(_ key: String) -> String { Bundle(for: FullScreenTests.self).object(forInfoDictionaryKey: key) as? String ?? "" }
    private func step(_ name: String, wait seconds: UInt32 = 0) {
        print("STEP \(ISO8601DateFormatter().string(from: Date())) \(name)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        if seconds > 0 { sleep(seconds) }
    }
    private func buttons(_ board: XCUIApplication) -> String {
        board.buttons.allElementsBoundByIndex.map { "  \($0.identifier) | \($0.label)" }.joined(separator: "\n")
    }

    func testFullScreen() throws {
        let hostID = identifier("ProbeHostID")
        let host = XCUIApplication(bundleIdentifier: hostID)
        let peer = XCUIApplication(bundleIdentifier: identifier("ProbePeerID"))
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        peer.launch(); step("peer launched", wait: 5)
        host.launch(); step("host launched", wait: 10)

        let controls = board.buttons["window-controls:\(hostID)"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5), "no window controls")
        controls.tap(); sleep(1)
        print("BUTTONS AFTER CONTROLS\n\(buttons(board))")
        step("controls open")
        let candidates = board.buttons.allElementsBoundByIndex.filter {
            let text = ($0.identifier + " " + $0.label).lowercased()
            return text.contains("full") || text.contains("maximi") || text.contains("zoom")
        }
        print("FULL SCREEN CANDIDATES\n" + candidates.map { "  \($0.identifier) | \($0.label)" }.joined(separator: "\n"))
        guard let full = candidates.first else { XCTFail("no full-screen control"); return }
        full.tap(); sleep(2)
        step("host full screen", wait: 120)
        step("still full screen after 120 s")
        peer.activate(); step("peer activated", wait: 15)
        step("end")
    }
}
