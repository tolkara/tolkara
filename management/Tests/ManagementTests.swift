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
        XCTAssertEqual(forever.executableInSource, "_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft")
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

/// setup.firstRun: the game must have started once on this Mac, which saves
/// its region and language (WoW's WTF/Config.wtf), or it quits on the device.
final class FirstRunTests: XCTestCase {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let configured = "SET accountName \"someone@example.com\"\nSET portal \"eu\"\nSET textLocale \"deDE\"\nSET audioLocale \"deDE\"\nSET gxApi \"metal\"\n"
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func shipped(_ id: String) throws -> AppProfile {
        try XCTUnwrap(ProfileParser.catalog(source: repository).profiles.first { $0.id == id })
    }

    /// A fixture "World of Warcraft" folder as Battle.net leaves it: the client,
    /// and a Config.wtf only once the game has started (nil: never started).
    func game(_ profile: AppProfile, config: String?) throws -> URL {
        let source = folder.appendingPathComponent(profile.destination)
        let executable = profile.executable(inSource: source)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let settings = source.appendingPathComponent(try XCTUnwrap(profile.firstRun).settings)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let config { try config.write(to: settings, atomically: true, encoding: .utf8) }
        return source
    }

    func testShippedWoWProfilesNeedAFirstRun() throws {
        for (id, client) in [("wow-classic-era", "_classic_era_"), ("wow-forever", "_forever_")] {
            let firstRun = try XCTUnwrap(try shipped(id).firstRun, id)
            XCTAssertEqual(firstRun.settings, "\(client)/WTF/Config.wtf")
            XCTAssertEqual(firstRun.keys, ["portal", "textLocale", "audioLocale"])
            XCTAssertTrue(firstRun.steps.contains { $0.contains("Battle.net") })
            XCTAssertEqual(try shipped(id).firstRunDevicePath, "Documents/World of Warcraft/\(client)/WTF/Config.wtf")
        }
        XCTAssertNil(try shipped("heroes3-hota").firstRun)
    }

    func testFixtureFolders() throws {
        for id in ["wow-classic-era", "wow-forever"] {
            let profile = try shipped(id)
            let firstRun = try XCTUnwrap(profile.firstRun)
            // Installed by Battle.net and never started: the tutorial case.
            var check = FirstRunCheck.check(firstRun, source: try game(profile, config: nil))
            XCTAssertFalse(check.isDone)
            XCTAssertFalse(check.fileExists)
            XCTAssertEqual(check.missing, ["portal", "textLocale", "audioLocale"])
            // Started, but no region saved (graphics settings only).
            check = FirstRunCheck.check(firstRun, source: try game(profile, config: "SET gxApi \"metal\"\nSET portal \"\"\n"))
            XCTAssertTrue(check.fileExists)
            XCTAssertEqual(check.missing, ["portal", "textLocale", "audioLocale"])
            check = FirstRunCheck.check(firstRun, source: try game(profile, config: "SET portal \"us\"\nSET textLocale \"enUS\"\n"))
            XCTAssertEqual(check.missing, ["audioLocale"])
            // Started from Battle.net, region and languages chosen.
            check = FirstRunCheck.check(firstRun, source: try game(profile, config: configured))
            XCTAssertTrue(check.isDone)
            XCTAssertEqual(check.values, ["portal": "eu", "textLocale": "deDE", "audioLocale": "deDE"])
            XCTAssertEqual(check.summary, "eu · deDE · deDE")
            try FileManager.default.removeItem(at: folder.appendingPathComponent(profile.destination))
        }
    }

    func testOnlyTheNamedKeysAreRead() {
        let keys = ["portal", "textLocale", "audioLocale"]
        XCTAssertEqual(FirstRunCheck.values(in: configured, keys: keys).keys.sorted(), ["audioLocale", "portal", "textLocale"])
        XCTAssertEqual(FirstRunCheck.values(in: "SET portal \"test\"\r\n  SET textLocale \"enUS\"  \n# SET audioLocale \"enUS\"\nSET audioLocale \"en US\"", keys: keys),
                       ["portal": "test", "textLocale": "enUS"])
        XCTAssertEqual(FirstRunCheck.values(in: "", keys: keys), [:])
    }

