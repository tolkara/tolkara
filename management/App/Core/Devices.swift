import Foundation

/// An iPad or iPhone as Xcode's devicectl reports it.
struct Device: Identifiable, Hashable {
    var id: String              // UDID: what xcodebuild and devicectl are given
    var name: String
    var model: String           // "iPad Pro 11-inch (M5)"
    var type: String            // "iPad", "iPhone"
    var osVersion: String
    var paired: Bool
    var developerMode: Bool?    // nil: not known until paired
    var wired: Bool
    var available: Bool         // connected now, not just remembered

    var osMajor: Int { Int(osVersion.split(separator: ".").first ?? "") ?? 0 }
    var isIPad: Bool { type == "iPad" }
}

enum Devices {
    /// Physical iPads and iPhones, iPads first.
    static func list(xcode: XcodeInstallation) async throws -> [Device] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--json-output", output.path],
                              environment: Toolchain.environment(xcode: xcode))
        return parse(try Data(contentsOf: output))
    }

    static func parse(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { entry -> Device? in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard let udid = hardware["udid"] as? String, hardware["platform"] as? String == "iOS",
                  (hardware["reality"] as? String ?? "physical") == "physical" else { return nil }
            let type = hardware["deviceType"] as? String ?? "Device"
            guard type == "iPad" || type == "iPhone" else { return nil }
            let developerMode: Bool?
            switch properties["developerModeStatus"] as? String {
            case "enabled": developerMode = true
            case "disabled": developerMode = false
            default: developerMode = nil
            }
            let transport = connection["transportType"] as? String
            let tunnel = connection["tunnelState"] as? String
            return Device(id: udid, name: properties["name"] as? String ?? type,
                          model: hardware["marketingName"] as? String ?? type, type: type,
                          osVersion: properties["osVersionNumber"] as? String ?? "",
                          paired: connection["pairingState"] as? String == "paired",
                          developerMode: developerMode, wired: transport == "wired",
                          available: transport != nil && tunnel != "unavailable")
        }.sorted { a, b in
            (a.available ? 0 : 1, a.isIPad ? 0 : 1, a.name.localizedLowercase) < (b.available ? 0 : 1, b.isIPad ? 0 : 1, b.name.localizedLowercase)
        }
    }

    /// Asks the device to trust this Mac (the Trust prompt on the iPad).
    static func pair(_ device: Device, xcode: XcodeInstallation) async throws {
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "manage", "pair", "--device", device.id],
                              environment: Toolchain.environment(xcode: xcode))
    }

    /// Copies of Tolkara on the device built by a developer, whatever their
    /// bundle ID: one installed by hand (tools/install.sh) can be adopted.
    static func tolkaraInstalls(on device: Device, xcode: XcodeInstallation) async -> [String] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let result = try? await Shell.run("/usr/bin/xcrun", ["devicectl", "device", "info", "apps", "--device", device.id,
                                                                  "--quiet", "--json-output", output.path],
                                                environment: Toolchain.environment(xcode: xcode)), result.succeeded,
              let data = try? Data(contentsOf: output) else { return [] }
        return tolkaraInstalls(fromApps: data)
    }

    static func tolkaraInstalls(fromApps data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else { return [] }
        return apps.filter { $0["name"] as? String == "Tolkara" && $0["builtByDeveloper"] as? Bool != false }
            .compactMap { $0["bundleIdentifier"] as? String }.sorted()
    }

    static func isInstalled(bundleID: String, on device: Device, xcode: XcodeInstallation) async -> Bool {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let result = try? await Shell.run("/usr/bin/xcrun", ["devicectl", "device", "info", "apps", "--device", device.id,
                                                                  "--bundle-id", bundleID, "--quiet", "--json-output", output.path],
                                                environment: Toolchain.environment(xcode: xcode)), result.succeeded,
              let data = try? Data(contentsOf: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = (root["result"] as? [String: Any])?["apps"] as? [[String: Any]] else { return false }
        return apps.contains { $0["bundleIdentifier"] as? String == bundleID }
    }

    /// Opens Tolkara on the device (its library), as tapping its icon would.
    static func launch(bundleID: String, on device: Device, xcode: XcodeInstallation) async throws {
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--terminate-existing",
                                                 "--device", device.id, bundleID], environment: Toolchain.environment(xcode: xcode))
    }

    /// Copies a file from Tolkara's container on the device to the Mac.
    static func copyFromApp(_ path: String, to destination: URL, bundleID: String, device: Device, xcode: XcodeInstallation) async throws {
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "device", "copy", "from", "--device", device.id,
                                                 "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                                                 "--source", path, "--destination", destination.path],
                              environment: Toolchain.environment(xcode: xcode))
    }

    struct RemoteFile: Hashable {
        var path: String        // relative to the listed folder
        var size: Int64
        var isDirectory: Bool
    }

    /// Files in Tolkara's container on the device; nil if the folder is missing.
    static func listFiles(_ folder: String, recurse: Bool, bundleID: String, device: Device, xcode: XcodeInstallation) async throws -> [RemoteFile]? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await Shell.run("/usr/bin/xcrun", ["devicectl", "device", "info", "files", "--device", device.id,
                                                           "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                                                           "--subdirectory", folder, recurse ? "--recurse" : "--no-recurse",
                                                           "--quiet", "--json-output", output.path],
                                         environment: Toolchain.environment(xcode: xcode))
        guard result.succeeded, let data = try? Data(contentsOf: output) else { return nil }
        return parseFiles(data)
    }

    static func parseFiles(_ data: Data) -> [RemoteFile]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = (root["result"] as? [String: Any])?["files"] as? [[String: Any]] else { return nil }
        return files.compactMap { entry in
            guard let path = entry["relativePath"] as? String else { return nil }
            let metadata = entry["metadata"] as? [String: Any] ?? [:]
            let resources = entry["resources"] as? [String: Any] ?? [:]
            return RemoteFile(path: path, size: (metadata["size"] as? NSNumber)?.int64Value ?? 0,
                              isDirectory: resources["isDirectory"] as? Bool ?? false)
        }
    }

    /// A small file from Tolkara's container, or nil if it is not there.
    static func readFromApp(_ path: String, bundleID: String, device: Device, xcode: XcodeInstallation) async -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        guard (try? await copyFromApp(path, to: file, bundleID: bundleID, device: device, xcode: xcode)) != nil else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Starts Tolkara with development arguments (a status screen, not the library).
    static func launch(bundleID: String, arguments: [String], on device: Device, xcode: XcodeInstallation) async throws {
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "device", "process", "launch", "--terminate-existing",
                                                 "--device", device.id, bundleID] + arguments,
                              environment: Toolchain.environment(xcode: xcode))
    }

    /// Copies a folder from the Mac into Tolkara's Documents on the device.
    static func copyToApp(_ source: URL, destination: String, bundleID: String, device: Device, xcode: XcodeInstallation,
                          line: @escaping @Sendable (String) -> Void) async throws {
        try await Shell.check("/usr/bin/xcrun", ["devicectl", "device", "copy", "to", "--device", device.id,
                                                 "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                                                 "--source", source.path, "--destination", destination],
                              environment: Toolchain.environment(xcode: xcode), line: line)
    }
}
