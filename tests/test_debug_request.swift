import Foundation
private func reject(_ block: () throws -> Void) { do { try block(); fatalError("invalid request accepted") } catch {} }
@main struct RequestTests {
    static func main() throws {
        func make(pid: UInt32 = 1234, helper: UInt32 = 4321, nonceAddress: UInt64 = 0x100000, nonce: Data = Data(1...32), regions: [DebugArenaRequest.Region] = [.init(address:0x200000,size:16384)]) throws -> DebugArenaRequest {
            try DebugArenaRequest(pid:pid,helperPID:helper,uid:501,challengeAddress:nonceAddress,challenge:nonce,regions:regions)
        }
        _ = try make()
        // Exactly the 2 GiB ceiling is accepted, as one region or split across several.
        _ = try make(regions:[.init(address:0x200000,size:2048*1024*1024)])
        _ = try make(regions:[.init(address:0x200000,size:1024*1024*1024),.init(address:0x100000000,size:1024*1024*1024)])
        for pid: UInt32 in [0,1,4321,UInt32.max] { reject { _ = try make(pid:pid) } }
        reject { _ = try make(pid:UInt32(getpid())) }
        for nonce in [Data(),Data(repeating:1,count:31),Data(repeating:0,count:32),Data(repeating:1,count:33)] { reject { _ = try make(nonce:nonce) } }
        for address: UInt64 in [0,UInt64.max,0x200000,0x1ffff0] { reject { _ = try make(nonceAddress:address) } }
        for range in [DebugArenaRequest.Region(address:0x200001,size:16384),.init(address:0x200000,size:1),.init(address:0x200000,size:0),.init(address:0x200000,size:2048*1024*1024+16384),.init(address:0xffffffffffffc000,size:16384)] { reject { _ = try make(regions:[range]) } }
        reject { _ = try make(regions:[]) }
        reject { _ = try make(regions:[.init(address:0x200000,size:32768),.init(address:0x204000,size:16384)]) }
        // A total one page over the ceiling fails as oversized, not as an overlap.
        do { _ = try make(regions:[.init(address:0x200000,size:2048*1024*1024),.init(address:0x100000000,size:16384)]); fatalError("oversized request accepted") } catch PairingError.oversized {}
        print("Debug request: self/PID, nonce, alignment, overflow, overlap and size bounds passed")
    }
}
