// ProcessProbePeer: a second app of the same team, to see what a separate app process
// adds (docs/MULTIPROCESS.md): its own limits, whether it keeps running beside or
// behind ProcessProbe, and whether the two talk over a Unix socket in their shared
// App Group container. It writes a heartbeat there every second and answers each
// connection on peer.sock with its report.
import Darwin
import SwiftUI
import BackgroundTasks

@main
struct PeerApp: App {
    @State private var text = "Starting…"

    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading) {
                    Button("Start 120-request background test") { ContinuedProbe.shared.start() }
                    Button("Start 600-request background test") { ContinuedProbe.shared.start(replies: 600) }
                    Text("Finite tests: about 6 or 30 minutes at the host ping rate. iPadOS can cancel either test.")
                    // Refreshed every second: the latest scene changes, then the report.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Background test: " + ContinuedProbe.shared.status() + "\nPeer events:\n" + Peer.shared.recentEvents())
                    }
                    Text(text)
                }
                .font(.system(.footnote, design: .monospaced)).padding()
            }
            .task { text = Peer.shared.start() }
        }
        .onChange(of: phase, initial: true) { _, new in Peer.shared.setPhase(new) }
    }
}

final class Peer {
    static let shared = Peer()
    private var started = false
    private let launched = Date()
    private let lock = NSLock()
    private var phase = "unknown"
    private var events: [String] = []

    func recentEvents() -> String { lock.lock(); defer { lock.unlock() }; return events.joined() }

    /// The scene's state, kept for answers and logged with a monotonic time to peer-events.log.
    func setPhase(_ new: ScenePhase) {
        let name: String
        switch new {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "other"
        }
        let line = String(format: "%@ uptime %.1f s pid %d: %@\n", Date().description,
                          Date().timeIntervalSince(launched), getpid(), name)
        lock.lock(); phase = name; events.append(line); if events.count > 20 { events.removeFirst() }; lock.unlock()
        // In this app's own Documents, where devicectl can fetch it.
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent("peer-events.log")
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    func currentPhase() -> String { lock.lock(); defer { lock.unlock() }; return phase }

    func start() -> String {
        guard !started, let group = groupContainer() else { return started ? "running" : "no App Group container" }
        started = true
        let report = ProbeReport.make(role: "peer app")
        let heartbeat = group.appendingPathComponent("peer-heartbeat")
        Thread.detachNewThread {
            while true {
                try? String(format: "%.0f", Date().timeIntervalSince1970).write(to: heartbeat, atomically: true, encoding: .utf8)
                Thread.sleep(forTimeInterval: 1)
            }
        }
        let socketPath = group.appendingPathComponent("peer.sock").path
        Thread.detachNewThread { self.serve(socketPath, report: report) }
        Thread.detachNewThread { DescriptorProbe.serve(in: group) }
        return report + "\n\nserving \(socketPath)"
    }

    private func serve(_ path: String, report: String) {
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 4) == 0 else { return }
        while true {
            let client = accept(server, nil, nil)
            if client < 0 { continue }
            // A suspended peer may resume after the caller has timed out and closed.
            // Treat that stale reply as EPIPE instead of terminating the probe.
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var request: [UInt8] = []
            var byte: UInt8 = 0
            while request.count < 64, read(client, &byte, 1) == 1, byte != 10 { request.append(byte) }
            let nonce = String(decoding: request, as: UTF8.self)
            let answer = nonce.hasPrefix("ping ")
                ? String(format: "pong %@ pid %d uptime %.1f phase %@\n", String(nonce.dropFirst(5)), getpid(),
                         Date().timeIntervalSince(launched), currentPhase())
                : "peer pid \(getpid()), up \(Int(Date().timeIntervalSince(launched))) s\n\(report)\n"
            let sent = answer.withCString { write(client, $0, strlen($0)) }
            if nonce.hasPrefix("ping "), sent == answer.utf8.count { ContinuedProbe.shared.replied() }
            close(client)
        }
    }
}
