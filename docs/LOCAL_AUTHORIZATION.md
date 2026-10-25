# Integrated native authorization

> Engineering notes written during bring-up, kept for their protocol detail.
> They include historical intermediate states. `build/*.log` and `logs/` paths
> are local evidence files on the author's machine and are not in the repository.
> For a how-to, read [BUILDING.md](BUILDING.md) first. This is the
> **Developer service** execution mode; the other modes, Local signing and
> External JIT, are described in [ARCHITECTURE.md](ARCHITECTURE.md).

In this mode Tolkara is one installed app. It does not rely on an external
JIT-enabler app (External JIT is the separate mode that does) or an embedded
third-party JIT library: the app bundles its own packet-tunnel
extension and speaks to the iPad's own developer services over a local route.
The imported macOS executable stays unchanged data outside the signed app; in
this mode nothing of it is ever signed.

## Current physical status (September 20)

Own-code execution and full original-image authorization now pass through our
bundled helper. Full 87,425,024-byte preparation, verification and confirmed
detachment took 81.584 seconds with checked -O optimization. The host accepted
its matching receipt and executed every original initializer. Original main
subsequently reached Metal rendering and audio after a QuartzCore sizing wait;
the login screen was confirmed on the device. Disconnected cold launch and launch after a reboot were confirmed later.
The implementation notes below include historical intermediate states.

Long-lived provider-message replies could be lost while the host was stopped.
Production now submits once, receives pending, and polls the same bound
request for an in-memory completion. Polling never repeats an attachment;
unknown status after helper loss remains uncertain and preserves the arena.

## Implemented and checked

- `Tolkara` is an optional Xcode scheme with the same application identity
  as Host. `Host` remains the existing prototype build. Both reuse our Mach-O
  loader and adapters. Do not install the incomplete integrated build over the
  physical prototype without a concrete device test plan.
- Our `LocalAuthorizationTunnel` packet-tunnel extension is embedded in
  Tolkara. Its fixed virtual interface is 10.7.0.2, peer 10.7.0.1, with a
  /32 included peer route and excluded default route. It swaps the addresses of
  only matching IPv4 packets and feeds them back into the local stack. It creates
  no external sockets and supplies no DNS configuration. Game internet traffic
  should remain outside this route; actual device routing remains unverified.
- Our bounded packet routine checks IPv4/header/total lengths and exact address
  pairs. ASan/UBSan tests verify payload and IP/TCP checksum preservation,
  unrelated-traffic rejection and malformed input bounds.
- The Diagnostics menu's Developer service section (formerly "Local launch setup") can check
  TCP reachability of 127.0.0.1:49152 or request or stop our optional route.
  Starting it is an explicit action that may require iPadOS's VPN
  configuration consent. It never starts automatically at launch.
- `--direct-authorization-probe` runs the same bounded, credentials-free TCP check
  and writes Documents/direct-authorization-probe.txt. A failed connection only
  rejects that one endpoint at that moment. A successful connection proves
  neither service identity nor pairing nor native execution permission.
- The extension's control status explicitly reports nativeExecutionReady=false.
  No network state is treated as permission to run downloaded instructions.
- Our `DebugWire` codec implements bounded streaming GDB remote packet framing,
  checksums, binary escaping, response run-length encoding, notifications and
  ACK/NACK parsing. Unit tests include all byte values, invalid checksum, output
  bounds and malformed-stream recovery. The command layer and synthetic debug
  connection described below are now implemented; no real attachment is tested.
- `authorization/Pairing` now supplies our bounded RPPairing/CDTunnel frame codec,
  TLV8 fragmentation/parser and CryptoKit key derivation/proof encryption. The
  encrypted request channel allows one outstanding request, consumes nonces once
  and closes after authentication/encryption failure. None of these primitives
  claims completed pairing or verifies the device's long-term identity yet.
- Pairing tests pass with AddressSanitizer, an RFC 7748 X25519 vector,
  independently generated HKDF-SHA512 expectations, literal wire fixtures,
  malformed/truncated inputs, 254/255-byte fragments, modified ciphertext,
  invalid keys, response replay and the counter transition through 255.
  Evidence: build/pairing-unit-tests.log. No real pairing credentials are used.
- `TunnelTLS.m` configures Apple's Network/Security TLS stack for the documented
  TLS 1.2 PSK suites. Both AES256-CBC-SHA384 and AES128-CBC-SHA exchanged encrypted
  application data with an independent local OpenSSL test peer; an incorrect
  PSK was rejected in both cases. Evidence: build/system-psk-probe.log. This is
  macOS interoperability evidence, not an iPad development-service handshake.
  OpenSSL is used only by the host test and is not included in the app.
