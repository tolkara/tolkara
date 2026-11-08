import Foundation
import CryptoKit
import Darwin
import Network

// Authenticated local developer transport driven by the helper's packet flow.
// Its lifetime is independent of the app process that the debugger may pause.
@objc(TKPacketServiceProbe) final class PacketServiceProbe: NSObject {
    private let queue = DispatchQueue(label:"local.tolkara.packet-service-probe")
    @objc private(set) var arenaService: ArenaPreparationService!
    // The synthetic tuple: our reserved port and the device service's port
    // (49152 unless iOS moved it; TKServicePort finds it in the app).
    private var codec: LocalTCPIPv4?
    private var reservedPortFD: Int32
    private var reservedPort: UInt16
    private var tcp: TunnelTCP?
    private var decoder = PairingFrameDecoder()
    private var timer: DispatchSourceTimer?
    private var completion: ((String)->Void)?
    private var output: ((Data)->Bool)?
    private var used = false, finished = false
    private var proofRequested = false
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var authentication: PairingSession?
    private var enrollment: PairingEnrollment?
    private var makeTunnel = false
    private var retainAuthorization = false
    @objc private(set) var authorizationReady = false
    private var proxy: LocalPacketTCPProxy?
    private var manager: TunnelConnectionManager?
    private var discovery: TunnelDiscoveryClient?
    private var debugStream: UUID?
    private let debugWire = DebugProtocolWire()
    private var debugCapabilityComplete = false
    private var deadline: TimeInterval = 0
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        // Reserve an unused kernel port so a concurrent host socket cannot
        // accidentally share the diagnostic's synthetic TCP tuple. The
        // service's own port is known only when a request names it.
        (reservedPortFD,reservedPort) = Self.reservePort()
        super.init()
        arenaService = ArenaPreparationService(queue:queue)
    }
    private static func reservePort() -> (Int32,UInt16) {
        let fd = socket(AF_INET,SOCK_STREAM,0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = fd >= 0 && withUnsafeMutablePointer(to:&address) { pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1) {
                Darwin.bind(fd,$0,length) == 0 && getsockname(fd,$0,&length) == 0
            }
        }
        if bound { return (fd,UInt16(bigEndian:address.sin_port)) }
        if fd >= 0 { Darwin.close(fd) }
        return (-1,0)
    }

    @objc func start(servicePort: UInt16, output: @escaping (Data)->Bool, completion: @escaping (String)->Void) {
        start(deviceIdentifier:nil,servicePort:servicePort,makeTunnel:false,output:output,completion:completion)
    }
    @objc func startAuthenticated(deviceIdentifier: String, servicePort: UInt16, output: @escaping (Data)->Bool, completion: @escaping (String)->Void) {
        start(deviceIdentifier:deviceIdentifier,servicePort:servicePort,makeTunnel:false,output:output,completion:completion)
    }
    @objc func startVerifiedTunnel(deviceIdentifier: String, servicePort: UInt16, output: @escaping (Data)->Bool, completion: @escaping (String)->Void) {
        start(deviceIdentifier:deviceIdentifier,servicePort:servicePort,makeTunnel:true,output:output,completion:completion)
    }
    @objc func startAuthorization(deviceIdentifier: String, servicePort: UInt16, output: @escaping (Data)->Bool, completion: @escaping (String)->Void) {
        start(deviceIdentifier:deviceIdentifier,servicePort:servicePort,makeTunnel:true,retainAuthorization:true,output:output,completion:completion)
    }
    private func start(deviceIdentifier: String?, servicePort: UInt16, makeTunnel: Bool, retainAuthorization: Bool = false, output: @escaping (Data)->Bool, completion: @escaping (String)->Void) {
        queue.async { [self] in
            guard !used else { completion("Packet probe already used; restart route for another test.");return }
            used = true; self.output = output; self.completion = completion; self.makeTunnel = makeTunnel; deadline = clock+(makeTunnel ? 45 : 8)
            self.retainAuthorization = retainAuthorization
            if reservedPortFD >= 0 && reservedPort == servicePort {
                // Our port must differ from the service's in the tuple.
                let previous = reservedPortFD
                (reservedPortFD,reservedPort) = Self.reservePort()
                Darwin.close(previous)
            }
            guard servicePort > 0, reservedPortFD >= 0, reservedPort != servicePort else { finish("Could not reserve the packet probe's local port.");return }
            let codec = LocalTCPIPv4(clientPort:reservedPort,servicePort:servicePort)
            self.codec = codec
            do {
                if let deviceIdentifier {
                    guard let enrollment = try PairingKeychain().load(deviceIdentifier:deviceIdentifier) else {
                        finish("Helper has no protected enrollment for the selected device.");return
                    }
                    authentication = PairingSession(identity:enrollment.identity)
                    self.enrollment = enrollment
                }
                tcp = try TunnelTCP(endpoints:codec.endpoints,mtu:1500,initialSequence:.random(in:0...UInt32.max))
                let timer = DispatchSource.makeTimerSource(queue:queue)
                timer.schedule(deadline:.now()+0.1,repeating:0.1)
                timer.setEventHandler { [weak self] in
                    guard let self, !self.finished else { return }
                    if self.clock >= self.deadline { self.finish(self.authorizationReady ? "Local authorization session expired." : "Packet-flow service handshake timed out.") }
                    else if let tcp = self.tcp { self.process(tcp.tick(now:self.clock)) }
                }
                self.timer = timer; timer.resume()
                process(try tcp!.connect(now:clock))
            } catch { finish("Packet-flow probe could not initialize.") }
        }
    }
    @objc func consume(_ packet: Data) -> Bool {
        // Keep the tuple reserved through the provider lifetime, including after
        // completion; delayed packets must never enter the reflector.
        return queue.sync {
            if let proxy, proxy.consume(packet) { return true }
            guard let codec, codec.matches(packet) else { return false }
            guard used, !finished, let tcp, let incoming = try? codec.incoming(packet) else { return true }
            process(tcp.receive(incoming,now:clock))
            return true
        }
    }
    @objc func cancel() { queue.async { self.finish("Packet-flow service probe cancelled.") } }
    private func process(_ events: [TunnelTCP.Event]) {
        guard !finished else { return }
        // Send protocol ACKs before consuming application data.
        for event in events {
            if case .packet(let data) = event {
                guard let packet = try? codec?.outgoing(data), output?(packet) == true else {
                    finish("Packet-flow injection failed.");return
                }
            }
        }
        for event in events {
            guard !finished, let tcp else { return }
            switch event {
            case .connected:
                do {
                    if let authentication {
                        process(try tcp.write(PairingFrameDecoder.encode(authentication.begin()),now:clock));continue
                    }
                    let query: [String:Any] = ["message":["plain":["_0":["request":["_0":["handshake":["_0":[
                        "hostOptions":["attemptPairVerify":true],"wireProtocolVersion":19]]]]]]],"originatedBy":"host","sequenceNumber":0]
                    let wire = try PairingFrameDecoder.encode(JSONSerialization.data(withJSONObject:query))
                    process(try tcp.write(wire,now:clock))
                } catch { finish("Packet-flow query encoding failed.") }
            case .readable:
                let (bytes,events) = tcp.read(maximum:16384); process(events)
                do {
                    var reply: Data?
                    for byte in bytes {
                        guard reply == nil else { throw PairingError.malformed }
                        if let value = try decoder.consume(byte) { reply = value }
                    }
                    if let reply {
                        if let authentication {
                            switch try authentication.receive(reply) {
                            case .send(let message):
                                process(try tcp.write(PairingFrameDecoder.encode(message),now:clock))
                            case .tunnel(let offer):
                                if makeTunnel { try beginTunnel(offer) }
                                else { finish("Helper authenticated the pinned device, proved our app identity, and received an encrypted tunnel offer. No debugger attached or native permission enabled.") }
                            }
                            continue
                        }
                        let object = try JSONSerialization.jsonObject(with:reply) as? [String:Any]
                        guard object?["originatedBy"] as? String == "device" else { throw PairingError.malformed }
                        var value: Any? = object
                        if !proofRequested {
                            for key in ["message","plain","_0","response","_1","handshake","_0"] { value = (value as? [String:Any])?[key] }
                            guard value is [String:Any] else { throw PairingError.malformed }
                            let key = Curve25519.KeyAgreement.PrivateKey(); ephemeral = key
                            let tlv = try PairingTLV.encode([(6,Data([1])),(3,key.publicKey.rawRepresentation)])
                            let query: [String:Any] = ["message":["plain":["_0":["event":["_0":["pairingData":["_0":[
                                "data":tlv.base64EncodedString(),"kind":"verifyManualPairing","startNewSession":true]]]]]]],"originatedBy":"host","sequenceNumber":1]
                            proofRequested = true
                            process(try tcp.write(PairingFrameDecoder.encode(JSONSerialization.data(withJSONObject:query)),now:clock))
                        } else {
                            for key in ["message","plain","_0","event","_0","pairingData","_0","data"] { value = (value as? [String:Any])?[key] }
                            guard let text = value as? String, let data = Data(base64Encoded:text), let ephemeral else { throw PairingError.malformed }
                            let fields = try PairingTLV.message(data,state:2)
                            guard let publicKey = fields[3], let ciphertext = fields[5] else { throw PairingError.malformed }
                            let shared = try PairingCrypto.sharedSecret(privateKey:ephemeral,peerPublicKey:publicKey)
                            do {
                                let proof = try PairingTLV.decode(PairingCrypto.open(ciphertext,key:PairingCrypto.verifyKey(shared),nonce:PairingCrypto.nonce("PV-Msg02")))
                                let expected = proof[1] != nil && proof[10]?.count == 64
                                finish(expected ? "Helper handshake and encrypted device-proof format passed. No trusted identity, host authentication or native permission verified." : "Helper handshake passed; decrypted device-proof schema differs from the expected identifier/signature format.")
                            } catch {
                                finish("Helper handshake and X25519 exchange passed; device-proof decryption failed. No credentials sent or authentication claimed.")
                            }
                        }
                    }
                } catch { finish(authentication == nil ? "Packet-flow service response was invalid." : "Authenticated packet-flow pairing failed verification or protocol validation.") }
            case .failed: finish("Packet-flow TCP connection failed.")
            case .peerClosed, .closed: finish("Packet-flow service closed before the handshake completed.")
            default: break
            }
        }
    }
    private func beginTunnel(_ offer: PairingSession.TunnelOffer) throws {
        guard proxy == nil, let output, let enrollment else { throw PairingError.invalidState }
        let proxy = try LocalPacketTCPProxy(servicePort:offer.port,output:output)
        self.proxy = proxy
        proxy.start(onReady:{ [weak self] port in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.finished else { return }
                do {
                    let key = offer.sessionKey.withUnsafeBytes { Data($0) }
                    let link = try CDTunnelConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,sessionKey:key,queue:self.queue)
                    let manager = TunnelConnectionManager(link:link,queue:self.queue)
                    self.manager = manager
                    manager.start(onReady:{ [weak self] configuration in
                        guard let self, !self.finished else { return }
                        let discovery = TunnelDiscoveryClient(manager:manager,expectedDeviceIdentifier:enrollment.deviceIdentifier,hostUUID:enrollment.connectionIdentifier)
                        self.discovery = discovery
                        discovery.start(port:configuration.rsdPort) { [weak self] result in
                            guard let self, !self.finished else { return }
                            switch result {
                            case .success(let catalog):
                                let service = catalog.services["com.apple.internal.dt.remote.debugproxy"]
                                let names = catalog.services.keys.filter { $0.contains("debug") || $0.contains("developer") || $0.contains("image") }.sorted().map { "\($0) (XPC=\(catalog.services[$0]!.usesRemoteXPC))" }.joined(separator:", ")
                                if let service { self.probeDebugService(manager:manager,port:service.port) }
                                else { self.finish("Helper authenticated pairing and TLS discovery; developer services: \(names).") }
                            case .failure: self.finish("Authenticated TLS tunnel opened; discovery failed: \(discovery.diagnosticStage). TLS: \(link.diagnosticStage).")
                            }
                        }
                    },onClosed:{ [weak self, weak link] _ in
                        self?.finish("Authenticated pairing passed; TLS/CDTunnel failed: \(link?.diagnosticStage ?? "unavailable").")
                    })
                } catch { self.finish("Could not initialize the authenticated system TLS tunnel.") }
            }
        },onClosed:{ [weak self] _ in
            guard let self else { return };self.queue.async { self.finish("The helper's private TLS packet bridge closed or failed.") }
        })
    }
    // iPadOS 27 advertises UsesRemoteXPC even on the documented raw debugproxy
    // endpoint. Confirm its actual wire protocol with a read-only capability
    // query; no attach/process-control command is sent by this diagnostic.
    private func probeDebugService(manager: TunnelConnectionManager, port: UInt16) {
        deadline = clock + 12
        do {
            debugStream = try manager.open(port:port) { [weak self] id,event in
                guard let self, !self.finished, !self.debugCapabilityComplete else { return }
                do {
                    switch event {
                    case .connected: try manager.write(id,data:DebugProtocolWire.encode("qSupported"))
                    case .readable:
                        for byte in try manager.read(id) {
                            guard let response = try self.debugWire.feed(byte) else { continue }
                            switch response {
                            case .packet(let payload):
                                guard let text = String(data:payload,encoding:.ascii) else { throw PairingError.malformed }
                                let sizes = text.split(separator:";").filter { $0.hasPrefix("PacketSize=") }
                                guard sizes.count == 1, try DebugProtocolWire.number(String(sizes[0].dropFirst(11))) >= 256 else { throw PairingError.malformed }
                                self.debugCapabilityComplete = true
                                if self.retainAuthorization {
                                    try manager.write(id,data:Data([43])) // acknowledge final RSP reply
                                    manager.cancelStream(id);self.debugStream = nil
                                    try self.arenaService.setVerifiedDebugService(manager:manager,port:port)
                                    self.authorizationReady = true;self.deadline = self.clock + 960
                                    let callback = self.completion;self.completion = nil
                                    callback?("Authenticated local debugger is ready for our app's bound memory-preparation request. No process attached yet.")
                                } else {
                                    self.finish("Authenticated local tunnel and raw debugger capability query passed. No debugger attachment or native execution permission tested.")
                                }
                                return
                            case .ack: break
                            case .nack,.badChecksum: throw PairingError.malformed
                            }
                        }
                    case .closed,.peerClosed: self.finish("Authenticated debug service closed before its capability response.")
                    default: break
                    }
                } catch { self.finish("Authenticated debug service did not return a valid raw capability response.") }
            }
        } catch { finish("Could not open the authenticated developer debug service.") }
    }
    private func finish(_ report: String) {
        guard !finished else { return }; finished = true
        authorizationReady = false
        arenaService.invalidate()
        discovery?.cancel();discovery = nil;manager?.cancel();manager = nil;proxy?.cancel()
        timer?.cancel(); timer = nil
        if let tcp { for event in tcp.abort() {
            if case .packet(let data) = event, let packet = try? codec?.outgoing(data) { _ = output?(packet) }
        } }
        tcp = nil; output = nil; ephemeral = nil; authentication?.close(); authentication = nil;enrollment = nil
        let detail = proxy.map { " \($0.diagnostic)." } ?? ""
        let directory = URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try? (report+detail).write(to:directory.appendingPathComponent("local-tunnel-progress.txt"),atomically:true,encoding:.utf8)
        let callback = completion; completion = nil; callback?(report+detail)
    }
    deinit { timer?.cancel(); if reservedPortFD >= 0 { Darwin.close(reservedPortFD) } }
}
