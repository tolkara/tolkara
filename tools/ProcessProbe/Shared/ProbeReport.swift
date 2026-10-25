// A process's own view of its limits, for comparing the app with its app-extension
// processes (docs/MULTIPROCESS.md): address space, how large one contiguous reservation
// can be, the system's current memory estimate, and whether MAP_JIT memory can be mapped.
import Darwin
import Foundation
import os

@objc protocol ProbeService {
    func report(_ reply: @escaping (String) -> Void)
}

enum ProbeReport {
    static func make(role: String) -> String {
        var lines = ["\(role) pid \(getpid()) bundle \(Bundle.main.bundleIdentifier ?? "?")"]
        var info = task_vm_info_data_t()
        let fields = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        var count = fields
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // min_address/max_address came with a later revision of TASK_VM_INFO: the kernel must fill them
        let rangeEnd = (MemoryLayout<task_vm_info_data_t>.offset(of: \task_vm_info_data_t.max_address) ?? 0) +
                       MemoryLayout<mach_vm_address_t>.size
        let haveRange = status == KERN_SUCCESS && Int(count) * MemoryLayout<natural_t>.size >= rangeEnd
        guard haveRange, info.max_address > info.min_address else {
            lines.append("TASK_VM_INFO unavailable (kr \(status), \(count) of \(fields) fields)")
            return lines.joined(separator: "\n")
        }
        lines.append(String(format: "address space %#llx-%#llx, footprint %llu MiB",
                            info.min_address, info.max_address, info.phys_footprint >> 20))
        // The largest unmapped interval inside [min, max), by walking the regions (metadata only).
        let low = vm_address_t(info.min_address), high = vm_address_t(info.max_address)
        var at = low, previousEnd = low
        var largest: vm_size_t = 0, largestAt: vm_address_t = 0
        var walkError: kern_return_t = KERN_SUCCESS
        while at < high {
            var size: vm_size_t = 0
            var region = vm_region_basic_info_data_64_t()
            var regionCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
            var object: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &region) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(regionCount)) {
                    vm_region_64(mach_task_self_, &at, &size, VM_REGION_BASIC_INFO_64, $0, &regionCount, &object)
                }
            }
            if object != 0 { mach_port_deallocate(mach_task_self_, object) }
            if kr != KERN_SUCCESS {
                if kr != KERN_INVALID_ADDRESS { walkError = kr }  // KERN_INVALID_ADDRESS: past the last region
                break
            }
            let start = min(max(at, low), high)
            if start > previousEnd && start - previousEnd > largest { largest = start - previousEnd; largestAt = previousEnd }
            let (end, overflow) = at.addingReportingOverflow(size)
            if overflow || size == 0 { break }
            previousEnd = max(previousEnd, min(end, high))
            at = end
        }
        if high > previousEnd && high - previousEnd > largest { largest = high - previousEnd; largestAt = previousEnd }
        lines.append(String(format: "largest free interval %lu MiB at %#lx%@", largest >> 20, largestAt,
                            walkError == KERN_SUCCESS ? "" : " (walk stopped, kr \(walkError))"))
        // One contiguous reservation at a time (each released before the next): individual capacity.
        for gib in [16, 32, 48, 56] {
            var address: vm_address_t = 0
            let size = vm_size_t(gib) << 30
            let kr = vm_allocate(mach_task_self_, &address, size, VM_FLAGS_ANYWHERE)
            var line = String(format: "reserve %d GiB alone: %@", gib,
                              kr == KERN_SUCCESS ? String(format: "ok at %#lx", address) : "failed (kr \(kr))")
            if kr == KERN_SUCCESS {
                let freed = vm_deallocate(mach_task_self_, address, size)
                if freed != KERN_SUCCESS { line += " (release failed, kr \(freed))" }
            }
            lines.append(line)
        }
        lines.append("os_proc_available_memory now \(os_proc_available_memory() >> 20) MiB (an estimate, not the jetsam limit)")
        // Mapping only; whether such memory could execute is not tested here.
        let page = Int(getpagesize())
        let jit = mmap(nil, page, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0)
        lines.append("MAP_JIT mapping: \(jit == MAP_FAILED ? "refused (errno \(errno))" : "mapped (execution not tested)")")
        if jit != MAP_FAILED { munmap(jit, page) }
        return lines.joined(separator: "\n")
    }
}

/// The App Group container both probe apps share; its identifier is in the Info.plist.
func groupContainer() -> URL? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "ProbeAppGroup") as? String else { return nil }
    return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
}

/// ProcessProbe's view of ProcessProbePeer: how old its heartbeat is (whether it is still
/// running) and its answer on the shared socket.
enum PeerCheck {
    static func run() -> String {
        guard let group = groupContainer() else { return "peer: no App Group container" }
        var lines: [String] = []
        let heartbeat = group.appendingPathComponent("peer-heartbeat")
        if let text = try? String(contentsOf: heartbeat, encoding: .utf8), let beat = Double(text) {
            lines.append(String(format: "peer heartbeat %.0f s old", Date().timeIntervalSince1970 - beat))
        } else {
            lines.append("peer heartbeat: none (peer never ran)")
        }
        let path = group.appendingPathComponent("peer.sock").path
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(client); return (lines + ["peer socket path too long (\(bytes.count) bytes)"]).joined(separator: "\n")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            lines.append("peer socket: connect failed (errno \(errno))")
        } else {
            _ = "report\n".withCString { write(client, $0, strlen($0)) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { if n < 0 { lines.append("peer socket: read failed (errno \(errno))") }; break }
                data.append(buffer, count: n)
            }
            lines.append("peer answered:\n" + (String(data: data, encoding: .utf8) ?? "?"))
        }
        close(client)
        return lines.joined(separator: "\n")
    }
}

extension PeerCheck {
    /// One bounded round trip: "ping <nonce>" → "pong <nonce> pid … uptime … phase …".
    static func ping(_ nonce: String, timeout seconds: Int = 2) -> String {
        guard let group = groupContainer() else { return "no group" }
        let path = group.appendingPathComponent("peer.sock").path
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return "path too long" }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return "connect failed errno \(errno)" }
        _ = "ping \(nonce)\n".withCString { write(client, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(client, &buffer, buffer.count)
        if n <= 0 { return n == 0 ? "closed without answer" : "no answer (errno \(errno))" }
        let answer = String(decoding: buffer.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.hasPrefix("pong \(nonce) ") ? answer : "WRONG answer: \(answer)"
    }
}