- The pairing sources are compiled into our bundled extension. Simulator and
  signed device builds passed: build/pairing-{sim,device}-build.log. Xcode emits
  its metadata-extraction notice because the extension does not use AppIntents.
  No updated app was installed on either the physical device or simulator in
  this iteration, and no VPN was enabled.
- The next iteration adds `PairingIdentity`, `PairingSession` and
  `PairingConnection`. The existing-pair client performs the host handshake,
  validates an encrypted and signed peer proof, signs the host proof, checks the
  verification state, and requests a tunnel listener through the encrypted
  channel. The returned offer is only a port/session key, never JIT readiness.
  The TCP connection has bounded reads and per-phase deadlines, a serial owner,
  cancellation and exactly one completion. Keep it alive until tunnel teardown:
  the listener may depend on the control connection's lifetime.
- Device-proof verification uses the HAP-style transcript in Apple's public
  Pair Verify implementation (device ephemeral key, device ID, host ephemeral
  key). Reuse by this iPad's Remote Pairing service is **not yet verified**.
  Missing proof, unknown identity or signature mismatch fails the session;
  no compatibility fallback skips authentication. The record requires a trusted
  device identifier and public key in addition to matching host signing keys.
  Parsing validates structure, not the provenance of the trust anchor. Existing
  minimal third-party pair files without a device key are not accepted as an
  authenticated record. Enrollment/import and protected persistence remain open.
- Synthetic session tests cover the complete exchange, key/identity mismatch,
  ciphertext modification, replay, invalid message order and listener ports.
  Loopback TCP tests cover the exchange with fragmented writes, forged proofs,
  invalid/truncated/extra framing, silent-peer timeout and cancellation. Evidence:
  build/pairing-session-tests.log and build/pairing-connection-tests.log. The
  initial test-fixture Data-slice indexing error was fixed; it was not a game or
  transport crash. No real pairing record or development service was accessed.
- Latest simulator and device builds passed in
  build/pairing-session-{sim,device}-build.log; both device bundle signatures
  verified. The only build notice is skipped AppIntents metadata extraction.
  These binaries were not installed, so physical and simulator app state remain
  unchanged.
- `authorization/Transport` now implements the CDTunnel handshake and encrypted
  IPv6 packet transport, using the same system TLS setup as the existing probe.
  It validates numeric unicast IPv6 endpoints, contiguous subnet masks, MTU and
  RSD port, packet lengths and direction, and handles the handshake-to-packet
  transition even within a single TLS receive. Input and pending writes are
  bounded. Handshake, partial-packet and write deadlines, cancellation, and
  stale-timer guards keep failure asynchronous and terminal.
- CDTunnel unit tests pass under ASan for fragmented/coalesced reads, limits,
  malformed addresses/masks/ports, wrong endpoints and truncated packets.
  An independent OpenSSL peer exchanged synthetic IPv6 packets through our
  actual encrypted connection. Wrong PSK, malformed handshake, oversized packet,
  truncated handshake, silent peer and partial-packet timeout were rejected.
  Evidence: build/cdtunnel-wire-tests.log and build/cdtunnel-transport-tests.log.
  These are Mac loopback tests, not on-device network or execution permission.
  No kernel routes, VPN preferences or device pairing records were accessed.
  A burst-write test also verifies backpressure and completion delivery. The
  256 KiB/64-write admission bound is reserved before queue dispatch, so queued
  closures cannot retain unlimited packet data while the worker is busy.
  Final simulator/device builds passed in build/cdtunnel-{sim,device}-build.log;
  signatures verified and the app still excludes the original executable.
  Only the expected AppIntents metadata notice remains. Neither build was
  installed, so both existing app installations are unchanged.
- Simulator and device builds signed successfully. Actual new provisioning
  profiles contain get-task-allow and packet-tunnel-provider for both host and
  extension. This supersedes the earlier failed StikDebug signing attempt.
  Final clean build logs: build/integrated-final-sim-build.log,
  build/integrated-final-device-build.log.
  The signed app contains no OriginalExecutable.bin or Guest.framework.
- The final integrated app was installed/launched in the simulator only.
  Its direct-loopback probe returned ECONNREFUSED (61) and remained responsive;
  build/integrated-direct-probe.txt and build/integrated-direct-probe.png record
  this. It does not determine physical-iPad reachability or tunnel necessity.
  No VPN configuration was created, no debug connection established, and the
  physical iPad build was not changed.

