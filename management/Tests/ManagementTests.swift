import XCTest
@testable import Tolkara_Management

final class ProfileTests: XCTestCase {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func profile(_ value: [String: Any], origin: AppProfile.Origin = .imported(file: URL(fileURLWithPath: "/x.json"))) throws -> AppProfile {
        try ProfileParser.parse(try JSONSerialization.data(withJSONObject: value), origin: origin)
    }

    let good: [String: Any] = ["id": "a", "name": "A", "workingDirectory": "Games/A", "executable": "A.app/Contents/MacOS/A"]

    func testShippedProfilesParse() throws {
        let catalog = ProfileParser.catalog(source: repository)
        XCTAssertEqual(catalog.problems, [])
        let forever = try XCTUnwrap(catalog.profiles.first { $0.id == "wow-forever" })
        XCTAssertTrue(forever.hasSetup)
        XCTAssertEqual(forever.destination, "World of Warcraft")
        XCTAssertEqual(forever.executableInSource, "_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft")
        XCTAssertEqual(forever.installerURL?.lastPathComponent, "install.py")
        XCTAssertNotNil(forever.risk)
        XCTAssertFalse(forever.risk!.history.isEmpty)
        // Profiles run by a compatibility runtime stay on the command line.
        XCTAssertFalse(catalog.profiles.first { $0.id == "heroes3-hota" }!.hasSetup)
    }

    /// The source the app carries offers WoW Forever by itself: users never supply its profile.
    func testBundledSourceOffersWoWForever() async throws {
        let archive = try XCTUnwrap(Bundle.main.url(forResource: "Tolkara-source", withExtension: "tar.gz"), "the app carries no source")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Shell.check("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        let catalog = ProfileParser.catalog(source: folder)
        let builtIn = catalog.profiles.filter { !$0.isImported && $0.hasSetup }
        XCTAssertEqual(builtIn.first { $0.id == "wow-forever" }?.installerURL?.lastPathComponent, "install.py")
        XCTAssertTrue(builtIn.contains { $0.id == "wow-classic-era" })
        XCTAssertNotNil(Workspace.bundledVersion())
    }

    func testDefaultsAndExecutable() throws {
        let parsed = try profile(good)
        XCTAssertEqual(parsed.destination, "Games")
        XCTAssertEqual(parsed.executable(inSource: URL(fileURLWithPath: "/Applications/Games")).path,
                       "/Applications/Games/A/A.app/Contents/MacOS/A")
        XCTAssertNil(parsed.installerURL)
    }

    func testImportedProfilesNeverRunInstallers() throws {
        let parsed = try profile(good.merging(["setup": ["installer": "install.py"]]) { $1 })
        XCTAssertNil(parsed.installerURL)
    }

    func testRejectsWhatCheckProfileRejects() {
        let bad: [[String: Any]] = [
            ["executable": "/bin/sh"], ["workingDirectory": "../x"], ["command": "x"], ["name": ""],
            ["setup": ["destination": "Other"]], ["setup": ["destination": "Games/A/B"]], ["setup": ["source": "relative"]],
            ["setup": ["installer": "../x.py"]], ["setup": ["getApp": ["name": "S", "url": "http://example.com"]]],
            ["setup": ["risk": ["summary": "x", "links": [["title": "x", "url": "javascript:alert(1)"]]]]],
            ["setup": ["risk": ["history": []]]], ["setup": ["run": "x"]],
            ["runtime": "R", "setup": [String: Any]()],
        ]
        for change in bad {
            XCTAssertThrowsError(try profile(good.merging(change) { $1 }), "\(change)")
        }
    }

    func testRiskDigestFollowsWording() throws {
        let one = try profile(good.merging(["setup": ["risk": ["summary": "One."]]]) { $1 })
        let two = try profile(good.merging(["setup": ["risk": ["summary": "Two."]]]) { $1 })
        XCTAssertNotEqual(one.risk!.digest, two.risk!.digest)
    }
}

final class LocalEnvTests: XCTestCase {
    func testRender() throws {
        let text = try LocalEnv.render(.init(team: "ABCDE12345", bundleID: "local.tolkara.abcde12345", device: "00000000-0001",
                                             executables: ["/Applications/World of Warcraft/_classic_beta_/W.app/Contents/MacOS/World of Warcraft"],
                                             ownProfiles: []))
        XCTAssertTrue(text.contains("DEVELOPMENT_TEAM=\"ABCDE12345\"\n"))
        XCTAssertTrue(text.contains("GUEST_EXE=\"/Applications/World of Warcraft/_classic_beta_/W.app/Contents/MacOS/World of Warcraft\"\n"))
        XCTAssertTrue(text.contains("TOLKARA_MODE=\"developer-service\"\n"))
        XCTAssertFalse(text.contains("TOLKARA_PROFILE"))
    }

