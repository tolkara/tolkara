import Foundation

// Narrow all-stop debugserver transaction. No launch, registers, breakpoints,
// arbitrary memory writes or guest-byte publication. Only zeros in validated
// fresh host arenas. The owner closes the channel on any terminal result.
//
// Acknowledgements are switched off before attaching (the encrypted tunnel
// already guarantees delivery), so reads and writes go out in batches. A
// debugger write prepares the whole 16 KiB page it lands in: after every byte
// of every arena has been read back as zero, one zero byte per page is written
// and read back.
final class DebugArenaSession {
    enum Phase { case idle, supported, noAck, detachPolicy, attach, process, challenge, region, preflight, prepare, draining, finalProcess, finalChallenge, detach, cleanup, complete, failed }
    enum Reason: Error { case protocolFailure, wrongProcess, wrongChallenge, unsafeRegion, nonzeroMemory, serverFailure, timedOut, cancelled, disconnected }
    struct Failure: Error { let reason: Reason; let detachConfirmed: Bool }
    struct Receipt { let pid: UInt32; let challenge: Data; let regions: [DebugArenaRequest.Region] }
    enum Event { case send(Data), finished(Result<Receipt,Failure>) }
    static let page: UInt64 = 16384
    static let readsPerBatch = 4, pagesPerBatch = 128
    // What each command of a preflight or preparation batch must answer.
    private enum Reply { case ok, zeros(Int) }
    private(set) var phase: Phase = .idle
    private let request: DebugArenaRequest, wire = DebugProtocolWire()
    private var outstanding = 0, noAck = false, acknowledged = false, retries = 0, badPackets = 0, consolePackets = 0
    private var lastPacket = Data(), commandDeadline: TimeInterval = 0, totalDeadline: TimeInterval = 0, lastTime: TimeInterval = 0
    private var packetSize = 1024, chunk = 480, index = 0
    private var offset: UInt64 = 0, regionCursor: UInt64 = 0
    private var replies: [Reply] = [], replied = 0
    private var attached = false, pendingFailure: Reason?, failedIn: Phase?
    var diagnosticProgress: String { "phase=\(failedIn.map { "failed in \($0)" } ?? "\(phase)"), region=\(index), offset=\(offset)" }
    init(request: DebugArenaRequest) { self.request = request }
    private var terminal: Bool { phase == .complete || phase == .failed }
    private func time(_ now: TimeInterval) throws {
        guard now.isFinite, now >= lastTime else { throw Reason.protocolFailure }; lastTime = now
    }
    func begin(now: TimeInterval) throws -> [Event] {
        guard phase == .idle else { throw Reason.protocolFailure }
        try time(now); totalDeadline = now + 1800
        return try command("qSupported",phase:.supported,now:now)
    }
    private func command(_ text: String, phase: Phase, now: TimeInterval) throws -> [Event] {
        try send([text],phase:phase,now:now)
    }
    // One command at a time until acknowledgements are off.
    private func send(_ texts: [String], phase: Phase, now: TimeInterval) throws -> [Event] {
        guard outstanding == 0, !texts.isEmpty, noAck || texts.count == 1 else { throw Reason.protocolFailure }
        var packets = Data()
        for text in texts {
            guard text.utf8.count <= packetSize else { throw Reason.protocolFailure }
            packets += try DebugProtocolWire.encode(text)
        }
        lastPacket = packets; outstanding = texts.count; acknowledged = noAck; retries = 0; badPackets = 0
        self.phase = phase; commandDeadline = now + 10
        return [.send(packets)]
    }
    func receive(_ bytes: Data, now: TimeInterval) -> [Event] {
        guard !terminal, phase != .idle else { return [] }
        // Replies answer only commands sent before this call returns: what it
        // emits has not reached the server, so it cannot be answered yet.
        var events: [Event] = [], answerable = outstanding
        do {
            try time(now)
            if now >= commandDeadline || now >= totalDeadline { return finish(.timedOut,detached:false) }
            guard bytes.count <= 65536 else { throw Reason.protocolFailure }
            for byte in bytes {
                guard answerable > 0 else { throw Reason.protocolFailure }
                guard let event = try wire.feed(byte) else { continue }
                switch event {
                case .ack:
                    guard !noAck, !acknowledged else { throw Reason.protocolFailure }; acknowledged = true
                case .nack:
                    guard !noAck, !acknowledged, retries < 2 else { throw Reason.protocolFailure }
                    retries += 1; events.append(.send(lastPacket))
                case .badChecksum:
                    // Without acknowledgements a damaged reply cannot be asked for again.
                    guard !noAck, badPackets < 2 else { throw Reason.protocolFailure }
                    badPackets += 1; events.append(.send(Data([45])))
                case .packet(let payload):
                    guard let text = String(data:payload,encoding:.ascii) else { throw Reason.protocolFailure }
                    if !noAck { events.append(.send(Data([43]))) }
                    if text.hasPrefix("O"), text != "OK" {
                        consolePackets += 1
                        guard consolePackets <= 64, text.utf8.count % 2 == 1 else { throw Reason.protocolFailure }
                        _ = try DebugProtocolWire.unhex(String(text.dropFirst()),count:(text.utf8.count-1)/2)
                        continue // Deliberately do not expose/log process output.
                    }
                    guard acknowledged else { throw Reason.protocolFailure }
                    answerable -= 1; outstanding -= 1
                    do { events += try reply(text,now:now) }
                    catch {
                        let reason = error as? Reason ?? .protocolFailure
                        if attached, phase != .detach, phase != .cleanup {
                            // The rest of the batch is answered first, then detach.
                            pendingFailure = reason; failedIn = phase
                            if outstanding > 0 { phase = .draining }
                            else { events += try command("D",phase:.cleanup,now:now) }
                        } else { events += finish(reason,detached:false) }
                    }
                }
            }
            return events
        } catch { return finish(.protocolFailure,detached:false) }
    }
    private func reply(_ text: String, now: TimeInterval) throws -> [Event] {
        if phase == .draining { return outstanding == 0 ? try command("D",phase:.cleanup,now:now) : [] }
        if text.hasPrefix("E") { throw Reason.serverFailure }
        switch phase {
        case .supported:
            var seen = false
            for feature in text.split(separator:";") where feature.hasPrefix("PacketSize=") {
                guard !seen else { throw Reason.protocolFailure }; seen = true
                let maximum = try DebugProtocolWire.number(String(feature.dropFirst(11)))
                guard maximum >= 256 else { throw Reason.protocolFailure }
                packetSize = Int(min(maximum,UInt64(DebugProtocolWire.capacity)))
            }
            chunk = (packetSize-64)/2
            return try command("QStartNoAckMode",phase:.noAck,now:now)
        case .noAck:
            guard text == "OK" else { throw Reason.serverFailure }
            noAck = true; wire.acceptsZeroChecksum = true
            return try command("QSetDetachOnError:1",phase:.detachPolicy,now:now)
        case .detachPolicy:
            guard text == "OK" else { throw Reason.serverFailure }
            return try command("vAttach;"+String(request.pid,radix:16),phase:.attach,now:now)
        case .attach:
            // Darwin may stop with SIGSTOP or SIGTRAP. Any valid all-stop
            // reply is followed by exact process and challenge verification.
            guard (text.hasPrefix("T") && text.count >= 3) || (text.hasPrefix("S") && text.count == 3) else { throw Reason.protocolFailure }
            _ = try DebugProtocolWire.number(String(text.dropFirst().prefix(2)))
            attached = true
            return try command("qProcessInfo",phase:.process,now:now)
        case .process, .finalProcess:
            let final = phase == .finalProcess, info = try DebugProtocolWire.fields(text)
            guard try DebugProtocolWire.number(info["pid"]) == UInt64(request.pid),
                  try DebugProtocolWire.number(info["effective-uid"]) == UInt64(request.uid),
                  try DebugProtocolWire.number(info["cputype"]) == 0x100000c,
                  try DebugProtocolWire.number(info["ptrsize"]) == 8, info["endian"] == "little" else { throw Reason.wrongProcess }
            return try command("m"+String(request.challengeAddress,radix:16)+",20",phase:final ? .finalChallenge : .challenge,now:now)
        case .challenge, .finalChallenge:
            let final = phase == .finalChallenge
            guard try DebugProtocolWire.unhex(text,count:32) == request.challenge else { throw Reason.wrongChallenge }
            if final { return try command("D",phase:.detach,now:now) }
            index = 0; regionCursor = request.regions[0].address
            return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now)
        case .region:
            let info = try DebugProtocolWire.fields(text), range = request.regions[index]
            let base = try DebugProtocolWire.number(info["start"]), size = try DebugProtocolWire.number(info["size"])
            guard size > 0, base <= regionCursor, size <= UInt64.max-base, base+size > regionCursor,
                  info["error"] == nil, Set(info["permissions"] ?? "") == Set("rx"),
                  (info["name"] ?? "").isEmpty else { throw Reason.unsafeRegion }
            regionCursor = min(base+size,range.address+range.size)
            if regionCursor < range.address+range.size { return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now) }
            offset = 0; return try preflightBatch(now:now)
        case .preflight, .prepare:
            guard replied < replies.count else { throw Reason.protocolFailure }
            switch replies[replied] {
            case .ok: guard text == "OK" else { throw Reason.serverFailure }
            case .zeros(let count): guard try DebugProtocolWire.unhex(text,count:count).allSatisfy({ $0 == 0 }) else { throw Reason.nonzeroMemory }
            }
            replied += 1
            guard outstanding == 0 else { return [] }
            if phase == .prepare {
                if index < request.regions.count { return try prepareBatch(now:now) }
                return try command("qProcessInfo",phase:.finalProcess,now:now)
            }
            if offset < request.regions[index].size { return try preflightBatch(now:now) }
            index += 1
            if index < request.regions.count {
                regionCursor = request.regions[index].address
                return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now)
            }
            // All arenas passed the full preflight before the first write.
            index = 0; offset = 0; return try prepareBatch(now:now)
        case .detach, .cleanup:
            guard text == "OK" else { throw Reason.serverFailure }
            attached = false
            if let pendingFailure { return finish(pendingFailure,detached:true) }
            phase = .complete; outstanding = 0; lastPacket = Data()
            return [.finished(.success(Receipt(pid:request.pid,challenge:request.challenge,regions:request.regions)))]
        default:throw Reason.protocolFailure
        }
    }
    // Reads the current arena from offset; every byte must be zero.
    private func preflightBatch(now: TimeInterval) throws -> [Event] {
        let range = request.regions[index]
        var texts: [String] = []; replies = []; replied = 0
        while texts.count < Self.readsPerBatch, offset < range.size {
            let count = Int(min(UInt64(chunk),range.size-offset))
            texts.append("m"+String(range.address+offset,radix:16)+","+String(count,radix:16))
            replies.append(.zeros(count)); offset += UInt64(count)
        }
        return try send(texts,phase:.preflight,now:now)
    }
    // Writes one zero byte at the start of each page and reads it back.
    private func prepareBatch(now: TimeInterval) throws -> [Event] {
        var texts: [String] = []; replies = []; replied = 0
        while texts.count < 2*Self.pagesPerBatch, index < request.regions.count {
            let address = String(request.regions[index].address+offset,radix:16)
            texts += ["M"+address+",1:00","m"+address+",1"]; replies += [.ok,.zeros(1)]
            offset += Self.page
            if offset == request.regions[index].size { index += 1; offset = 0 }
        }
        return try send(texts,phase:.prepare,now:now)
    }
    func tick(now: TimeInterval) -> [Event] {
        guard !terminal, phase != .idle else { return [] }
        guard now.isFinite, now >= lastTime, now < commandDeadline, now < totalDeadline else { return finish(.timedOut,detached:false) }
        lastTime = now; return []
    }
    func cancel() -> [Event] { terminal ? [] : finish(.cancelled,detached:false) }
    func disconnected() -> [Event] { terminal ? [] : finish(.disconnected,detached:false) }
    private func finish(_ reason: Reason, detached: Bool) -> [Event] {
        failedIn = failedIn ?? phase; phase = .failed; outstanding = 0; lastPacket = Data()
        return [.finished(.failure(Failure(reason:reason,detachConfirmed:detached)))]
    }
}
