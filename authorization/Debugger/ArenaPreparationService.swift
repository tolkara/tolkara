import Foundation
import Darwin

// The OS-delivered provider message is the only entry point. No network listener
// accepts host descriptors. A verified ready raw debugserver service must be
// installed separately; route/discovery readiness never installs one implicitly.
@objc(TKArenaPreparationService) final class ArenaPreparationService: NSObject {
    let queue: DispatchQueue
    private var manager: TunnelConnectionManager?, port: UInt16?
    private var client: DebugArenaClient?, timer: DispatchSourceTimer?
    private var used = false, closed = false
    private var completion: ((Data?) -> Void)?, message: Data?
    private var pollingRequest: Data?, pollingReply: Data?
    private var lastProgressTime: TimeInterval = 0
    private func recordProgress(_ value: String) {
#if os(iOS)
        // Own diagnostic status only; no addresses, memory, challenges or keys.
        let directory = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try? value.write(to:directory.appendingPathComponent("local-authorization-progress.txt"),atomically:true,encoding:.utf8)
#endif
    }
    override init() { queue = DispatchQueue(label:"local.tolkara.arena-service"); super.init() }
    init(queue: DispatchQueue) { self.queue = queue; super.init() }
    // Internal only, after actual service check-in; not exposed to host IPC.
    func setVerifiedDebugService(manager: TunnelConnectionManager, port: UInt16) throws {
        dispatchPrecondition(condition:.onQueue(queue))
        guard !used, !closed, self.manager == nil, manager.queue === queue, port != 0 else { throw PairingError.invalidState }
        self.manager = manager; self.port = port
    }
    @objc(handleMessage:completion:) func handle(_ data: Data, completion: @escaping (Data?) -> Void) {
        // Bound before crossing queues/copying input. NEProvider already gives
        // an immutable message; all mutable state lives on this serial queue.
        guard data.count == TKAC_SIZE else { completion(nil); return }
        queue.async { self.prepare(data,completion:completion) }
    }
    // Provider messages must finish promptly: the OS can discard a reply held
    // across a long debugger stop. Submit once, then poll the exact same bound
    // descriptor. Polling can never start or repeat an attachment.
    @objc(handleAsyncMessage:completion:) func handleAsync(_ data: Data, completion: @escaping (Data?) -> Void) {
        guard data.count == TKAC_SIZE else { completion(nil);return }
        var command = TKAC_SUBMIT, normalized = Data(count:Int(TKAC_SIZE))
        let valid = normalized.withUnsafeMutableBytes { out in data.withUnsafeBytes { source in
            tkac_normalize(source.bindMemory(to:UInt8.self).baseAddress,source.count,&command,out.bindMemory(to:UInt8.self).baseAddress,out.count)
        } }
        guard valid else { completion(nil);return }
        let request = normalized, operation = command
        queue.async {
            if operation == TKAC_SUBMIT {
                // A duplicate must not imply that its memory is safe to free:
                // the first submission may still be preparing that same arena.
                guard self.pollingRequest == nil else { completion(Self.response(request,TKAC_UNCERTAIN));return }
                self.pollingRequest = request
                completion(Self.response(request,TKAC_PENDING))
                self.queue.async {
                    self.prepare(request) { result in self.pollingReply = result ?? Self.response(request,TKAC_UNCERTAIN) }
                }
                return
            } else if self.pollingRequest != request {
                completion(Self.response(request,TKAC_UNCERTAIN));return
            }
            completion(self.pollingReply ?? Self.response(request,TKAC_PENDING))
        }
    }
    private static func response(_ data: Data, _ outcome: TKACOutcome) -> Data? {
        var response = Data(count:Int(TKAC_SIZE))
        let valid = response.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { source in
                tkac_reply(source.bindMemory(to:UInt8.self).baseAddress,source.count,outcome,
                           out.bindMemory(to:UInt8.self).baseAddress,out.count)
            }
        }
        return valid ? response : nil
    }
    private func prepare(_ data: Data, completion: @escaping (Data?) -> Void) {
        var raw = TKACRequest()
        let valid = data.withUnsafeBytes { tkac_decode($0.bindMemory(to:UInt8.self).baseAddress,$0.count,&raw) }
        guard valid else { completion(nil); return }
        let now = UInt64(ProcessInfo.processInfo.systemUptime*1000)
        guard !used, !closed, let manager, let port, raw.pid != UInt32(getpid()),
              raw.uid == UInt32(geteuid()), raw.deadline_ms > now, raw.deadline_ms-now <= 1850_000 else {
            completion(Self.response(data,TKAC_REJECTED)); return
        }
        do {
            let challenge = withUnsafeBytes(of:raw.challenge) { Data($0) }
            var regions = [DebugArenaRequest.Region(address:raw.address,size:raw.size)]
            if raw.second_size != 0 { regions.append(DebugArenaRequest.Region(address:raw.second_address,size:raw.second_size)) }
            let request = try DebugArenaRequest(pid:raw.pid,helperPID:UInt32(getpid()),uid:raw.uid,
                challengeAddress:raw.challenge_address,challenge:challenge,
                regions:regions)
            // One attach attempt per helper instance; never reattach after the
            // target could have entered the guest's PT_DENY_ATTACH path.
            used = true; self.completion = completion; message = data
            recordProgress("Starting own-app memory preparation, bytes=\(raw.size+raw.second_size)")
            let client = DebugArenaClient(manager:manager,request:request); self.client = client
            let timer = DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+0.1,repeating:1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let time = ProcessInfo.processInfo.systemUptime
                if time*1000 >= Double(raw.deadline_ms) { self.client?.cancel() }
                else if time >= self.lastProgressTime+1, let client = self.client {
                    self.lastProgressTime = time;self.recordProgress(client.diagnosticProgress)
                }
            }
            self.timer = timer; timer.resume()
            client.start(port:port) { [weak self] result in
                guard let self, self.message != nil else { return }
                switch result {
                case .success(let receipt):
                    guard receipt.pid == request.pid, receipt.challenge == request.challenge,
                          receipt.regions == request.regions else { self.finish(TKAC_UNCERTAIN); return }
                    self.finish(TKAC_PREPARED)
                case .failure(let failure):
                    self.recordProgress("Failed: \(failure.reason), detachConfirmed=\(failure.detachConfirmed); \(client.diagnosticProgress)")
                    self.finish(failure.detachConfirmed ? TKAC_FAILED_DETACHED : TKAC_UNCERTAIN)
                }
            }
        } catch { completion(Self.response(data,TKAC_REJECTED)) }
    }
    private func finish(_ result: TKACOutcome) {
        guard let data = message else { return }
        if result == TKAC_PREPARED { recordProgress("Prepared and detached") }
        let callback = completion; completion = nil; message = nil
        timer?.cancel(); timer = nil; client = nil
        callback?(Self.response(data,result))
    }
    @objc func invalidate() {
        queue.async {
            self.closed = true; self.client?.cancel(); self.finish(TKAC_UNCERTAIN)
            self.manager = nil; self.port = nil
        }
    }
    deinit { timer?.cancel() }
}
