import Foundation
import Darwin

// Built only from our waiting host's IPC request. The host must retain these
// mappings/challenge and load no guest bytes until it accepts the matching
// successful detach receipt. Never build this descriptor from a game module.
struct DebugArenaRequest {
    struct Region: Equatable { let address: UInt64, size: UInt64 }
    let pid: UInt32, uid: UInt32
    let challengeAddress: UInt64, challenge: Data
    let regions: [Region]
    init(pid: UInt32, helperPID: UInt32, uid: UInt32, challengeAddress: UInt64, challenge: Data, regions: [Region]) throws {
        guard pid > 1, pid <= UInt32(Int32.max), pid != helperPID, pid != UInt32(getpid()), challenge.count == 32,
              challenge.contains(where:{ $0 != 0 }), challengeAddress >= 4096,
              challengeAddress <= 0x0000ffffffffffff-32, !regions.isEmpty, regions.count <= 4 else { throw PairingError.malformed }
        var total: UInt64 = 0
        for (index,region) in regions.enumerated() {
            guard region.address >= 16384, region.address % 16384 == 0, region.size > 0,
                  region.size <= 2048*1024*1024, region.size % 16384 == 0,
                  region.address <= 0x0000ffffffffffff-region.size,
                  region.address+region.size <= challengeAddress || challengeAddress+32 <= region.address else { throw PairingError.malformed }
            total += region.size
            guard total <= 2048*1024*1024 else { throw PairingError.oversized }
            for other in regions.prefix(index) {
                guard region.address+region.size <= other.address || other.address+other.size <= region.address else { throw PairingError.malformed }
            }
        }
        self.pid = pid; self.uid = uid; self.challengeAddress = challengeAddress; self.challenge = challenge; self.regions = regions
    }
}
