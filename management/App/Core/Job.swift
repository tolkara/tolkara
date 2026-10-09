import Foundation
import Observation

/// A long-running step (a build, an enrolment, a copy) with its output.
@MainActor @Observable
final class Job: Identifiable {
    enum Kind: Hashable {
        case xcodegen, pair, install, copy(String), remove(String), launch, log
    }

    let id = UUID()
    let kind: Kind
    var title: String
    var phase: String
    var hint: String?               // what the user should do meanwhile ("Unlock your iPad")
    var detail: String?             // what the build is doing right now
    private(set) var lines: [String] = []
    let started = Date()
    var finished: Date?
    var failure: String?
    var diagnosis: Diagnosis?
    var task: Task<Void, Never>?

    var isRunning: Bool { finished == nil }
    var succeeded: Bool { finished != nil && failure == nil }
    var output: String { lines.joined(separator: "\n") }

    init(kind: Kind, title: String, phase: String) {
        self.kind = kind
        self.title = title
        self.phase = phase
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }

    /// A line handler usable from any thread; lines arrive in order.
    nonisolated func sink() -> @Sendable (String) -> Void {
        { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(line) } }
        }
    }
}

/// What xcodebuild is doing, read from the newest build log a script writes
/// into the source's logs/ folder (tools/install.sh keeps xcodebuild's
/// output there rather than on the terminal).
enum BuildActivity {
    static func current(logs: URL, since: Date) -> String? {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files.filter { $0.pathExtension == "log" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date >= since else { return nil }
                return (url, date)
            }.max { $0.1 < $1.1 }?.0
        guard let newest, let handle = try? FileHandle(forReadingFrom: newest) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            if let text = describe(String(line)) { return text }
        }
        return nil
    }

    static func describe(_ line: String) -> String? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let action = words.first else { return nil }
        func file() -> String {
            let path = words.dropFirst().first { $0.hasPrefix("/") && !$0.hasSuffix(".o") } ?? words.last ?? ""
            return URL(fileURLWithPath: String(path)).lastPathComponent
        }
        switch action {
        case "CompileC", "SwiftCompile", "CompileSwift", "CompileMetalFile": return "Compiling \(file())"
        case "SwiftDriver", "SwiftEmitModule": return "Compiling Swift code"
        case "Ld": return "Linking \(file())"
        case "CodeSign": return "Signing \(file())"
        case "CompileAssetCatalog", "CompileAssetCatalogVariant": return "Preparing images"
        case "PhaseScriptExecution": return "Preparing compatibility libraries"
        case "ProcessProductPackaging", "ProcessProductPackagingDER": return "Preparing signing"
        default: return nil
        }
    }
}
