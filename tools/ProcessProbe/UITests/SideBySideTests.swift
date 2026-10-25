// Drives ProcessProbe and ProcessProbePeer on the device, so the side-by-side test needs
// no hands: launches both, switches between them and to the Home Screen, and takes a
// screenshot at every step. Each step's time is printed, to align with the apps' logs.
import XCTest

final class SideBySideTests: XCTestCase {
    private func identifier(_ key: String) -> String {
        Bundle(for: SideBySideTests.self).object(forInfoDictionaryKey: key) as? String ?? ""
    }

    private func step(_ name: String, wait seconds: UInt32 = 0) {
        print("STEP \(ISO8601DateFormatter().string(from: Date())) \(name)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if seconds > 0 { sleep(seconds) }
    }

    func testSideBySide() throws {
        let host = XCUIApplication(bundleIdentifier: identifier("ProbeHostID"))
        let peer = XCUIApplication(bundleIdentifier: identifier("ProbePeerID"))
        peer.launch()
        step("peer launched", wait: 5)
        host.launch()
        step("host launched", wait: 30)
        peer.activate()
        step("peer activated", wait: 30)
        host.activate()
        step("host activated again", wait: 30)
        XCUIDevice.shared.press(.home)
        step("home screen", wait: 30)
        host.activate()
        step("host back", wait: 5)
        peer.activate()
        step("peer back", wait: 10)
        step("end")
    }
}
