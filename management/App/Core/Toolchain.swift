import AppKit

/// Where Tolkara Management keeps its own files: the unpacked Tolkara source
/// (with the user's local.env and build output), downloaded tools, imported
/// profiles and its state. Nothing here leaves the Mac.
enum AppPaths {
    /// TOLKARA_MANAGEMENT_SUPPORT replaces it, so a second copy (for
    /// screenshots or tests) leaves the user's own state alone.
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = ProcessInfo.processInfo.environment["TOLKARA_MANAGEMENT_SUPPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("Tolkara Management", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var tools: URL { support.appendingPathComponent("Tools", isDirectory: true) }
    static var profiles: URL { support.appendingPathComponent("Profiles", isDirectory: true) }
    static var state: URL { support.appendingPathComponent("state.json") }
}

struct XcodeInstallation: Equatable {
    var url: URL
    var version: String
    var developerDirectory: String { url.appendingPathComponent("Contents/Developer").path }
    var majorVersion: Int { Int(version.split(separator: ".").first ?? "") ?? 0 }
}

/// Xcode, XcodeGen and Python: what Tolkara's own scripts need on the Mac.
enum Toolchain {
    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    static let xcodeAppStore = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!
    static let xcodegenRelease = URL(string: "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip")!

    /// The newest Xcode installed, wherever it is (xcode-select may point at the
    /// Command Line Tools, so it is not consulted).
    static func findXcode() -> XcodeInstallation? {
        var urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: xcodeBundleIdentifier)
        let standard = URL(fileURLWithPath: "/Applications/Xcode.app")
        if FileManager.default.fileExists(atPath: standard.path), !urls.contains(standard) { urls.append(standard) }
        return urls.compactMap { url -> XcodeInstallation? in
            guard let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Developer/usr/bin/xcodebuild").path)
            else { return nil }
            return XcodeInstallation(url: url, version: version)
        }.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Our own copy first, then Homebrew's.
    static var xcodegen: String? {
        [AppPaths.tools.appendingPathComponent("xcodegen/bin/xcodegen").path, "/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The environment for Tolkara's scripts: a GUI app starts with a minimal
    /// PATH, and none of the builder settings a terminal might carry, so that
    /// local.env (written by us) is what the scripts read.
    static func environment(xcode: XcodeInstallation?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("TOLKARA_") || ["DEVICE", "DEVELOPMENT_TEAM", "GUEST_EXE", "NATIVE_GUEST_SHIMS", "SIGN_IDENTITY",
                                           "SIMULATOR", "DEVELOPER_DIR", "PYTHONPATH", "PYTHONHOME"].contains(key))
        }
        var path: [String] = []
        if let xcodegen { path.append(URL(fileURLWithPath: xcodegen).deletingLastPathComponent().path) }
        path += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = path.joined(separator: ":")
        if let xcode { environment["DEVELOPER_DIR"] = xcode.developerDirectory }
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        return environment
    }

    /// Whether Xcode's first-launch setup (licence, system components) is done.
    static func firstLaunchDone(_ xcode: XcodeInstallation) async -> Bool {
        let result = try? await Shell.run(xcode.developerDirectory + "/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"],
                                          environment: environment(xcode: xcode))
        return result?.succeeded ?? false
    }

    /// The iOS SDK version Xcode builds with, for example "27.0".
    static func iosSDKVersion(_ xcode: XcodeInstallation) async -> String? {
        let result = try? await Shell.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"], environment: environment(xcode: xcode))
        guard let result, result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pythonVersion(_ xcode: XcodeInstallation?) async -> String? {
        let result = try? await Shell.run("/usr/bin/env", ["python3", "--version"], environment: environment(xcode: xcode))
        guard let result, result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Python ", with: "")
    }

    /// XcodeGen through Homebrew when the user has it, otherwise its official
    /// release from GitHub into our own Tools folder.
    static func installXcodegen(line: @escaping @Sendable (String) -> Void) async throws {
        if let brew {
            try await Shell.check(brew, ["install", "xcodegen"], environment: environment(xcode: nil), line: line)
            return
        }
        line("Downloading XcodeGen from \(xcodegenRelease.absoluteString)…")
        let (download, response) = try await URLSession.shared.download(from: xcodegenRelease)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: AppPaths.tools, withIntermediateDirectories: true)
        let unpacked = AppPaths.tools.appendingPathComponent("xcodegen-download", isDirectory: true)
        try? fileManager.removeItem(at: unpacked)
        try await Shell.check("/usr/bin/ditto", ["-x", "-k", download.path, unpacked.path], line: line)
        let target = AppPaths.tools.appendingPathComponent("xcodegen", isDirectory: true)
        guard fileManager.isExecutableFile(atPath: unpacked.appendingPathComponent("xcodegen/bin/xcodegen").path) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The XcodeGen download did not contain xcodegen."])
        }
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: unpacked.appendingPathComponent("xcodegen"), to: target)
        try? fileManager.removeItem(at: unpacked)
        line("Installed XcodeGen in \(target.path).")
    }

    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
