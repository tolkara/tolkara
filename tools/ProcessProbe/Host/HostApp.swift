// ProcessProbe: does an iPadOS app get more processes, each with its own limits, through
// app-defined extension points (ExtensionFoundation, iOS 26)? Starts every worker
// extension in its own process, keeps them all running, and asks each for its report
// twice (the second time after all have started), logging each stage as it happens to
// Documents/process-probe.log (docs/MULTIPROCESS.md).
import ExtensionFoundation
import SwiftUI

extension AppExtensionPoint {
    @Definition
    static var worker: AppExtensionPoint {
        Name("worker")
        Scope(restriction: .application)
        UserInterface(false)
    }
}

@main
struct ProcessProbeApp: App {
    @State private var text = "Probing…"

    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ScrollView { Text(text).font(.system(.footnote, design: .monospaced)).padding() }
                .task { text = await Probe.shared.runOnce() }
        }
        .onChange(of: phase, initial: true) { _, new in Probe.shared.setPhase(new) }
    }
}

/// One answer to one request, whichever comes first: the reply, an error, or the timeout.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    func wait(timeout seconds: Double, start: (OneShot) -> Void) async -> String {
        await withCheckedContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.finish("timed out after \(seconds) s") }
            start(self)
        }
    }

    func finish(_ value: String) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: value)
    }
}

@MainActor
final class Probe {
    static let shared = Probe()
    private var result: String?
    private var started = false
    private var workers: [(name: String, process: AppExtensionProcess, connection: NSXPCConnection)] = []
    private let runID = UUID().uuidString.prefix(8)
    private var phase = "unknown"
    private let launched = Date()

    func setPhase(_ new: ScenePhase) {
        switch new {
        case .active: phase = "active"
        case .inactive: phase = "inactive"
        case .background: phase = "background"
        @unknown default: phase = "other"
        }
        log(String(format: "%@ host phase %@ at +%.1f s", ISO8601DateFormatter().string(from: Date()), phase, Date().timeIntervalSince(launched)))
    }

    /// Every 3 s for 40 minutes: one bounded round trip to the peer, logged with both states;
    /// a gap of more than 10 s between pings means this app itself was suspended.
    private func startPings() {
        Task.detached {
            var last = Date()
            for sequence in 1...800 {
                let gap = Date().timeIntervalSince(last)
                if sequence > 1 && gap > 10 {
                    log(String(format: "host resumed after a %.0f s gap", gap))
                }
                last = Date()
                let nonce = String(format: "%@-%d", String(UUID().uuidString.prefix(6)), sequence)
                let started = Date()
                let answer = PeerCheck.ping(nonce)
                let hostPhase = await MainActor.run { Probe.shared.phase }
                log(String(format: "%@ ping %d at +%.1f s host %@: %@ (%.0f ms)", ISO8601DateFormatter().string(from: Date()), sequence,
                           Date().timeIntervalSince(await MainActor.run { Probe.shared.launched }), hostPhase, answer,
                           Date().timeIntervalSince(started) * 1000))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            log("pings done")
        }
    }

    func runOnce() async -> String {
        if let result { return result }
        if started { return "Probing…" }
        started = true
        var out: [String] = []
        func stage(_ text: String) { out.append(text); log(text) }

        stage("=== run \(runID) at \(Date())")
        // First, while a just-backgrounded peer still runs.
        if let group = groupContainer() { stage(DescriptorProbe.check(in: group)) }
        stage(ProbeReport.make(role: "app"))
        do {
            let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .worker)
            let state = monitor.state
            stage("extension point \(AppExtensionPoint.worker.id): \(state.identities.count) identities, " +
                  "\(state.unapprovedCount) unapproved, \(state.disabledCount) disabled")
            for identity in state.identities {
                let name = identity.bundleIdentifier
                stage("launching \(name)")
                do {
                    let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity) {
                        log("interrupted: \(name)")
                    })
                    let connection = try process.makeXPCConnection()
                    connection.remoteObjectInterface = NSXPCInterface(with: ProbeService.self)
                    connection.interruptionHandler = { log("XPC interrupted: \(name)") }
                    connection.invalidationHandler = { log("XPC invalidated: \(name)") }
                    connection.resume()
                    workers.append((name, process, connection))
                    stage("— \(name), first report\n\(await ask(connection))")
                } catch {
                    stage("— \(name): launch failed: \(error)")
                }
            }
            // All running at once: ask each again.
            for worker in workers {
                stage("— \(worker.name), again with \(workers.count) running\n\(await ask(worker.connection))")
            }
        } catch {
            stage("monitor failed: \(error)")
        }
        stage(PeerCheck.run())
        stage("=== run \(runID) done; pinging the peer every 3 s for 40 minutes")
        startPings()
        let text = out.joined(separator: "\n\n")
        result = text
        return text
    }

    private func ask(_ connection: NSXPCConnection) async -> String {
        await OneShot().wait(timeout: 30) { shot in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                shot.finish("XPC error: \(error)")
            } as? ProbeService
            guard let proxy else { shot.finish("no proxy"); return }
            proxy.report { shot.finish($0) }
        }
    }
}

private let logQueue = DispatchQueue(label: "process-probe.log")

func log(_ line: String) {
    logQueue.sync {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("process-probe.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