    func testSeveralAndRejected() throws {
        let text = try LocalEnv.render(.init(team: "T", bundleID: "b", device: "d", executables: ["/a", "/b"], ownProfiles: ["/p.json", "/q.json"]))
        XCTAssertTrue(text.contains("GUEST_EXE=\"/a:/b\""))
        XCTAssertTrue(text.contains("TOLKARA_PROFILE=\"/p.json:/q.json\""))
        for path in ["/a$HOME", "/a\"b", "/a`x`", "/a\\b", "/a:b"] {
            XCTAssertThrowsError(try LocalEnv.render(.init(team: "T", bundleID: "b", device: "d", executables: [path], ownProfiles: [])), path)
        }
    }

    func testDefaultBundleID() {
        XCTAssertEqual(LocalEnv.defaultBundleID(team: "ABCDE12345"), "local.tolkara.abcde12345")
    }
}

final class DeviceTests: XCTestCase {
    func testParse() throws {
        let json = """
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"SIM","platform":"iOS","reality":"simulated","deviceType":"iPad"},
           "deviceProperties":{"name":"Simulator"},"connectionProperties":{"pairingState":"paired","transportType":"sameMachine","tunnelState":"connected"}},
          {"hardwareProperties":{"udid":"PHONE","platform":"iOS","reality":"physical","deviceType":"iPhone","marketingName":"iPhone 16 Pro Max"},
           "deviceProperties":{"name":"Phone","osVersionNumber":"27.0","developerModeStatus":"disabled"},
           "connectionProperties":{"pairingState":"unpaired","transportType":"wired","tunnelState":"disconnected"}},
          {"hardwareProperties":{"udid":"IPAD","platform":"iOS","reality":"physical","deviceType":"iPad","marketingName":"iPad Pro 11-inch (M5)"},
           "deviceProperties":{"name":"iPad","osVersionNumber":"27.0.1","developerModeStatus":"enabled"},
           "connectionProperties":{"pairingState":"paired","transportType":"localNetwork","tunnelState":"disconnected"}},
          {"hardwareProperties":{"udid":"OLD","platform":"iOS","reality":"physical","deviceType":"iPad"},
           "deviceProperties":{"name":"Old iPad","developerModeStatus":"enabled"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"}},
          {"hardwareProperties":{"udid":"WATCH","platform":"watchOS","reality":"physical","deviceType":"appleWatch"}}
        ]}}
        """
        let devices = Devices.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.id), ["IPAD", "PHONE", "OLD"])
        XCTAssertEqual(devices[0].osMajor, 27)
        XCTAssertEqual(devices[0].developerMode, true)
        XCTAssertTrue(devices[0].available && devices[0].paired && !devices[0].wired)
        XCTAssertFalse(devices[2].available)
        XCTAssertEqual(devices[1].developerMode, false)
        XCTAssertTrue(devices[1].wired && !devices[1].paired)
    }
}