## What still needs implementation / real device evidence

### Bounded TCP work (02:14 iteration)

`TunnelTCP.swift` now implements an active-open stream over the private IPv6
tunnel: checksums, tuple/header/options checks, SYN/ACK, MSS segmentation,
ACK/partial-ACK handling, bounded windows, duplicate/overlap handling, sequence
wrap, retransmission/backoff, zero-window probes/deadlines, validated resets and
half-close/FIN/TIME-WAIT. It retains one outstanding segment, with 64 KiB send and
32 KiB receive queues. This is for device control connections, not game traffic.
It is not a general internet TCP stack: no scaling, SACK, urgent-data semantics,
fragmentation or IPv6 extensions; out-of-order data is dropped/ACKed for retry.

ASan tests pass in build/tunnel-tcp-unit-tests.log. An independent Python packet
peer checked every checksum while transferring 9000/40000 bytes with loss,
partial ACK, zero window, reordering, duplication, wrap and half-close:
build/tunnel-tcp-peer-tests.log. A separate OpenSSL/Python test connected this core
through the actual encrypted CDTunnelConnection and passed TLS, tunnel setup,
TCP handshake, bidirectional data and close: build/tcp-over-tunnel-tests.log.
These are synthetic peers, not kernel-TCP conformance or real-device evidence.
At that iteration, production coordination was still missing; see Managed
connections below for its implementation. This older probe uses test tuples.
Latest simulator/device builds passed in build/tunnel-tcp-{sim,device}-build.log,
with only the AppIntents metadata notice. Host and extension signatures verified;
the app excludes the original guest executable. Neither build was installed.

### RemoteXPC / service discovery (03:14 iteration)

`RemoteXPCWire.swift` is our bounded binary codec: typed dictionaries/arrays,
UTF-8 strings, data, UUIDs and numeric values; correct collection byte lengths,
message IDs and little-endian wrapper lengths. Limits are 1 MiB payload, depth
32 and 16,384 objects. Duplicate keys, malformed bounds/types and truncation
fail closed. Independent channel assemblers preserve split/coalesced messages.

`RemoteDiscovery.swift` implements the narrow HTTP/2 RemoteXPC discovery exchange:
root/reply stream opening order, version-7 handshake, settings/ACK, peer send
windows and receive credits, PING, bounded frames and a fixed 20-second deadline.
It parses the advertised service ports and UsesRemoteXPC flags, requiring an
exact expected device identifier from trusted enrollment/selection. That check
is additional binding, not a replacement for the authenticated tunnel. The
Remote Pairing peer identifier is not assumed to equal the RSD UniqueDeviceID.
No debugger port is guessed and discovery alone never means native execution
is authorized. Header blocks must be empty; HPACK, file transfer, pushed streams
and general RemoteXPC RPC are intentionally not implemented here.

ASan tests and an independent Python peer passed in
build/remote-xpc-unit-tests.log and build/remote-discovery-peer-tests.log:
literal wire vectors, all supported types, every message split, hostile lengths,
depth/count limits, interleaved channels, identity mismatch, timeout and flow
control, including an initial zero window and a catalog larger than 64 KiB.
An OpenSSL/Python peer also passed the whole TLS -> CDTunnel -> IPv6/TCP ->
HTTP/2 -> RemoteXPC exchange with 702 services and graceful close:
build/rsd-over-tunnel-tests.log. No real device services or pairing records were
accessed. The combined probe uses fixture tuples and no production timer loop;
production connection coordination is covered by the next iteration below.

Latest builds: build/remote-discovery-{sim,device}-build.log, both successful
with only the AppIntents metadata notice. Host and extension signatures verified;
both app bundles exclude OriginalExecutable.bin and Guest.framework. These
sources are compiled into our bundled extension, but have no app launch
coordinator yet. Neither build was installed.

### Managed connections (04:14 iteration)

`TunnelStreams.swift` owns at most eight TCP connections with independent bounded
buffers. It allocates random ephemeral ports and initial sequence numbers,
demultiplexes complete validated tuples, drives retransmission/close timers and
quarantines retired ports for 120 seconds, including failed/aborted streams.
An old handle or delayed packet cannot operate on a newly opened connection.
The private control TCP limitations described above still apply.

`TunnelConnectionManager.swift` confines transport, stream mutation and callbacks
to one serial queue shared with CDTunnelConnection. A DispatchSource timer drives
TCP without test-harness intervention. A 256 KiB/256-packet FIFO and one link write
in flight bound output while preserving packet order. Stream callbacks support
reentrant cancellation; teardown cancels timers, removes handlers and ignores
late completions. Internal callers must use its queue and return promptly.

