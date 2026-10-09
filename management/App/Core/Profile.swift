import Foundation
import CryptoKit

/// An application profile (profiles/<id>/profile.json, profiles/README.md),
/// with the optional `setup` block this app reads. Validation follows
/// tools/check_profile.py; keep the two in step.
struct AppProfile: Identifiable, Hashable {
    struct Link: Hashable { var title: String; var url: URL }
    struct HistoryEntry: Hashable { var when: String; var text: String }
    struct Risk: Hashable {
        var summary: String
        var history: [HistoryEntry]
        var links: [Link]
        /// Changes when the wording changes, so a new risk is accepted anew.
        var digest: String {
            let text = ([summary] + history.map { $0.when + $0.text } + links.map(\.url.absoluteString)).joined(separator: "\n")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct GetApp: Hashable {
        var name: String
        var url: URL
        var path: String?
        var steps: [String]
    }
    enum Origin: Hashable {
        case builtIn(folder: URL)      // profiles/<id>/ in the Tolkara source
        case imported(file: URL)       // a profile the user added
    }

    var id: String
    var name: String
    var workingDirectory: String
    var executable: String
    var tested: String?
    var notes: String?
    var hasRuntime: Bool { runtimeFolder != nil }
    var runtimeFolder: String?
    var hasSetup: Bool
    var source: String?
    var destination: String
    var installer: String?
    var getApp: GetApp?
    var risk: Risk?
    var origin: Origin

    var isImported: Bool { if case .imported = origin { return true } else { return false } }

    /// The copy helper: only a built-in profile's own script is ever run.
    var installerURL: URL? {
        guard case .builtIn(let folder) = origin, let installer else { return nil }
        return folder.appendingPathComponent(installer)
    }

    var profileFile: URL {
        switch origin {
        case .builtIn(let folder): return folder.appendingPathComponent("profile.json")
        case .imported(let file): return file
        }
    }

    /// Path of the executable inside the Mac folder that becomes Documents/<destination>.
    var executableInSource: String {
        let full = workingDirectory + "/" + executable
        return String(full.dropFirst(destination.count + 1))
    }

    func executable(inSource folder: URL) -> URL { folder.appendingPathComponent(executableInSource) }
}

struct ProfileError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum ProfileParser {
    static let required = ["id", "name", "workingDirectory", "executable"]
    static let optional = ["notes", "tested", "caseAliases", "runtime", "arguments", "environment", "libraries", "codePool", "setup"]

    static func relative(_ value: Any?) -> Bool {
        guard let value = value as? String, !value.isEmpty, !value.hasPrefix("/") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !["", ".", ".."].contains($0) }
    }

    static func text(_ value: Any?, _ name: String, limit: Int = 1000) throws -> String {
        guard let value = value as? String, !value.isEmpty, value.count <= limit else {
            throw ProfileError(message: "\(name) must be a non-empty string of at most \(limit) characters.")
        }
        return value
    }

    static func https(_ value: Any?, _ name: String) throws -> URL {
        let string = try text(value, name, limit: 2048)
        guard string.hasPrefix("https://"), !string.contains(where: \.isWhitespace), let url = URL(string: string) else {
            throw ProfileError(message: "\(name) must be an https link.")
        }
        return url
    }