final class MembershipTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func profile(days: Double, created: Date? = nil, entitlements: [String: Any] = [:]) -> [String: Any] {
        let created = created ?? now.addingTimeInterval(-86400)
        return ["TeamIdentifier": ["ABCDE12345"], "TeamName": "Example", "CreationDate": created,
                "ExpirationDate": created.addingTimeInterval(days * 86400), "Entitlements": entitlements]
    }

    func testProfileLifetime() {
        XCTAssertEqual(MembershipScanner.team(fromProfile: profile(days: 365), now: now)?.kind, .paid)
        XCTAssertEqual(MembershipScanner.team(fromProfile: profile(days: 7), now: now)?.kind, .free)
        XCTAssertEqual(MembershipScanner.team(fromProfile: profile(days: 7, entitlements: ["com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]]), now: now)?.kind, .paid)
        XCTAssertEqual(MembershipScanner.team(fromProfile: profile(days: 365, created: now.addingTimeInterval(-400 * 86400)), now: now)?.kind, .expired)
        XCTAssertNil(MembershipScanner.team(fromProfile: ["TeamIdentifier": ["short"]], now: now))
    }

    func testXcodeDefaults() {
        let defaults: [String: Any] = ["IDEProvisioningTeamByIdentifier": [
            "account-1": [["teamID": "ABCDE12345", "teamName": "Paid Team", "isFreeProvisioningTeam": false, "teamType": "Individual"],
                          ["teamID": "FREE123456", "teamName": "Me (Personal Team)", "isFreeProvisioningTeam": true]],
        ]]
        let teams = MembershipScanner.teams(fromXcodeDefaults: defaults)
        XCTAssertEqual(Set(teams.map { "\($0.id):\($0.kind)" }), ["ABCDE12345:paid", "FREE123456:free"])
    }

    func testExpiryOfTheAppsProfile() {
        let old = ["Entitlements": ["application-identifier": "ABCDE12345.local.tolkara.x"], "ExpirationDate": now] as [String: Any]
        let new = ["Entitlements": ["application-identifier": "ABCDE12345.local.tolkara.x"], "ExpirationDate": now.addingTimeInterval(86400)] as [String: Any]
        let other = ["Entitlements": ["application-identifier": "ABCDE12345.other"], "ExpirationDate": now.addingTimeInterval(9e6)] as [String: Any]
        XCTAssertEqual(MembershipScanner.expiry(team: "ABCDE12345", bundleID: "local.tolkara.x", in: [old, new, other]), now.addingTimeInterval(86400))
        XCTAssertNil(MembershipScanner.expiry(team: "ABCDE12345", bundleID: "missing", in: [old]))
    }

    func testMergeKeepsStrongest() {
        let merged = MembershipScanner.merge([
            DeveloperTeam(id: "ABCDE12345", name: "B", kind: .free, evidence: "x"),
            DeveloperTeam(id: "ABCDE12345", name: "B", kind: .paid, evidence: "y"),
            DeveloperTeam(id: "ZZZZZ12345", name: "A", kind: .free, evidence: "z"),
        ])
        XCTAssertEqual(merged.map(\.id), ["ABCDE12345", "ZZZZZ12345"])
        XCTAssertEqual(merged[0].kind, .paid)
    }
}

final class DiagnosisTests: XCTestCase {
    func testKnownFailures() {
        XCTAssertEqual(Diagnoser.diagnose("error: Personal development teams, including \"Me\", do not support the Network Extensions capability.", source: nil)?.step, .membership)
        XCTAssertEqual(Diagnoser.diagnose("ERROR: The device is locked.\n device is locked", source: nil)?.title, "Your device is locked")
        XCTAssertNil(Diagnoser.diagnose("something unexpected", source: nil))
    }

    func testReadsTheNamedLog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "error: No Accounts: Add a new account in Accounts settings.".write(to: folder.appendingPathComponent("logs/install-1.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Diagnoser.diagnose("BUILD FAILED -> logs/install-1.log", source: folder)?.step, .membership)
    }

    func testBuildActivity() {
        XCTAssertEqual(BuildActivity.describe("CompileC /x/NativeGuest.o /Users/me/runtime/NativeGuest.m normal arm64 objective-c"), "Compiling NativeGuest.m")
        XCTAssertEqual(BuildActivity.describe("CodeSign /x/Tolkara.app (in target 'Tolkara')"), "Signing Tolkara.app")
        XCTAssertNil(BuildActivity.describe("    cd /Users/me"))
    }
}

final class StateTests: XCTestCase {
    func testPartialStateKeepsWhatItCan() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SetupState.self, from: Data(#"{"welcomed":true,"device":"D","profiles":["wow-forever"],"future":1}"#.utf8))
        XCTAssertTrue(state.welcomed)
        XCTAssertEqual(state.device, "D")
        XCTAssertEqual(state.profiles, ["wow-forever"])
        XCTAssertTrue(state.checkForUpdates)
    }
}

final class LibraryTests: XCTestCase {
    func testLauncherLibrary() throws {
        let json = """
        {"format":1,"apps":[
          {"id":"a","name":"World of Warcraft Forever","executable":"World of Warcraft/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft","profile":"wow-forever","lastLaunched":1790000000},
          {"id":"b","name":"Mine","executable":"Mine/Mine.app/Contents/MacOS/Mine"},
          {"id":"c","name":"Escape","executable":"../x"}]}
        """
        let entries = try XCTUnwrap(DeviceLibraryReader.entries(fromLibrary: Data(json.utf8)))
        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        XCTAssertEqual(entries[0].profile, "wow-forever")
        XCTAssertEqual(entries[0].lastLaunched, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(DeviceLibraryReader.entries(fromLibrary: Data(#"{"format":2,"apps":[]}"#.utf8)))
    }

    func testFilesAndVersion() throws {
        let json = """
        {"result":{"files":[
          {"relativePath":"Data","metadata":{"size":96},"resources":{"isDirectory":true}},
          {"relativePath":"Data/a.idx","metadata":{"size":1000},"resources":{"isDirectory":false}}]}}
        """
        let files = try XCTUnwrap(Devices.parseFiles(Data(json.utf8)))
        XCTAssertEqual(files, [.init(path: "Data", size: 96, isDirectory: true), .init(path: "Data/a.idx", size: 1000, isDirectory: false)])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.60.1"], format: .xml, options: 0)
        XCTAssertEqual(DeviceLibraryReader.version(fromInfoPlist: plist), "1.60.1")
    }

    func testFindsTolkaraInstalledByHand() {
        let json = """
        {"result":{"apps":[{"name":"Tolkara","bundleIdentifier":"local.tolkara.mine","builtByDeveloper":true},
                           {"name":"Other","bundleIdentifier":"com.example.other","builtByDeveloper":true}]}}
        """
        XCTAssertEqual(Devices.tolkaraInstalls(fromApps: Data(json.utf8)), ["local.tolkara.mine"])
    }

    func testPathsAndUpdates() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let profiles = ProfileParser.catalog(source: repository).profiles
        let forever = try XCTUnwrap(profiles.first { $0.id == "wow-forever" })
        XCTAssertEqual(forever.documentsExecutable, "World of Warcraft/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft")
        XCTAssertEqual(forever.infoPlistPath, "World of Warcraft/_classic_beta_/World of Warcraft Beta.app/Contents/Info.plist")
        let heroes = try XCTUnwrap(profiles.first { $0.id == "heroes3-hota" })
        XCTAssertEqual(heroes.documentsExecutable, "Heroes 3 HotA/Wine/lib/wine/aarch64-unix/wine")
        XCTAssertNil(heroes.infoPlistPath)

        let game = DeviceGame(id: "g", name: "G", executable: "G/G.app/Contents/MacOS/G", executableSize: 100, version: "1.0")
        XCTAssertFalse(MacCopy(version: "1.0", executableSize: 100).isNewer(than: game))
        XCTAssertTrue(MacCopy(version: "1.1", executableSize: 100).isNewer(than: game))
        XCTAssertTrue(MacCopy(version: "1.0", executableSize: 101).isNewer(than: game))
        XCTAssertEqual(game.infoPlist, "G/G.app/Contents/Info.plist")
        XCTAssertFalse(SetupStep.setup.contains(.library))
    }

    /// Reads a real device's library: TEST_RUNNER_TOLKARA_LIVE_DEVICE=<UDID>
    /// and TEST_RUNNER_TOLKARA_LIVE_BUNDLE=<bundle ID> on the xcodebuild command line.
    @MainActor func testLiveDeviceLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let udid = environment["TOLKARA_LIVE_DEVICE"], let bundleID = environment["TOLKARA_LIVE_BUNDLE"] else {
            throw XCTSkip("No live device given.")
        }
        let xcode = try XCTUnwrap(Toolchain.findXcode())
        let devices = try await Devices.list(xcode: xcode)
        let device = try XCTUnwrap(devices.first { $0.id == udid })
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = try await DeviceLibraryReader.read(profiles: ProfileParser.catalog(source: repository).profiles,
                                                         bundleID: bundleID, device: device, xcode: xcode)
        for folder in library.folders {
            print("LIVE folder \(folder.name) \(folder.size.bytes): " + folder.games.map { "\($0.id) v\($0.version ?? "-") size \($0.executableSize ?? -1) played \($0.lastLaunched.map { "\($0)" } ?? "-")" }.joined(separator: "; "))
        }
        XCTAssertFalse(library.folders.isEmpty)
    }
}