`TunnelDiscoveryClient.swift` connects the RemoteXPC exchange to those streams,
with a fixed startup deadline and retained RSD connection. `LocalDeveloperSession`
owns existing-pair verification -> encrypted tunnel -> discovery and retains the
pairing control connection until teardown. Its ready callback supplies a catalog
and connection manager, not any executable-memory authorization. It still needs
a trusted pairing identity and separately bound expected RSD device identifier.
It is compiled into the helper but is not wired into the app's launch UI.

ASan evidence: build/tunnel-streams-unit-tests.log,
build/tunnel-manager-unit-tests.log, build/developer-session-unit-tests.log.
These cover tuple allocation/quarantine, isolation, admission bounds, automatic
timeouts, queue order, proof/TLS failure, startup deadline, reentrant/late
callbacks and cleanup. An independent OpenSSL/Python peer exercises the actual
manager and discovery client in build/managed-tunnel-tests.log: deliberately
drops the first SYN, observes an automatic retry, supplies a 702-service catalog,
then exchanges bytes on a second advertised service over the same tunnel and
checks whole-session cancellation. That fixture injects a synthetic verified
pairing offer; it does NOT validate real Remote Pairing or enrollment. Existing
pairing tests remain separate. The shared CDTunnel regression also passes.

Latest builds: build/managed-tunnel-{sim,device}-build.log, both successful with
only the AppIntents metadata notice. Host and extension signatures verified;
both app bundles exclude the guest executable. No real device service, pairing
credential, VPN configuration or installed iPad application was accessed.

### Protected pairing storage (05:16 iteration)

`authorization/Storage/PairingEnrollment.swift` binds the existing-pair identity to
its separately trusted RSD device identifier and a stable connection UUID. Its
bounded versioned envelope rejects unknown fields, invalid identities and
oversized input. Parsing is not authenticated enrollment or approval.

`PairingKeychain.swift` stores records as generic-password items in our explicit
shared Keychain access group, using WhenUnlockedThisDeviceOnly, no synchronization
and the data-protection Keychain. Queries are scoped to our service and one hashed
device identifier; it never enumerates the user's Keychain or falls back to a
file. Reads verify protection metadata and the bound identifier. Re-inserting
an identical identity is idempotent; replacing a host/device key or binding is
rejected until an explicit forget operation. No update/delete-and-retry fallback
silently replaces trust. API callers must supply an authenticated enrollment or
explicitly approved import; no real record has been imported by this work.

Tolkara and its extension now share the signed
`<team ID>.local.tolkara.authorization` group, with matching Info.plist configuration.
Tolkara uses Integrated-Info.plist; HostBase excludes its old Info.plist
from copied resources to avoid a duplicate after the override. The baseline Host
still uses its original Info.plist. Only our own storage/identity code was added
to the host. The storage API is not connected to enrollment UI yet.

ASan unit evidence: build/pairing-storage-unit-tests.log. Simulator evidence:
build/pairing-storage-simulator-tests.log. Three **simulator-only** probe app
identities used an isolated .authorization.probe group and deterministic public
fixture keys. Tests passed write/readback, conflicting-pin rejection, forced
process restart, cross-app shared access, rejection without the shared entitlement
(-34018), shared deletion and absence. The fixture record and all three test apps
were removed afterward. No real pairing credentials were accessed. Simulator
results do not establish physical-device protection-at-rest or locked behavior.
The probe initially needed a UIKit scene lifecycle for SDK 27; it now has one.

Latest successful builds: build/pairing-storage-{sim,device}-build.log. App and
extension signatures verified, their signed groups match configuration, and the
app excludes the guest executable: build/pairing-storage-signing.txt. The updated
Tolkara was installed **only in the simulator** and its direct-route probe
ran successfully, reporting ECONNREFUSED again:
build/pairing-storage-direct-probe.txt. Physical iPad installation is unchanged.

### Fresh-arena debugger transaction (06:16 heartbeat)

`authorization/Debugger` now implements a bounded all-stop RSP transaction through
our managed encrypted transport. `DebugArenaRequest` binds the waiting host's
PID/UID, a per-launch 32-byte memory challenge, and up to four non-overlapping
16 KiB-aligned fresh arenas (1 GiB total; bounded by an 1800-second preparation deadline). It rejects self-attachment, overflow,
challenge overlap and invalid ranges. The host request producer and mapping
lifetime/IPC gate are not connected to the native loader yet.

