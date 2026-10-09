import Foundation

/// The Tolkara source this app builds: normally the copy carried inside the
/// app, unpacked into Application Support, or a checkout the user chose.
struct SourceTree: Equatable {
    var root: URL
    var version: String     // tag or short commit, "-dirty" with uncommitted changes
    var identity: String    // follows the content: a different source needs a new build
}

enum Workspace {
    /// Tolkara-source.txt (tools/embed_management_source.sh): commit, version, content identity.
    static func bundledVersion() -> (identity: String, version: String)? {
        guard let url = Bundle.main.url(forResource: "Tolkara-source", withExtension: "txt"),
              let lines = try? String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init),
              let commit = lines.first, commit.count >= 12 else { return nil }
        return (lines.count > 2 ? lines[2] : commit, lines.count > 1 ? lines[1] : String(commit.prefix(12)))
    }

    static func isSource(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("tools/install.sh").path)
    }

    /// The source to build. A chosen folder wins; otherwise the bundled copy is
    /// unpacked once per version and older unpacked versions are removed.
    static func prepare(overridePath: String?) async throws -> SourceTree {
        if let overridePath, !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath)
            guard isSource(url) else { throw ProfileError(message: "\(overridePath) is not a Tolkara folder (tools/install.sh is missing).") }
            let commit = (try? await Shell.run("/usr/bin/git", ["-C", url.path, "rev-parse", "HEAD"]))?.output
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SourceTree(root: url, version: "local folder", identity: commit.count == 40 ? commit : "local")
        }
        guard let (identity, version) = bundledVersion(),
              let archive = Bundle.main.url(forResource: "Tolkara-source", withExtension: "tar.gz") else {
            throw ProfileError(message: "This copy of Tolkara Management carries no Tolkara source. Choose a Tolkara folder in Settings › Advanced.")
        }
        let fileManager = FileManager.default
        let parent = AppPaths.support.appendingPathComponent("Tolkara", isDirectory: true)
        let root = parent.appendingPathComponent(String(identity.prefix(12)), isDirectory: true)
        if !isSource(root) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let unpacking = parent.appendingPathComponent(".unpacking-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: unpacking, withIntermediateDirectories: true)
            do {
                try await Shell.check("/usr/bin/tar", ["-xzf", archive.path, "-C", unpacking.path])
                try? fileManager.removeItem(at: root)
                try fileManager.moveItem(at: unpacking, to: root)
            } catch {
                try? fileManager.removeItem(at: unpacking)
                throw error
            }
        }
        for old in (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where old != root {
            try? fileManager.removeItem(at: old)
        }
        return SourceTree(root: root, version: version, identity: identity)
    }
}

/// The ignored local.env that Tolkara's scripts read (local.env.example):
/// written by this app from what the user set up, never committed anywhere.
enum LocalEnv {
    struct Values: Equatable {
        var team: String
        var bundleID: String
        var device: String
        var executables: [String]
        var ownProfiles: [String]
        var mode = "developer-service"
    }

    /// The scripts source the file with bash and tools/localenv.py strips the
    /// quotes, so values are double-quoted and may not contain characters
    /// that bash would expand inside them.
    static func render(_ values: Values) throws -> String {
        func quoted(_ name: String, _ value: String) throws -> String {
            guard !value.contains(where: { "\"$`\\\n".contains($0) }) else {
                throw ProfileError(message: "\(name) contains a character Tolkara's scripts cannot take (\" $ ` \\): \(value)")
            }
            return "\(name)=\"\(value)\""
        }
        for path in values.executables + values.ownProfiles where path.contains(":") {
            throw ProfileError(message: "Paths may not contain “:”, which separates entries: \(path)")
        }
        var lines = ["# Written by Tolkara Management. It rewrites this file before each step;",
                     "# change these settings in the app instead.",
                     try quoted("DEVELOPMENT_TEAM", values.team),
                     try quoted("TOLKARA_BUNDLE_ID", values.bundleID),
                     try quoted("DEVICE", values.device),
                     try quoted("GUEST_EXE", values.executables.joined(separator: ":")),
                     try quoted("TOLKARA_MODE", values.mode)]
        if !values.ownProfiles.isEmpty { lines.append(try quoted("TOLKARA_PROFILE", values.ownProfiles.joined(separator: ":"))) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func write(_ values: Values, to source: SourceTree) throws {
        try render(values).write(to: source.root.appendingPathComponent("local.env"), atomically: true, encoding: .utf8)
    }

    /// A bundle ID unique to the team: Apple registers each one to a single team.
    static func defaultBundleID(team: String) -> String { "local.tolkara.\(team.lowercased())" }
}
