import Foundation
import CryptoKit

/// A game Tolkara has on the device.
struct DeviceGame: Identifiable, Hashable {
    var id: String              // profile id, or the launcher's entry id
    var name: String
    var profile: AppProfile?
    var executable: String      // relative to Documents
    var executableSize: Int64?
    var version: String?        // the copy on the device
    var lastLaunched: Date?
}

/// A folder in Tolkara's Documents that holds games. Games can share one
/// (both WoW clients use "World of Warcraft" and its Data), and a folder is
/// what can be removed.
struct DeviceFolder: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var size: Int64
    var games: [DeviceGame]
}

struct DeviceLibrary: Equatable {
    var deviceID: String
    var folders: [DeviceFolder]
    var loaded: Date
}

/// Reads what Tolkara has on the device: the folders in its Documents, the
/// launcher's own list (Library/Application Support/Tolkara/apps.json) and
/// each game's Info.plist for its version. Read only.
enum DeviceLibraryReader {
    /// Tolkara's own folders, never games.
    static let reserved: Set<String> = ["GuestModules", "GuestCompatibility", "GuestMirror", "LocalSigning"]

    static func read(profiles: [AppProfile], bundleID: String, device: Device, xcode: XcodeInstallation) async throws -> DeviceLibrary {
        guard let top = try await Devices.listFiles("Documents", recurse: false, bundleID: bundleID, device: device, xcode: xcode) else {
            throw ProfileError(message: "Tolkara's files on \(device.name) could not be read. Is Tolkara installed, and is the device unlocked?")
        }
        let folders = Set(top.filter { $0.isDirectory && !$0.path.hasPrefix(".") && !reserved.contains($0.path) }.map(\.path))
        let records = await Devices.readFromApp("Library/Application Support/Tolkara/apps.json", bundleID: bundleID, device: device, xcode: xcode)
            .flatMap(entries(fromLibrary:)) ?? []

        // Every game we can name: profiles, then the launcher's other entries.
        var candidates: [DeviceGame] = profiles.map {
            DeviceGame(id: $0.id, name: $0.name, profile: $0, executable: $0.documentsExecutable)
        }
        for record in records {
            if let index = candidates.firstIndex(where: { $0.id == record.profile || $0.executable == record.executable }) {
                candidates[index].lastLaunched = record.lastLaunched
            } else {
                candidates.append(DeviceGame(id: record.id, name: record.name, profile: nil, executable: record.executable, lastLaunched: record.lastLaunched))
            }
        }

        var result: [DeviceFolder] = []
        for folder in folders.sorted() {
            let inside = candidates.filter { $0.executable.hasPrefix(folder + "/") }
            guard !inside.isEmpty,
                  let files = try await Devices.listFiles("Documents/" + folder, recurse: true, bundleID: bundleID, device: device, xcode: xcode)
            else { continue }
            let sizes = Dictionary(files.filter { !$0.isDirectory }.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
            var games: [DeviceGame] = []
            for var game in inside {
                guard let size = sizes[String(game.executable.dropFirst(folder.count + 1))] else { continue }
                game.executableSize = size
                if let plist = game.infoPlist,
                   let data = await Devices.readFromApp("Documents/" + plist, bundleID: bundleID, device: device, xcode: xcode) {
                    game.version = version(fromInfoPlist: data)
                }
                games.append(game)
            }
            if !games.isEmpty { result.append(DeviceFolder(name: folder, size: sizes.values.reduce(0, +), games: games)) }
        }
        return DeviceLibrary(deviceID: device.id, folders: result, loaded: Date())
    }

    struct Entry { var id: String; var name: String; var executable: String; var profile: String?; var lastLaunched: Date? }

    /// The launcher's apps.json: {"format":1,"apps":[{id,name,executable,profile,lastLaunched,…}]}.
    static func entries(fromLibrary data: Data) -> [Entry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["format"] as? Int == 1,
              let apps = root["apps"] as? [[String: Any]] else { return nil }
        return apps.compactMap { app in
            guard let id = app["id"] as? String, let executable = app["executable"] as? String, ProfileParser.relative(executable) else { return nil }
            return Entry(id: id, name: app["name"] as? String ?? URL(fileURLWithPath: executable).lastPathComponent, executable: executable,
                         profile: app["profile"] as? String, lastLaunched: (app["lastLaunched"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
    }

    static func version(fromInfoPlist data: Data) -> String? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
}

extension AppProfile {
    /// The executable relative to Documents, as the launcher finds it.
    var documentsExecutable: String { (runtimeFolder ?? workingDirectory) + "/" + executable }

    /// Info.plist of the macOS app bundle holding the executable, relative to Documents.
    var infoPlistPath: String? {
        guard !hasRuntime, let range = documentsExecutable.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(documentsExecutable[..<range.lowerBound]) + ".app/Contents/Info.plist"
    }
}

extension DeviceGame {
    var infoPlist: String? {
        if let profile { return profile.infoPlistPath }
        guard let range = executable.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(executable[..<range.lowerBound]) + ".app/Contents/Info.plist"
    }
}

/// The game as it is on this Mac, to tell whether the device's copy is older.
struct MacCopy: Equatable {
    var version: String?
    var executableSize: Int64

    static func of(_ executable: URL) -> MacCopy? {
        guard let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return MacCopy(version: Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String, executableSize: Int64(size))
    }

    /// Different from the device's copy: the game was updated on this Mac.
    func isNewer(than game: DeviceGame) -> Bool {
        if let version, let other = game.version, version != other { return true }
        if let other = game.executableSize, other != executableSize { return true }
        return false
    }
}

enum FileHash {
    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