    func testDeviceSettings() throws {
        let firstRun = try XCTUnwrap(try shipped("wow-classic-era").firstRun)
        let mac = FirstRunCheck.check(firstRun, deviceFile: Data(configured.utf8))
        let none = FirstRunCheck.check(firstRun, deviceFile: nil)
        let other = FirstRunCheck.check(firstRun, deviceFile: Data("SET graphicsQuality \"2\"\nSET portal \"us\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\n".utf8))
        let macNever = FirstRunCheck(keys: firstRun.keys, fileExists: false, values: [:])
        XCTAssertFalse(none.fileExists)
        // Copied by Tolkara 0.2.0 from a Mac where the game never started.
        XCTAssertEqual(DeviceSettings.compare(mac: macNever, device: none), .startOnMac)
        XCTAssertEqual(DeviceSettings.compare(mac: nil, device: none), .startOnMac)
        // Started on the Mac since: Copy Again.
        XCTAssertEqual(DeviceSettings.compare(mac: mac, device: none), .copyAgain(changed: false))
        XCTAssertEqual(DeviceSettings.compare(mac: mac, device: other), .copyAgain(changed: true))
        XCTAssertEqual(DeviceSettings.compare(mac: mac, device: mac), .fine)
        // The device keeps what it has when this Mac's settings are gone.
        XCTAssertEqual(DeviceSettings.compare(mac: macNever, device: other), .fine)
        // Not read (a profile without firstRun): nothing to say.
        XCTAssertEqual(DeviceSettings.compare(mac: nil, device: nil), .fine)
    }

    func testProfileRules() throws {
        let good: [String: Any] = ["id": "a", "name": "A", "workingDirectory": "Games/A", "executable": "A.app/Contents/MacOS/A"]
        let firstRun: [String: Any] = ["settings": "A/WTF/Config.wtf", "keys": ["portal"], "steps": ["Start **A** once."]]
        let parsed = try ProfileParser.parse(try JSONSerialization.data(withJSONObject: good.merging(["setup": ["firstRun": firstRun]]) { $1 }),
                                             origin: .imported(file: URL(fileURLWithPath: "/x.json")))
        XCTAssertEqual(parsed.firstRun, .init(settings: "A/WTF/Config.wtf", keys: ["portal"], steps: ["Start **A** once."]))
        // The same rejections as tools/check_profile.py.
        let bad: [[String: Any]] = [
            ["settings": "/Applications/A/Config.wtf"], ["settings": "../Config.wtf"], ["settings": ""], ["keys": [String]()],
            ["keys": "portal"], ["keys": ["por tal"]], ["keys": ["portal\""]], ["keys": [1]], ["keys": (0..<17).map { "k\($0)" }],
            ["steps": "Start"], ["steps": [""]], ["steps": Array(repeating: "x", count: 17)], ["run": "x"],
        ]
        for change in bad {
            let value = good.merging(["setup": ["firstRun": firstRun.merging(change) { $1 }]]) { $1 }
            XCTAssertThrowsError(try ProfileParser.parse(try JSONSerialization.data(withJSONObject: value), origin: .imported(file: URL(fileURLWithPath: "/x.json"))), "\(change)")
        }
        for missing in ["settings", "keys"] {
            let value = good.merging(["setup": ["firstRun": firstRun.filter { $0.key != missing }]]) { $1 }
            XCTAssertThrowsError(try ProfileParser.parse(try JSONSerialization.data(withJSONObject: value), origin: .imported(file: URL(fileURLWithPath: "/x.json"))), missing)
        }
    }