    static func parse(_ data: Data, origin: AppProfile.Origin) throws -> AppProfile {
        guard data.count <= 65536, let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProfileError(message: "This is not a profile: a profile is a small JSON object.")
        }
        let unknown = Set(profile.keys).subtracting(required + optional)
        guard unknown.isEmpty else { throw ProfileError(message: "Unknown keys: \(unknown.sorted().joined(separator: ", ")).") }
        for key in required { _ = try text(profile[key], key, limit: 4096) }
        for key in ["workingDirectory", "executable", "runtime"] where profile[key] != nil {
            guard relative(profile[key]) else { throw ProfileError(message: "\(key) must stay inside Documents.") }
        }
        let workingDirectory = profile["workingDirectory"] as! String
        let hasRuntime = profile["runtime"] != nil
        let setup = profile["setup"]
        var source: String?, installer: String?, getApp: AppProfile.GetApp?, risk: AppProfile.Risk?
        var destination = String(workingDirectory.split(separator: "/").first ?? "")
        if let setup {
            guard let setup = setup as? [String: Any] else { throw ProfileError(message: "setup must be an object.") }
            let unknown = Set(setup.keys).subtracting(["source", "destination", "installer", "getApp", "risk"])
            guard unknown.isEmpty else { throw ProfileError(message: "setup: unknown keys: \(unknown.sorted().joined(separator: ", ")).") }
            guard !hasRuntime else { throw ProfileError(message: "setup is not available for a profile with a runtime.") }
            if setup["source"] != nil {
                source = try text(setup["source"], "setup.source", limit: 1024)
                guard source!.hasPrefix("/") else { throw ProfileError(message: "setup.source must be an absolute path on the Mac.") }
            }
            if setup["destination"] != nil { destination = setup["destination"] as? String ?? "" }
            if setup["installer"] != nil {
                guard let name = setup["installer"] as? String, name.wholeMatch(of: /[A-Za-z0-9_-]+\.py/) != nil else {
                    throw ProfileError(message: "setup.installer must name a Python script in the profile folder.")
                }
                installer = name
            }
            if let value = setup["getApp"] {
                guard let value = value as? [String: Any], Set(value.keys).isSubset(of: ["name", "url", "path", "steps"]) else {
                    throw ProfileError(message: "setup.getApp needs name and url, optionally path and steps.")
                }
                let path = value["path"] == nil ? nil : try text(value["path"], "setup.getApp.path", limit: 1024)
                if let path, !path.hasPrefix("/") { throw ProfileError(message: "setup.getApp.path must be an absolute path on the Mac.") }
                guard value["steps"] == nil || value["steps"] is [Any] else { throw ProfileError(message: "setup.getApp.steps must be a list.") }
                let steps = try (value["steps"] as? [Any] ?? []).map { try text($0, "setup.getApp.steps") }
                guard steps.count <= 16 else { throw ProfileError(message: "setup.getApp.steps has more than 16 entries.") }
                getApp = .init(name: try text(value["name"], "setup.getApp.name", limit: 100),
                               url: try https(value["url"], "setup.getApp.url"), path: path, steps: steps)
            }
            if let value = setup["risk"] {
                guard let value = value as? [String: Any], Set(value.keys).isSubset(of: ["summary", "history", "links"]) else {
                    throw ProfileError(message: "setup.risk needs summary, optionally history and links.")
                }
                func entries(_ name: String, _ keys: [String]) throws -> [[String: Any]] {
                    guard value[name] == nil || value[name] is [Any] else { throw ProfileError(message: "setup.risk.\(name) must be a list.") }
                    let list = value[name] as? [Any] ?? []
                    guard list.count <= 16 else { throw ProfileError(message: "setup.risk.\(name) has more than 16 entries.") }
                    return try list.map { entry in
                        guard let entry = entry as? [String: Any], Set(entry.keys) == Set(keys) else {
                            throw ProfileError(message: "setup.risk.\(name) entries need exactly: \(keys.joined(separator: ", ")).")
                        }
                        return entry
                    }
                }
                risk = .init(summary: try text(value["summary"], "setup.risk.summary", limit: 2000),
                             history: try entries("history", ["when", "text"]).map {
                                 .init(when: try text($0["when"], "setup.risk.history.when"), text: try text($0["text"], "setup.risk.history.text"))
                             },
                             links: try entries("links", ["title", "url"]).map {
                                 .init(title: try text($0["title"], "setup.risk.links.title"), url: try https($0["url"], "setup.risk.links.url"))
                             })
            }
        }
        guard relative(destination), (workingDirectory + "/").hasPrefix(destination + "/") else {
            throw ProfileError(message: "setup.destination must be the working directory or a folder above it.")
        }
        if let installer, case .builtIn(let folder) = origin,
           !FileManager.default.fileExists(atPath: folder.appendingPathComponent(installer).path) {
            throw ProfileError(message: "setup.installer is not in the profile folder.")
        }
        return AppProfile(id: profile["id"] as! String, name: profile["name"] as! String, workingDirectory: workingDirectory,
                          executable: profile["executable"] as! String, tested: profile["tested"] as? String,
                          notes: profile["notes"] as? String, runtimeFolder: profile["runtime"] as? String, hasSetup: setup != nil,
                          source: source, destination: destination, installer: installer, getApp: getApp, risk: risk, origin: origin)
    }

    /// Built-in profiles (profiles/*/profile.json in the source) and imported ones.
    static func catalog(source: URL?) -> (profiles: [AppProfile], problems: [String]) {
        var profiles: [AppProfile] = [], problems: [String] = [], seen = Set<String>()
        let fileManager = FileManager.default
        func add(_ file: URL, _ origin: AppProfile.Origin) {
            do {
                let profile = try parse(try Data(contentsOf: file), origin: origin)
                guard seen.insert(profile.id).inserted else { return }
                profiles.append(profile)
            } catch {
                problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let source {
            let folders = (try? fileManager.contentsOfDirectory(at: source.appendingPathComponent("profiles"), includingPropertiesForKeys: nil)) ?? []
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = folder.appendingPathComponent("profile.json")
                if fileManager.fileExists(atPath: file.path) { add(file, .builtIn(folder: folder)) }
            }
        }
        let imported = (try? fileManager.contentsOfDirectory(at: AppPaths.profiles, includingPropertiesForKeys: nil)) ?? []
        for file in imported.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            add(file, .imported(file: file))
        }
        return (profiles, problems)
    }

    /// Validates a profile and keeps a copy in our Profiles folder.
    @discardableResult
    static func importProfile(_ data: Data) throws -> AppProfile {
        let probe = try parse(data, origin: .imported(file: URL(fileURLWithPath: "/")))
        guard !probe.hasRuntime else {
            throw ProfileError(message: "“\(probe.name)” runs through a compatibility runtime, which Tolkara Management cannot set up yet. Use the command line (docs/BUILDING.md).")
        }
        try FileManager.default.createDirectory(at: AppPaths.profiles, withIntermediateDirectories: true)
        let safe = probe.id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let file = AppPaths.profiles.appendingPathComponent("\(safe).json")
        try data.write(to: file, options: .atomic)
        return try parse(data, origin: .imported(file: file))
    }
}