`DebugArenaSession` negotiates packet bounds, switches acknowledgements off
(QStartNoAckMode; debugserver then sends `#00` in place of checksums, and the
encrypted tunnel already guarantees delivery), requires QSetDetachOnError:1 before
attaching, validates exact PID/effective UID/ARM64/little-endian/64-bit pointers,
and reads the challenge from target memory. Every mapping must be anonymous RX;
every byte of every arena must read back as zero, four reads per batch, before
the first write. A debugger write prepares the whole 16 KiB page it lands in (as
StikJIT's region preparation relies on), so it then writes one zero byte into
each page and reads it back, 128 pages per batch. It writes only zeros, rechecks
the process and challenge, then requires a successful D reply. A failed reply
inside a batch is followed by the rest of that batch's replies, then the detach. EOF, connection loss or timeout is never a success receipt.
No guest bytes, registers, breakpoints or arbitrary writes are supported.

Semantic failures while stopped attempt a confirmed detach. Uncertain transport
failures close the connection and report detachConfirmed=false; the configured
detach-on-error policy is not itself proof of detachment. Protocol deadlines,
bounded checksum/NACK retries before no-ack mode and unsolicited/trailing-reply
rejection preserve failure. No process memory or console output is logged. `DebugArenaClient` owns
the managed stream/timer and closes it exactly once on terminal completion.

ASan request tests: build/debug-request-unit-tests.log. Independent Python RSP
peer: build/debug-arena-peer-tests.log (full preflight, zero-only writes/readback,
wrong PID/UID/architecture/challenge, unsafe/nonzero mappings, detach errors,
trailing data after a successful detach reply, retry limits and deadlines).
Independent encrypted TLS/CDTunnel/IPv6/TCP/RSP peer:
build/debug-over-tunnel-tests.log (success, wrong challenge with confirmed cleanup,
missing detach reply with timeout/failure). These use synthetic addresses and
public test keys and never attach to a real process. Real debugserver command
interoperability remains unverified.

Builds build/debug-arena-{sim,device}-build.log pass; runtime and extension
signatures verify for both. The only warning is unused AppIntents metadata.
The signed app still excludes the original guest executable. Neither build was
installed; the physical prototype and previous simulator installation are intact.

Batched preparation (September 27, iPad Pro M5, iPadOS 27): Heroes III's
109,854,720-byte arena was prepared and detached in 33.0 s, against 104.0 s when
every byte was written and read back one command at a time, and the game's
translated code ran from it. Apple's macOS debugserver prepares the 130-page
fixture of `tools/test_native_debugserver.py` the same way.

The required lifetime and IPC gate is now implemented below. The original
boolean publisher remains the Mac-assisted path.

### Host/helper memory ownership and IPC (07:16 heartbeat)

`nc_create_managed` distinguishes confirmed preparation, safe rejection and an
uncertain helper. Rejection releases the fresh mappings; confirmed preparation
enables the writable alias; uncertainty retains both mappings in a quarantine
owner without enabling writes. nc_write and nc_destroy cannot write/release a
quarantined arena. An occupied quarantine prevents another allocation/attempt.
The existing nc_create boolean API remains a wrapper for the Mac publisher.

`authorization/Control/ArenaControl` is our fixed 96-byte, network-order owning-app/
provider message format. It binds PID/UID, one fresh arena, a mapped 32-byte
challenge, random request ID and monotonic deadline. Exact reply matching rejects
any altered field, version, length or malformed outcome. No game bytes, pairing
keys or arbitrary memory commands cross this interface.

`LocalArenaPublisher` is a single-use host owner. Its private challenge mapping
is read-only and stays mapped for process lifetime on uncertainty. A missing,
invalid, late or contradictory reply cannot promote readiness. Main-thread waits
pump the host run loop; launch must occur from a run-loop callout, not while
holding a main-dispatch block. The import-completion path now schedules that
callout. The native loader also has an atomic one-attempt guard, preventing
recursive Objective-C hook installation after early startup failure.

NativeGuest selects this publisher only with the opt-in
`--local-native-authorization` argument alongside the existing native startup/
initializer argument. The owning app sends its request through its connected
NETunnelProviderSession; it never starts a VPN or requests consent implicitly.
Without a configured route/helper it rejects. For such a development run the
Tolkara launcher first prepares the route and helper exactly as a library
launch does (report in `Documents/local-game-setup.txt`) and enters the guest
from a timer callout once they are ready, so it needs no Mac. Without the
argument, Mac-assisted startup still uses host_debugger_publish_arena.

The bundled provider now passes binary arena messages to `ArenaPreparationService`.
Its default is a definite rejection: no debugger connection is attempted until
an authenticated ready raw service/manager is explicitly installed. Its private
setter is currently exercised only by fixtures, not connected to real enrollment
or service discovery. Once configured it runs DebugArenaClient with the request
deadline, returns a bound receipt, and refuses a second attach attempt. Provider
shutdown invalidates it and cancels outstanding work. Pairing keys are never put
in these messages. Keep the owning LocalDeveloperSession alive when connecting
this service to the real backend.

Evidence:
- build/arena-control-tests.log: literal wire fixture, every-byte reply binding,
  truncation, invalid bounds and overlap.
- build/native-memory-gate-tests.log: alias coherence, actual RX/RW VM protections,
  safe rejection cleanup, retained uncertainty and denied writes/retries.
- build/local-arena-publisher-tests.log: main-loop reply delivery, exact receipt,
  safe/uncertain outcomes, timeout, late success, contradictory transport result,
  one-shot behavior and retained challenge mapping.
- build/arena-service-tests.log: independent encrypted TLS/CDTunnel/TCP/RSP peer,
  success, wrong challenge/confirmed detach, lost detach reply, service expiry;
  unconfigured and second requests are rejected.
- build/native-debugserver-tests.log: Apple's actual macOS debugserver attached
  only to our disposable signed C fixture, prepared its zero-filled arena and
  confirmed detach. The fixture then verified unchanged zero bytes and exited.
  No game code or generated instructions were executed. The first harness used a
  shared process group that stopped during cleanup; isolated child sessions fixed
  it, and a second run passed and exited normally. This establishes macOS RSP
  interoperability, not iPad authorization/TXM behavior or standalone gameplay.
- build/arena-gate-regression-tests.log: tools/test_emulation.sh passed.
- build/arena-gate-simulator-probe.txt: actual Tolkara publisher rejected
  unconfigured authorization, released fresh memory and blocked guest entry.
- build/native-retry-simulator-probe.txt: actual native loader failed on an absent
  own test path, rejected a second startup before reinstalling hooks, and retained
  working host argument lookup. No guest file was loaded or run.

Tolkara/extension simulator and signed-device builds are recorded in
build/arena-gate-{sim,device}-build.log. Only the simulator app was installed.
Both app and extension signatures verified; build/arena-gate-signing.txt records
the host entitlements. These diagnostic builds do not enable NATIVE_GUEST_SHIMS
and are not complete gameplay packages.
Physical iPad prototype is unchanged; no new pairing record, VPN configuration,
device attachment or shader service was created. The original executable hash
still matches the recorded SHA-256; proprietary guest code remains outside the
signed app.

Protocol research also confirms the modern named RSD endpoint
`com.apple.internal.dt.remote.debugproxy` is used as a raw LLDB connection by the
reference client. Its developer-service connection skips generic RSDCheckin;
do not blindly send that plist exchange to every discovered port. Validate the
actual authenticated catalog/transport on the device and handle missing DDI
services explicitly. See the primary debugserver/RSD references below.

### Remaining gates

1. Verify direct route availability on M5/iPadOS 27, then the optional virtual
   route. The simulator cannot validate the physical development service, TXM
   executable permissions, or packet-tunnel device behavior.
2. Implement authenticated Remote Pairing from the protocol specification using
   system cryptography. Protected shared Keychain storage is now implemented;
   connect a supported enrollment/approved-import flow to it. Never use
   Files-shared Documents or logs. Do not weaken verification or substitute an
   unauthenticated endpoint check. No real pairing credentials have been read or
   transferred by this new implementation.
   The raw `_remotepairing._tcp` endpoint supports existing-pair verification,
   **not initial pair setup**. Establish a supported enrollment/import path;
   availability of a local VPN or development signing does not supply a pairing
   identity. The reference spec calls device-proof decryption optional and TLS
   Finished mismatches nonfatal; do not carry those relaxations into our code.
   Resolve and verify device identity proof rather than claiming that a decrypted
   message authenticates its sender. System TLS now avoids implementing TLS
   records ourselves and must retain its authentication checks.
   The existing-pair session/transport now has synthetic coverage; next validate
   its real device envelope fields and proof format, and implement enrollment
   using the new protected store. Do not silently accept an unverified peer to get
   past an interoperability failure.
3. The managed pairing/tunnel/discovery lifecycle now has local synthetic peer
   coverage. Validate actual Remote Pairing, direct/optional tunnel routing,
   device discovery and developer-image readiness/service check-in. The manager
   retains the pairing control connection through its owning session; the app
   launch UI is not yet connected to it.
4. Validate a separate helper process and its network path. A tunnel extension
   already supplies a second process, but its own outgoing connections may bypass
   tunnel routing. Do not assume it can act as the debug client without testing;
   a separate *bundled* extension may be necessary. Do not attach from the target
   process itself or rely on the suspended host to relay debugger traffic.
5. Connect authenticated enrollment/session/discovery to the new preparation
   service; its production instance currently rejects as unconfigured. Host IPC,
   retention, one-shot launch and quarantine are implemented and tested. Select
   the validated raw debugserver service and handle developer-image readiness;
   then test the entire path on M5. Preserve visible startup errors and never
   treat transport readiness or CS_DEBUGGED alone as native authorization.
6. Demonstrate original native startup after force-close/relaunch with no Mac.
   The Mac shader compiler is now only a fallback for libraries the iPad
   refuses (the adapter tries the iPad first; see ARCHITECTURE.md); confirm
   with the captured-shader diagnostic (`tools/probe_captured_shaders.py`)
   that none of the game's libraries needs it.

## Primary protocol/API references (not bundled dependencies)

- [Apple packet tunnel provider](https://developer.apple.com/documentation/networkextension/packet-tunnel-provider)
- [Keychain access groups](https://developer.apple.com/documentation/security/ksecattraccessgroup)
- [Device-only unlocked Keychain access](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
- [Apple provider messages](https://developer.apple.com/documentation/networkextension/netunnelprovidersession/sendprovidermessage(_:responsehandler:))
- [GDB remote wire protocol](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Overview.html)
- [LLDB debugserver extensions](https://lldb.llvm.org/resources/lldbgdbremote.html)
- [Remote Pairing protocol specification](https://jkcoxson.com/blog/rppairing-spec)
- [Apple's Pair Verify implementation](https://github.com/apple/HomeKitADK/blob/master/HAP/HAPPairingPairVerify.c)
- [RemoteXPC wire reference](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/remote/xpc_message.py)
- [RemoteXPC handshake reference](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/remote/remotexpc.py)
- [Service discovery reference](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/remote/remote_service_discovery.py)
- [Modern raw debugserver endpoint](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/developer/debugserver.py)
- [TCP specification, RFC 9293](https://www.rfc-editor.org/rfc/rfc9293.html)
- [IPv6 specification, RFC 8200](https://www.rfc-editor.org/rfc/rfc8200.html)
- [Executable-region preparation protocol](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)

The LocalDevVPN source was inspected to understand its public network behavior;
no third-party source files or libraries were copied into the app. Our code uses
the same simple address-exchange mechanism with independent bounded parsing and
tests. Documentation describes intended mechanisms, not successful device tests.

## Reproducing the new local tests

With DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer, the normal
tools/test_emulation.sh includes the sanitizer pairing tests. The independent
TLS test is separate because it starts a loopback-only server:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Istandalone/Pairing \
  -framework Foundation -framework Network -framework Security \
  authorization/Pairing/TunnelTLS.m tools/probe_system_psk.m -o build/probe_system_psk
python3 tools/test_pairing_transport.py
```

The session tests are also included in tools/test_emulation.sh. To exercise our
pairing TCP transport against its synthetic loopback peer:

```sh
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address authorization/Pairing/*.swift tests/PairingPeerFixture.swift \
  tests/test_pairing_connection.swift -o build/emulation/test_pairing_connection
build/emulation/test_pairing_connection
```

The protocol document was retrieved successfully via HTTPS and its rendered
template inspected; the browser text extractor's “Loading...” response omitted
the actual specification. Source: https://jkcoxson.com/blog/rppairing-spec.

CDTunnel wire tests are included in tools/test_emulation.sh. Its independent
loopback TLS test additionally compiles the shared system TLS adapter:

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Istandalone/Pairing \
  -c authorization/Pairing/TunnelTLS.m -o build/emulation/TunnelTLS.o
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/*.swift authorization/Transport/*.swift \
  build/emulation/TunnelTLS.o tools/probe_cd_tunnel.swift -o build/probe_cd_tunnel
python3 tools/test_cd_tunnel_transport.py
```

TCP unit tests and the independent packet peer are in tools/test_emulation.sh.
After compiling TunnelTLS.o as above, the combined encrypted TCP test is:

```sh
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/*.swift authorization/Transport/*.swift \
  build/emulation/TunnelTLS.o tools/probe_tcp_over_tunnel.swift \
  -o build/probe_tcp_over_tunnel
python3 tools/test_tcp_over_tunnel.py
```

RemoteXPC unit tests and the independent discovery peer are included in
`tools/test_emulation.sh`. The combined encrypted discovery test uses the shared
TLS object above and all original Swift transport sources:

```sh
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/*.swift authorization/Transport/*.swift \
  build/emulation/TunnelTLS.o tools/probe_rsd_over_tunnel.swift \
  -o build/probe_rsd_over_tunnel
python3 tools/test_rsd_over_tunnel.py
```

Managed stream/session unit tests are included in tools/test_emulation.sh.
The production connection lifecycle test uses a synthetic verified offer and
independent encrypted peer (never a real device pairing record):

```sh
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/*.swift authorization/Transport/*.swift \
  build/emulation/TunnelTLS.o tools/probe_managed_tunnel.swift \
  -o build/probe_managed_tunnel
python3 tools/test_managed_tunnel.py
```

Pairing storage ASan tests are in tools/test_emulation.sh. Its optional integration
test builds three isolated **simulator-only** probe identities, checks real
Keychain API behavior with synthetic keys, then removes its record and test apps:

```sh
python3 tools/test_pairing_storage_sim.py --build
```

This requires the documented simulator to be booted. It never installs anything
on the physical iPad. The StorageProbe target is a development test target, not
an additional app required by the product.

Debugger request and independent RSP peer tests are in tools/test_emulation.sh.
The encrypted debugger integration test uses only synthetic loopback traffic:

```sh
xcrun clang -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  -c authorization/DebugWire.c -o build/emulation/DebugWire.o
xcrun clang -Wall -Wextra -Werror -g -fsanitize=address,undefined \
  -c authorization/Control/ArenaControl.c -o build/emulation/ArenaControl.o
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/*.swift authorization/Transport/*.swift authorization/Debugger/*.swift \
  build/emulation/TunnelTLS.o build/emulation/DebugWire.o build/emulation/ArenaControl.o \
  tools/probe_debug_over_tunnel.swift -o build/probe_debug_over_tunnel
python3 tools/test_debug_over_tunnel.py
```

For the preparation-service integration, use the same compile command with
tools/probe_arena_service.swift / build/probe_arena_service, then run
`python3 tools/test_debug_over_tunnel.py --service`.

The optional native macOS debugserver test attaches only to its freshly spawned
own-code fixture, which is development signed locally. It never attaches to an
existing process or an iPad:

```sh
xcrun clang -Wall -Wextra -Werror tests/debug_arena_target.c \
  -o build/emulation/debug_arena_target
codesign --force --sign - --entitlements tests/debug_arena_target.entitlements \
  build/emulation/debug_arena_target
xcrun swiftc -module-cache-path build/swift-module-cache -warnings-as-errors \
  -g -sanitize=address -import-objc-header authorization/Transport/TransportBridge.h \
  authorization/Pairing/PairingWire.swift authorization/Debugger/DebugArenaRequest.swift \
  authorization/Debugger/DebugProtocolWire.swift authorization/Debugger/DebugArenaSession.swift \
  build/emulation/DebugWire.o tools/probe_native_debugserver.swift \
  -o build/probe_native_debugserver
python3 tools/test_native_debugserver.py
```


## September 20 physical integration update

The earlier physical-device status above is historical. See DEVICE_VALIDATION.md
for current evidence. Own trusted enrollment is in the shared protected Keychain;
our packet provider authenticates pairing, uses system PSK TLS over its own TCP
packet path, discovers the exact iPad, and verifies the actual RSP capability
response. iPadOS 27's debugproxy advertises UsesRemoteXPC=true despite answering
raw RSP; capability verification precedes any memory request. Background IPv6
control packets are filtered instead of poisoning the authenticated IP stream.

The full local transaction prepared and detached from our own 16 KiB zero arena,
then that memory successfully executed our return-42 fixture. No Mac debugger
participated. The first full game-size allocation returned uncertainty; guest
entry was blocked and mappings retained. A subsequent launch was blocked by the
locked device. Progress diagnostics are prepared for the next unlocked test.
Fully disconnected cold launch and reboot/DDI recovery are not yet
demonstrated; shader independence is implemented (the iPad compiles first, the
Mac translation is a fallback) and awaits the captured-shader diagnostic on the
device. Original guest CPU files remain unchanged and unsigned by
our app. The signed app includes only our runtime/adapters and bundled helper.