    func testCopyRefusalPointsToTheGameStep() {
        // The app's own refusal and the copy helper's (tools/first_run.py) lead to the Game step.
        XCTAssertEqual(Diagnoser.diagnose(FirstRunError(profile: "World of Warcraft Classic").localizedDescription, source: nil)?.step, .game)
        XCTAssertEqual(Diagnoser.diagnose("_classic_era_/WTF/Config.wtf on this Mac has no portal, textLocale, audioLocale.\nThe game has not been started on this Mac yet", source: nil)?.step, .game)
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

    /// Xcode freshly signed in on a Mac that never signed anything: the
    /// account is saved, its teams are not (seen in Tolkara 0.2.0's tutorial).
    func testSignedInXcodeWithoutSavedTeams() {
        let fresh: [String: Any] = ["DVTDeveloperAccountManagerAppleIDLists": ["IDE.Identifiers.Prod": [["identifier": "6111FB51-AC94-4D21-86C0-000000000000"]]]]
        XCTAssertEqual(MembershipScanner.accountCount(fromXcodeDefaults: fresh), 1)
        XCTAssertEqual(MembershipScanner.teams(fromXcodeDefaults: fresh), [])
        let older: [String: Any] = ["DVTDeveloperAccountManagerAppleIDLists": ["IDE.Prod": [["username": "me@example.com"], ["username": "you@example.com"]],
                                                                               "IDE.Identifiers.QA": [["identifier": "test"]]]]
        XCTAssertEqual(MembershipScanner.accountCount(fromXcodeDefaults: older), 2)
        XCTAssertEqual(MembershipScanner.accountCount(fromXcodeDefaults: [:]), 0)
        XCTAssertEqual(MembershipScanner.accountCount(fromXcodeDefaults: ["DVTDeveloperAccountManagerAppleIDLists": ["IDE.Identifiers.Prod": []]]), 0)
    }

    func testCertificateTeam() {
        let development = MembershipScanner.SigningCertificate(commonName: "Apple Development: Jane Doe (Q1W2E3R4T5)", teamID: "ABCDE12345",
                                                               teamName: "Jane Doe", expires: now.addingTimeInterval(86400))
        let team = MembershipScanner.team(fromCertificate: development, now: now)
        // The team is the organizational unit, not the ID in the common name; its kind waits for the build.
        XCTAssertEqual(team, DeveloperTeam(id: "ABCDE12345", name: "Jane Doe", kind: .unknown, evidence: "Signing certificate"))
        var expired = development
        expired.expires = now.addingTimeInterval(-1)
        XCTAssertNil(MembershipScanner.team(fromCertificate: expired, now: now))
        var other = development
        other.commonName = "My Own Signing Certificate"
        XCTAssertNil(MembershipScanner.team(fromCertificate: other, now: now))
        var noTeam = development
        noTeam.teamID = "Engineering"
        XCTAssertNil(MembershipScanner.team(fromCertificate: noTeam, now: now))
    }

    func testCertificateValues() {
        let field = { (oid: CFString, value: String) -> [String: Any] in
            [kSecPropertyKeyLabel as String: oid as String, kSecPropertyKeyValue as String: value]
        }
        let values: [String: Any] = [
            kSecOIDX509V1SubjectName as String: [kSecPropertyKeyValue as String: [
                field("0.9.2342.19200300.100.1.1" as CFString, "Q1W2E3R4T5"), field(kSecOIDCommonName, "Apple Development: Jane Doe (Q1W2E3R4T5)"),
                field(kSecOIDOrganizationalUnitName, "ABCDE12345"), field(kSecOIDOrganizationName, "Jane Doe"), field(kSecOIDCountryName, "US"),
            ]],
            kSecOIDX509V1ValidityNotAfter as String: [kSecPropertyKeyValue as String: NSNumber(value: now.timeIntervalSinceReferenceDate)],
        ]
        XCTAssertEqual(MembershipScanner.certificate(fromValues: values),
                       MembershipScanner.SigningCertificate(commonName: "Apple Development: Jane Doe (Q1W2E3R4T5)", teamID: "ABCDE12345", teamName: "Jane Doe", expires: now))
        XCTAssertNil(MembershipScanner.certificate(fromValues: [:]))
    }

    func testTeamProbe() async throws {
        XCTAssertEqual(TeamProbe.teams(inProjectFile: TeamProbe.pbxproj), [])
        let chosen = TeamProbe.pbxproj.replacingOccurrences(of: "CODE_SIGN_STYLE = Automatic;", with: "CODE_SIGN_STYLE = Automatic;\n\t\t\tDEVELOPMENT_TEAM = ABCDE12345;")
        XCTAssertEqual(TeamProbe.teams(inProjectFile: chosen), ["ABCDE12345"])
        XCTAssertEqual(TeamProbe.teams(inProjectFile: "DEVELOPMENT_TEAM = \"ZZZZZ12345\";\nDEVELOPMENT_TEAM = ZZZZZ12345;\nDEVELOPMENT_TEAM = \"\";"), ["ZZZZZ12345"])

        // Xcode accepts the project as written, and creating it again keeps the user's choice.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try TeamProbe.create(in: folder)
        let file = project.appendingPathComponent("project.pbxproj")
        try chosen.write(to: file, atomically: true, encoding: .utf8)
        try TeamProbe.create(in: folder)
        XCTAssertEqual(TeamProbe.teams(inProjectFile: try String(contentsOf: file, encoding: .utf8)), ["ABCDE12345"])
        let xcode = try XCTUnwrap(Toolchain.findXcode())
        let list = try await Shell.check(xcode.developerDirectory + "/usr/bin/xcodebuild", ["-list", "-project", project.path],
                                         environment: Toolchain.environment(xcode: xcode))
        XCTAssertTrue(list.output.contains("Team Check"), list.output)
        let settings = try await Shell.check(xcode.developerDirectory + "/usr/bin/xcodebuild", ["-showBuildSettings", "-project", project.path],
                                             environment: Toolchain.environment(xcode: xcode))
        XCTAssertTrue(settings.output.contains("DEVELOPMENT_TEAM = ABCDE12345"), settings.output)
        XCTAssertTrue(settings.output.contains("CODE_SIGN_STYLE = Automatic"))
    }

    func testTypedTeamID() {
        XCTAssertEqual(MembershipScanner.teamID(fromTyped: " abcde12345 "), "ABCDE12345")
        XCTAssertEqual(MembershipScanner.teamID(fromTyped: "ABCDE 12345"), "ABCDE12345")
        XCTAssertEqual(MembershipScanner.teamID(fromTyped: "Team ID: ABCDE12345"), "ABCDE12345")
        XCTAssertNil(MembershipScanner.teamID(fromTyped: "ABCDE1234"))
        XCTAssertNil(MembershipScanner.teamID(fromTyped: "ABCDE12345 ZZZZZ12345"))
        XCTAssertNil(MembershipScanner.teamID(fromTyped: "ABCDE-12345"))
    }

    func testMergeKeepsStrongest() {
        let merged = MembershipScanner.merge([
            DeveloperTeam(id: "ABCDE12345", name: "B", kind: .free, evidence: "x"),
            DeveloperTeam(id: "ABCDE12345", name: "B", kind: .paid, evidence: "y"),
            DeveloperTeam(id: "ZZZZZ12345", name: "A", kind: .free, evidence: "z"),
        ])
        XCTAssertEqual(merged.map(\.id), ["ABCDE12345", "ZZZZZ12345"])
        XCTAssertEqual(merged[0].kind, .paid)
        // A team chosen in Xcode keeps the name its certificate gives it.
        let named = MembershipScanner.merge([
            DeveloperTeam(id: "ABCDE12345", name: "Team ABCDE12345", kind: .unknown, evidence: "Chosen in Xcode"),
            DeveloperTeam(id: "ABCDE12345", name: "Jane Doe", kind: .unknown, evidence: "Signing certificate"),
        ])
        XCTAssertEqual(named.map(\.name), ["Jane Doe"])
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
        // The build tells two updates apart when the short version stays the same.
        XCTAssertEqual(DeviceLibraryReader.version(of: ["CFBundleShortVersionString": "1.60.1", "CFBundleVersion": "1.60.1.70938"]), "1.60.1.70938")
        XCTAssertEqual(DeviceLibraryReader.version(of: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "412"]), "2.1 (412)")
        XCTAssertEqual(DeviceLibraryReader.version(of: ["CFBundleVersion": "412"]), "412")
        XCTAssertNil(DeviceLibraryReader.version(of: [:]))
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
        XCTAssertEqual(forever.documentsExecutable, "World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft")
        XCTAssertEqual(forever.infoPlistPath, "World of Warcraft/_forever_/World of Warcraft.app/Contents/Info.plist")
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
