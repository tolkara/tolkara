// Descriptor passing between two apps of one team (docs/MULTIPROCESS.md): Wine's server
// hands file descriptors to its clients, and window surfaces are shared memory. The peer
// sends, over fd.sock in the App Group container, three descriptors with SCM_RIGHTS: a
// temporary file (already unlinked), one end of a socketpair, and a file it has mapped
// shared. The host checks each after the peer has closed its own copies, then both try
// POSIX shared memory by name.
import Darwin
import Foundation

enum DescriptorProbe {
    static let shmName = "/tkprobe.shm"

    // MARK: peer side

    static func serve(in group: URL) {
        let path = group.appendingPathComponent("fd.sock").path
        guard let server = listenSocket(path) else { return }
        while true {
            let client = accept(server, nil, nil)
            if client < 0 { continue }
            handle(client, group: group)
            close(client)
        }
    }

    private static func handle(_ client: Int32, group: URL) {
        let nonce = readLine(client)
        // 1. a temporary file, unlinked before it is sent
        let filePath = group.appendingPathComponent("fd-probe-\(getpid()).tmp").path
        let file = open(filePath, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        _ = "file from peer \(nonce)".withCString { write(file, $0, strlen($0)) }
        unlink(filePath)
        // 2. a socketpair; the peer keeps one end
        var pair: [Int32] = [-1, -1]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        // 3. a shared file mapping
        let mapPath = group.appendingPathComponent("fd-probe-\(getpid()).map").path
        let mapFile = open(mapPath, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        ftruncate(mapFile, 16384)
        let map = mmap(nil, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, mapFile, 0)
        unlink(mapPath)
        if let map, map != MAP_FAILED { _ = "shared-1 \(nonce)".withCString { strcpy(map.assumingMemoryBound(to: CChar.self), $0) } }
        // POSIX shared memory by name, for the host to open
        shm_unlink(shmName)
        let shm = probe_shm_open(shmName, O_RDWR | O_CREAT, 0o600)
        let shmResult = shm < 0 ? "shm_open failed errno \(errno)" : "shm_open ok"
        if shm >= 0 { ftruncate(shm, 4096); close(shm) }

        let sent = sendDescriptors(client, [file, pair[1], mapFile], message: "\(shmResult)\n")
        close(file); close(pair[1]); close(mapFile)  // the host now holds the only copies of these
        guard sent else { close(pair[0]); return }
        _ = "pair hello \(nonce)".withCString { write(pair[0], $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(pair[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if read(pair[0], &buffer, buffer.count) > 0, let map, map != MAP_FAILED {
            _ = "shared-2 \(nonce)".withCString { strcpy(map.assumingMemoryBound(to: CChar.self), $0) }
            // The host then writes its own value into the mapping and asks what this side sees.
            if read(pair[0], &buffer, buffer.count) > 0 {
                let seen = String(cString: map.assumingMemoryBound(to: CChar.self))
                _ = seen.withCString { write(pair[0], $0, strlen($0)) }
            }
        }
        close(pair[0])
        if let map, map != MAP_FAILED { munmap(map, 16384) }
    }

    // MARK: host side

    static func check(in group: URL) -> String {
        let path = group.appendingPathComponent("fd.sock").path
        let nonce = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        var lines = ["descriptor probe (nonce \(nonce)):"]
        guard let client = connectSocket(path) else { return lines[0] + " connect to fd.sock failed (errno \(errno))" }
        defer { close(client) }
        _ = (nonce + "\n").withCString { write(client, $0, strlen($0)) }
        guard let (fds, message) = receiveDescriptors(client), fds.count == 3 else {
            return lines[0] + " no descriptors received (errno \(errno))"
        }
        lines.append("received \(fds.count) descriptors; peer: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        // 1. the unlinked file
        var buffer = [CChar](repeating: 0, count: 256)
        lseek(fds[0], 0, SEEK_SET)
        let n = read(fds[0], &buffer, 255)
        let fileText = n > 0 ? String(cString: buffer) : "read failed errno \(errno)"
        lines.append("file: \(fileText == "file from peer \(nonce)" ? "ok" : "FAIL (\(fileText))")")
        // 2. the socketpair end
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        buffer = [CChar](repeating: 0, count: 256)
        let m = read(fds[1], &buffer, 255)
        let pairText = m > 0 ? String(cString: buffer) : "read failed errno \(errno)"
        lines.append("socketpair: \(pairText == "pair hello \(nonce)" ? "ok" : "FAIL (\(pairText))")")
        // 3. the shared mapping: written by the peer before and after our reply
        let map = mmap(nil, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fds[2], 0)
        if let map, map != MAP_FAILED {
            let first = String(cString: map.assumingMemoryBound(to: CChar.self))
            lines.append("shared map before: \(first == "shared-1 \(nonce)" ? "ok" : "FAIL (\(first))")")
            _ = "ack".withCString { write(fds[1], $0, strlen($0)) }
            var second = ""
            for _ in 0..<50 {
                second = String(cString: map.assumingMemoryBound(to: CChar.self))
                if second == "shared-2 \(nonce)" { break }
                usleep(100_000)
            }
            lines.append("shared map after peer's write: \(second == "shared-2 \(nonce)" ? "ok" : "FAIL (\(second))")")
            // Now the other direction: the host writes, the peer reads it back from its own mapping.
            let mine = "host-3 \(nonce)"
            _ = mine.withCString { strcpy(map.assumingMemoryBound(to: CChar.self), $0) }
            _ = "check".withCString { write(fds[1], $0, strlen($0)) }
            buffer = [CChar](repeating: 0, count: 256)
            let k = read(fds[1], &buffer, 255)
            let seen = k > 0 ? String(cString: buffer) : "no answer errno \(errno)"
            lines.append("shared map, host's write seen by peer: \(seen == mine ? "ok" : "FAIL (\(seen))")")
            munmap(map, 16384)
        } else {
            lines.append("shared map: mmap failed errno \(errno)")
        }
        fds.forEach { close($0) }
        // POSIX shared memory by name, created by the peer
        let shm = probe_shm_open(shmName, O_RDWR, 0)
        lines.append("shm_open of the peer's \(shmName): \(shm >= 0 ? "ok" : "failed errno \(errno)")")
        if shm >= 0 { close(shm) }
        return lines.joined(separator: "\n")
    }

    // MARK: helpers

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        return address
    }

    private static func listenSocket(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    private static func connectSocket(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    private static func readLine(_ fd: Int32) -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 64, read(fd, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sendDescriptors(_ socket: Int32, _ fds: [Int32], message: String) -> Bool {
        var payload = Array(message.utf8)
        let space = Int(CMSG_SPACE_(MemoryLayout<Int32>.size * fds.count))
        var control = [UInt8](repeating: 0, count: space)
        return payload.withUnsafeMutableBytes { payloadBytes -> Bool in
            var iov = iovec(iov_base: payloadBytes.baseAddress, iov_len: payloadBytes.count)
            return control.withUnsafeMutableBytes { controlBytes -> Bool in
                let cmsg = controlBytes.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                cmsg.pointee.cmsg_len = socklen_t(CMSG_LEN_(MemoryLayout<Int32>.size * fds.count))
                let data = UnsafeMutableRawPointer(cmsg).advanced(by: CMSG_ALIGN_(MemoryLayout<cmsghdr>.size))
                fds.enumerated().forEach { data.storeBytes(of: $1, toByteOffset: $0 * 4, as: Int32.self) }
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> Bool in
                    var header = msghdr()
                    header.msg_iov = iovPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBytes.baseAddress
                    header.msg_controllen = socklen_t(space)
                    return sendmsg(socket, &header, 0) >= 0
                }
            }
        }
    }

    private static func receiveDescriptors(_ socket: Int32) -> ([Int32], String)? {
        var payload = [UInt8](repeating: 0, count: 256)
        let space = Int(CMSG_SPACE_(MemoryLayout<Int32>.size * 8))
        var control = [UInt8](repeating: 0, count: space)
        return payload.withUnsafeMutableBytes { payloadBytes -> ([Int32], String)? in
            var iov = iovec(iov_base: payloadBytes.baseAddress, iov_len: payloadBytes.count)
            return control.withUnsafeMutableBytes { controlBytes -> ([Int32], String)? in
                var header = msghdr()
                let n = withUnsafeMutablePointer(to: &iov) { iovPointer -> Int in
                    header.msg_iov = iovPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBytes.baseAddress
                    header.msg_controllen = socklen_t(space)
                    return recvmsg(socket, &header, 0)
                }
                guard n >= 0, header.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return nil }
                let cmsg = controlBytes.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                guard cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS else { return nil }
                let count = (Int(cmsg.pointee.cmsg_len) - CMSG_ALIGN_(MemoryLayout<cmsghdr>.size)) / 4
                let data = UnsafeRawPointer(cmsg).advanced(by: CMSG_ALIGN_(MemoryLayout<cmsghdr>.size))
                let fds = (0..<count).map { data.load(fromByteOffset: $0 * 4, as: Int32.self) }
                return (fds, String(decoding: payloadBytes.prefix(n), as: UTF8.self))
            }
        }
    }

    // The CMSG_* macros are not imported into Swift.
    private static func CMSG_ALIGN_(_ n: Int) -> Int { (n + MemoryLayout<UInt32>.size - 1) & ~(MemoryLayout<UInt32>.size - 1) }
    private static func CMSG_SPACE_(_ n: Int) -> Int { CMSG_ALIGN_(MemoryLayout<cmsghdr>.size) + CMSG_ALIGN_(n) }
    private static func CMSG_LEN_(_ n: Int) -> Int { CMSG_ALIGN_(MemoryLayout<cmsghdr>.size) + n }
}
