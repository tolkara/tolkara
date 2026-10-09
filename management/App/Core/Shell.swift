import Foundation

/// A finished command: its exit status and everything it printed.
struct CommandResult: Sendable {
    var status: Int32
    var output: String
    var succeeded: Bool { status == 0 }
}

struct CommandError: LocalizedError {
    var command: String
    var result: CommandResult
    var errorDescription: String? {
        let tail = result.output.split(separator: "\n").suffix(6).joined(separator: "\n")
        return "\(command) failed (exit status \(result.status)).\(tail.isEmpty ? "" : "\n\(tail)")"
    }
}

/// Runs command-line tools. Output is read as it arrives, so a long build or
/// copy shows its progress, and a cancelled task stops the whole process tree.
enum Shell {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    directory: URL? = nil, line: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector(line: line)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                // Done when the process has exited and its output has ended; a
                // grandchild may keep the pipe open, so do not wait long for that.
                let once = Once()
                let finish = {
                    once.run {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(returning: CommandResult(status: process.terminationStatus, output: collector.finish()))
                    }
                }
                let ended = DispatchGroup()
                ended.enter()
                ended.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ended.leave()
                    } else {
                        collector.append(data)
                    }
                }
                process.terminationHandler = { _ in
                    ended.leave()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: finish)
                }
                ended.notify(queue: .global(), execute: finish)
                do {
                    try process.run()
                } catch {
                    once.run {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if process.isRunning { terminateTree(process.processIdentifier) }
        }
    }

    /// Like run, but throws CommandError for a non-zero exit status.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                      directory: URL? = nil, line: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let result = try await run(executable, arguments, environment: environment, directory: directory, line: line)
        guard result.succeeded else {
            throw CommandError(command: ([URL(fileURLWithPath: executable).lastPathComponent] + arguments.prefix(2)).joined(separator: " "), result: result)
        }
        return result
    }

    /// SIGTERM to a process and all its descendants, children first.
    static func terminateTree(_ pid: pid_t) {
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        children.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        children.standardOutput = pipe
        try? children.run()
        children.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for child in output.split(separator: "\n").compactMap({ pid_t($0) }) { terminateTree(child) }
        kill(pid, SIGTERM)
    }
}

/// Runs a block at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}

/// Collects output and hands it on line by line.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var partial = Data()
    private let line: (@Sendable (String) -> Void)?

    init(line: (@Sendable (String) -> Void)?) { self.line = line }

    func append(_ data: Data) {
        lock.lock()
        all.append(data)
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let text = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...newline)
            if !text.isEmpty { lines.append(text) }
        }
        lock.unlock()
        if let line { lines.forEach(line) }
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !partial.isEmpty, let line {
            line(String(decoding: partial, as: UTF8.self))
            partial.removeAll()
        }
        return String(decoding: all, as: UTF8.self)
    }
}
