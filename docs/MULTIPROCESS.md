# Several Windows processes in one iPad process

> **Lifecycle gate, 2026-10-13:** see [Full-screen process evidence](FULLSCREEN_PROCESSES.md).
> Finite background IPC passed for 29 minutes 38 seconds; continuous two-app Steam execution is unproven.

> Design and status for running more than one Windows process at a time
> under Tolkara's Wine. First targets: the Windows Steam client (`steam.exe`
> and its `steamwebhelper.exe` children), then games started from it. Each
> section says what is proven, where (Mac, simulator or iPad), and what is not.
>
> **Status, 2026-10-11: M1 reached.** Our original parent/child fixture
> (`probe-wine-process.exe`, 32-bit) starts itself as a child twice, by
> searched and by explicit path; each child runs in its own process slot
> with its own copy of Wine's 16 Unix-side libraries, its own WoW64 window
> and a 64 MiB share of the code pool, returns 73, and only its thread ends;
> the parent reads the exit codes and prints PASS. Passed in the iOS 27
> Simulator and on the iPad Pro M5 with Developer service (231 MB of
> prepared memory for three slots).

## Why

iPadOS gives an app one process: `fork`, `posix_spawn` and `exec` are refused,
and the only other processes an app has are system-launched extensions with
small memory limits. [WINDOWS.md](WINDOWS.md) (W4) therefore runs Wine as a
single process: `wineserver` is a thread, and `NtCreateUserProcess` returns
`STATUS_NOT_SUPPORTED`. That suits a game that is one program. It does not
suit the Windows Steam client: on the Mac, one signed-in session is six
Windows processes (`steam.exe`, which is 32-bit, plus the 64-bit
`steamwebhelper.exe` browser, GPU, network, storage and renderer processes),
and a game Steam starts is a seventh. Launchers such as the Rockstar Games
Launcher are built the same way.

## The approach: one copy of Wine's Unix side per Windows process

Wine already keeps everything that belongs to a Windows process in the Unix
process that runs it: the address-space bookkeeping and signal handlers in
`ntdll.so`, the window surfaces in `win32u.so`, the server connection and its
file descriptors. The Windows side (PE `ntdll.dll`, `kernelbase.dll`, ...) is
mapped by that Unix side and is per-process by construction. So instead of
teaching one Wine instance to host several Windows processes, Tolkara gives
each Windows process its **own copy of Wine's Unix-side libraries**, placed by
its own loader, all in one iOS process and all connected to the one
in-process `wineserver`:

```
  iPad process (Tolkara)
  ├── wineserver thread (bin/wineserver.so, one copy)
  ├── instance 0: wine loader + ntdll.so, win32u.so, winemac.so, …  → steam.exe (WoW64 window W0)
  ├── instance 1: its own ntdll.so, win32u.so, …                    → steamwebhelper.exe
  ├── instance 2: …                                                  → steamwebhelper.exe --type=gpu-process
  └── …
```

Tolkara's loader can do this because it already places Wine's Unix libraries
itself (profile key `libraries`, W3) and binds every import itself: a second
copy is the same files placed again at another address, with its own data,
and with the few process-wide host facilities it touches bound to
per-instance shims.

### What is per instance, and how

| Host facility | Today | Per instance |
| --- | --- | --- |
| Library code and data | one placed copy, keyed by path (`GuestLink.c`) | a placed copy per instance slot; `dlopen`/`dlsym` from a library answer from its own instance |
| Environment (`getenv`, `environ`) | the process environment, set by the launcher | a private environment per instance: `WINEJITPOOL` (its slice of the code pool), `WINESERVERSOCKET`, `WINEPRELOADRESERVE`, `WINEDEBUG` |
| Signal handlers (`sigaction`) | Wine's handlers installed process-wide | one Tolkara dispatcher; each copy's handlers recorded per instance; a fault or a server signal (SIGUSR1, SIGQUIT) goes to the copy that owns the thread |
| Thread ownership | n/a | `pthread_create` from a copy tags the new thread with its instance |
| Process exit (`exit`, `_exit`, `abort`) | ends the iOS process | ends the instance: its threads stop and its server connection closes, so `wineserver` sees the Windows process die; instance 0's exit still ends the app |
| Executable memory | one code pool, `WINEJITPOOL=${CodePool}` | the code pool divided into per-instance slices |
| Address-space reservations | `ntdll` reserves at startup | each copy reserves its own areas; the 32-bit window of each WoW64 process is chosen inside them |
| Working directory | process-wide `chdir` | all copies use the prefix's directory; Windows working directories are already per thread in the server |

Process creation keeps Wine's own protocol. `NtCreateUserProcess` in the
parent instance does what it does today (a socket pair, the `new_process` and
`new_thread` requests); where it would fork and exec the loader it instead
asks Tolkara for a free instance slot and hands it the child's command line,
the socket and the environment. Tolkara starts the slot's `__wine_main` on a
new thread. The child connects through the inherited socket as any Wine child
does.

### What the server needs

`wineserver` identifies clients by their socket, not by Unix pid, and thread
ids on Darwin are Mach thread ports, which stay unique across instances. Two
places act on the whole host process and must not when the client is
in-process: the delayed SIGKILL of a dying process (already guarded in the
working tree), and `write_process_memory`'s `task_suspend`, which would stop
the server's own task.

### Known hard limits

- **Executable memory.** The Developer service prepares at most 512 MiB per
  launch, once. Every instance's FEX code buffers and native PE modules must
  fit their slice. A single game already used 496 MiB (MegaBonk); Steam's
  browser runs a JavaScript engine whose generated x86 code FEX translates
  again. This is the first number to measure.
  Measured on the Mac with the iPad's aliased pool (`WINEJITPOOL=dual:512`),
  2026-10-12, Windows Steam 1788652215: each 64-bit process maps 66 to 129
  MiB of Wine's native ARM64EC modules into its pool, plus FEX's code
  buffers (16 to 32 MiB for `steam.exe`, far more for Chromium processes
  whose V8 keeps generating code). Native module code cannot be shared
  between processes by mapping it twice: on the iPad Pro M5 (iPadOS 27,
  Developer service) a prepared arena page mapped a second time with
  `vm_remap` outside the arena ends the process when executed there
  (`--jit-probe`, remap stage), so execute permission belongs to the
  prepared mapping, not to the pages.
- **Memory.** Each instance carries its own copy of the Unix libraries (a few
  MB) and its Windows processes' own memory.
- **Windows of several processes.** `winemac.drv` registers Objective-C classes
  by name and drives the one `NSApp`. A second copy's classes are not entered
  in the class table and its controller would replace the first's. Console
  programs do not load the driver; windows from more than one instance are a
  later milestone (M3).

## Windows Steam in 512 MiB

Measured on the Mac with the iPad's aliased pool (`WINEJITPOOL=dual:512`)
and Steam client 1788652215, 2026-10-12. Steam now installs its 64-bit
client here (Wine reports that x64 programs can run on an ARM64 host, as
Windows 11 on ARM does), so every Steam process is x86-64 under FEX.

| Layout | Processes | Code pool at their peak |
| --- | --- | --- |
| Steam's default | `steam.exe`, the browser and its GPU, network, storage and renderer processes, probes | over 700 MiB |
| One renderer, GPU and network in the browser | 6 | about 600 MiB |
| One-process browser, V8 interpreted, FEX buffers at their final size | 2 | `steam.exe` 120 MiB, browser 216 MiB |

What gets it there, all profile data (no change to Steam):

- Chromium switches for `steamwebhelper.exe` (`WINEAPPENDARGS`, a Wine
  setting that appends arguments when a named executable is started):
  `--single-process --in-process-gpu --js-flags=--jitless`. V8's generated
  code is what kept FEX translating; interpreted, its code is translated
  once. Steam's own `-cef-disable-site-isolation` and
  `-cef-disable-gpu(-compositing)` options.
- Steam's probes that only fail here are not started (`WINENOSPAWN`):
  `steamsysinfo`, `gldriverquery(64)`, `vulkandriverquery(64)` and the crash
  reporter.
- FEX code buffers that start at their final size
  (`FEX_INITIALCODEBUFFERSIZE`, new in Tolkara's FEX branch): growing 16 → 32
  → 64 → 128 MiB keeps the smaller buffers alive while threads still use
  them. 32 MiB for `steam.exe`, 128 MiB for the browser. A child inherits its
  Windows environment from its parent, so the browser's values are set when
  `steam.exe` starts it (`WINEAPPENDENV`).
- Code pool shares by command line (`TOLKARA_PROCESS_POOL`): 150 MiB for
  `steam.exe`, 260 MiB for the browser, in a 470 MiB pool; the arena with
  three slots is 500 MiB.

### Address space: the 64-bit browser does not fit

On the iPad Pro M5 (iPadOS 27, extended virtual addressing) an app can map
only 448 to 512 GiB, 64 GiB in all ([CYBERPUNK_VM.md](CYBERPUNK_VM.md)).
Chromium 126's allocator reserves two 16 GiB pools, each on a 16 GiB
boundary. On Windows it does that by reserving about 32 GiB, releasing it and
reserving the aligned 16 GiB inside. Measured on the iPad, 2026-10-12:

- With nothing set aside, the browser's first 32 GiB reservation fails.
- `TOLKARA_LARGE_RESERVE_MB` sets one block aside at startup, at the top of
  the address space on a 16 GiB boundary. `WINELARGERESERVE` hands it to one
  process's Wine, which places reservations of 1 GiB or more there and keeps
  it mapped. Wine must also accept a fixed-address reservation in that block:
  otherwise the release-and-reserve-aligned step fails and Chromium retries it
  forever, which looked like a hang.
- With 48 GiB from 448 GiB both pools fit and `chrome_elf.dll` initializes.
  `libcef.dll` then asks for another 32 GiB over-reservation; with about
  4 GiB of the 64 GiB left, it fails.

So Steam's 64-bit browser cannot run in one iPad process. Its 32-bit browser
(`bin/cef/cef.win7`, used by Steam's 32-bit client) lives in a 4 GiB window.
`WINENOX64` makes Wine report that x64 programs cannot run, so Steam keeps its
32-bit client.

### The 32-bit client (status 2026-10-12)

On the Mac without a code pool, the 32-bit client reaches its library and
friends list. On the iPad, `steam.exe` runs in slot 0, its first window
appears, and the browser starts in slot 1 but stops after its first page; Steam
ends it as unresponsive. Fixed on the way, each found on the device or with an
iPad-like Mac run:

- Wine placed 64-bit memory (FEX's own allocator) in a process's 32-bit
  window when the only reserved area was the window, as in a slot: the window
  filled in 256 MiB pieces until the browser's allocations failed.
- FEX's allocator (rpmalloc) reserved address space in 256 MiB spans per
  thread, 43 GiB across Steam's threads; its Windows build now uses 64 MiB.
- FEX's 32-bit exception handler dereferenced the thread state of threads that
  never ran x86 code (Wine's own), and one thread ending another cleared its
  own CPU area; both ended in endless nested exceptions.
- A debugger's break-in thread started at the debugger's own address of
  `DbgUiRemoteBreakin`; modules in a code pool sit at different addresses in
  each process.
- `nsi.dll` in a 32-bit process reaches `nsiproxy`'s Unix library through the
  32-bit `nsiproxy.sys` in `syswow64\drivers` (new WoW64 thunks), so Steam's
  check of which process owns its UI connection works without a driver
  process.
- The library kept a profile's old working directory when a newer profile
  moved the application (all runtime profiles share one executable).

Code pool use, measured on the Mac with the iPad's pool: `steam.exe` 71 MiB,
the 32-bit browser 135 MiB (one 128 MiB FEX buffer); while FEX replaces a full
buffer the browser briefly needs two.

Steam also checks which process owns each connection to its local UI
server (`GetExtendedTcpTable`). Wine answers through the `nsiproxy.sys`
driver, which runs in `winedevice.exe`; with no driver process, `nsi.dll`
now calls `nsiproxy`'s Unix library in-process. The owners come from the
server's own socket table, so they stay right when all processes share one
Unix pid.

## Two apps: current gate and integration audit (2026-10-14)

The alternative remains experimental, not scrapped. `GuestRemote.c` already
hands a Wine child command line, environment and server descriptor to another
app over the App Group socket. `TOLKARA_REMOTE_PROCESS` selects the child;
`TOLKARA_SLOT_HOST` waits for it in the second app. These hooks do not themselves
grant background execution. The first handed-over process uses the second
app's main slot; later children use its additional slots.

The physical probe has demonstrated descriptor transfer and shared file-backed
mappings. Ordinary background execution failed after transition. A finite
continued-processing task completed 120 replies; its six-minute endpoint was
programmed completion, not a measured system time limit. The 600-reply extension completed normally, with 29 minutes 38 seconds of
uninterrupted active-host/background-peer replies in its final host run; see
FULLSCREEN_PROCESSES.md for run identifiers.
Neither test proves a game-session lifetime or runtime operation under load.

Do not deploy the ignored `build/mptest/profile-steam-host.json` or
`profile-steam-browser.json` as a current validated configuration. Both retain
`WINEPHANTOMRANGE` / `WINEPHANTOMPOOLS` from the earlier reservation experiment.
Those settings do not establish usable backing for accessed memory. A second
app provides a separate address space, but does not expand the addressable
range of one browser process. Any revived two-app trial must use actual native
or explicitly authorized software-backed allocations and measure their cost.

Handover failure handling now suppresses SIGPIPE per connection and bounds
idle handover send/receive waits to ten seconds. Signal connections suppress
SIGPIPE but retain their persistent receive behavior. The Mac ASan/UBSan
fixture `tests/test_guest_remote.c` verifies a closed socket cannot terminate
the host, a silent receiver returns ETIMEDOUT, and failure retains the caller's
server descriptor. The fixture also executes the real sender and receiver in
separate Mac processes: the receiver closes its inherited descriptor copies
before accepting SCM_RIGHTS, obtains the command line intact, and exchanges
a bidirectional nonce over the transferred server socket. Successful handover
closes the sender's original descriptor. This is an idle-I/O bound, not a transaction-wide deadline.
A lost acknowledgement remains ambiguous: the receiver might already have
started the child, so callers must not blindly retry. Physical Wine handover
validation remains pending; this change was not deployed during the live
600-reply lifecycle test.

Before actual Steam trials, validate an owned Wine parent/child across the
handover, including child exit, communication after foreground changes, and
expiration handling. A supported finite download/install job may use continued
processing with real progress; a longer IPC test does not justify an indefinite
service or automatic task resubmission. Preserve the original binaries and
prepare/detach authorization separately before guest entry in either app.

### Finite runtime handover workload

`testguest/windows/remote_handover_probe.c` is an owned Windows fixture for the
next physical two-app test. The parent starts `remote_child.exe` with an
inherited pipe; the child computes a fixed 64 MiB FNV workload, writes the
checksum, and exits 73. The parent checks the independently calculated checksum
0x4bfc9dc5 and exit status within 30 seconds. An optional unique gate file lets
runtime preparation finish before spawning; it times out after ten minutes
and grants no background execution.

Both names use the same executable built from this source. On 2026-10-14 it
built with -Wall -Wextra -Werror and passed under the Mac Wine runtime in the
isolated control prefix (log `/private/tmp/codex-remote-handover-wine.log`). This
validates the workload and Windows pipe/exit behavior, not Tolkara's remote
handover or the iPad lifecycle. Ignored profiles `profile-handover-parent.json`
and `profile-handover-peer.json` in build/mptest select the remote child and
slot host without phantom reservations or software memory. They are preparation
artifacts, not validated deployment profiles. The Swift ProcessProbe continued-
processing grant remains confined to that probe's process. The runtime now
has an opt-in `--finite-handover-probe` path for the slot host, requiring the
owned `--app=mp-process-probe` profile and MPTest runtime path in the foreground.
It begins a standard short UIKit background task after memory preparation,
just before waiting for the handover. It never renews; expiration ends this
owned diagnostic with exit 124. This is a bounded integration experiment, not
a continued-processing implementation for Steam. Both existing runtime bundle
IDs built successfully with this path; physical execution remains pending.

The parent must prepare and reach its unique gate first. The receiver then
prepares; when its finite allowance starts, bring the parent foreground and
release the gate promptly. Direct App Group staging returned a file-node error,
so the parent profile uses the existing non-overwriting TOLKARA_GROUP_SEED path.
The isolated package at build/handover-stage/MPTest omits prefix symlinks to
personal folders and drive roots. It carries only the test prefix, packaged
Wine, and the owned parent/child executable.

### First physical Wine handover attempt

On 2026-10-14 both existing Tolkara installations received the isolated test
package. Initial discovery failed because the saved MPTest runtime record
retained profile ID `mp-process-probe`; the diagnostic now preserves that ID.
The parent seeded 1999 files into the shared App Group with zero failures,
prepared/detached, and reached its unique gate. The receiver then prepared/
detached, started its finite background allowance and listened. Activating the
parent reused its original process, after which the gate was released.

The runtime reported successful handover to the receiver, which entered Wine's
main for the child. However, CreateProcess failed with error 126, and the
receiver reported c0000135 for a child path resolved through Z: into the
parent app's private Documents container. This is a failed initialization,
not a successful two-app Wine workload. The fixture now accepts an explicit
child path, and the profile uses C:\test\remote_child.exe in the shared Wine
prefix. The corrected parent build succeeds; physical retest is pending.
The raw attempt logs are `/private/tmp/codex-handover-parent-native.log` and
`/private/tmp/codex-handover-peer-native.log` (contain local container paths;
not committed). The trigger was regenerated for the next attempt.


### Physical Wine handover passed (2026-10-14)

The corrected shared-prefix child path passed on the physical iPad under
ordinary devicectl launch. Fresh parent run
`handover-go-c5b74457cab6477894eb0fa5b202b62d` retained PID 2045 when activated;
receiver run `handover-peer-0037a7afbbde4c93ab7ac45017ff8dd1` used PID 2050.
Both prepared and detached before entry. The receiver started its one finite
UIKit allowance and accepted C:\test\remote_child.exe. The parent reported
`PASS: child computed 64 MiB, inherited pipe returned checksum, exit 73`.
This verifies actual Wine child initialization, inherited-pipe communication
and exit reporting across two iPad app processes. It is not a Steam result,
a sustained execution test, or a performance benchmark. Unlike the earlier
Swift IPC test, this test uses a short UIKit background task, not continued
processing. Expiration behavior under this workload remains untested.

A discarded intermediate attempt activated the parent using a stale receiver
ready log and failed with connection refused. The coordinator now requires the
fresh receiver run tag before readiness. New runs terminate their own previous
instance; foreground reactivation must preserve the parent's PID. Those invalid
attempts are not evidence of a lifecycle failure. Raw successful logs remain in
/private/tmp/codex-handover-{parent,peer}-native.log; copies should be retained
before subsequent tests replace them.


### Relative child paths with shared working directory

A second physical test passed with `TOLKARA_CHDIR=${Group}/MPTest/prefix/drive_c/test`
and an ordinary relative `remote_child.exe` launch. Parent run
`handover-go-74d1a7bbc0914d70b19f6a0a6e5565de` retained PID 2066 on activation;
receiver run `handover-peer-9b67360fd5f841648611c81331318c90` used PID 2070.
The parent again verified the 64 MiB checksum and exit 73. This confirms the
existing shared working-directory mechanism avoids private-container child
resolution without rewriting guest binaries or their process arguments.
The initial shared-directory attempt used a stale fixture already present in
the non-overwriting shared seed and lacked its gate. That attempt is invalid
as a handover test. A new owned filename `handover_parent_v2.exe` was seeded
(1 file copied, zero failures), and its unique gate was observed before the
successful receiver launch. Future fixture versions must not assume seeding
updates existing files. Evidence copies:
`/private/tmp/codex-handover-sharedcwd-{parent,peer}.log`.

Ignored, schema-validated `build/mptest/profile-steam-twoapp-client.json` and
`profile-steam-twoapp-browser.json` now describe shared-prefix client/browser
roles with 256/640 MiB code pools. The browser uses the existing software-backed
pool experiment, not the invalid phantom reservations from older profiles.
These candidates are not deployed and do not solve the sustained-lifecycle
requirement. In particular, the owned short handover allowance must not be
mistaken for a general Steam background service. Steam UI, download, game
launch, and performance remain unverified.

## Milestones

- **M0 — the design** (this document).
- **M1 — a parent and a child console process** in the iOS Simulator: our
  original fixture starts itself as a child through `CreateProcess` (searched
  and explicit path), the child sees the inherited environment, the parent
  gets its exit code. Then the same on the iPad.
- **M2 — instance reuse.** A finished instance's slot is reset (its data
  re-placed from the original files, fixups applied again) so that programs
  that start many short-lived helpers do not run out of slots.
- **M3 — windows from more than one instance.**
- **M4 — the Steam client** signs in and shows its library on the iPad.
- **M5 — a game started from Steam.**


### Prepared code-pool retirement (2026-10-15)

A slot that entered guest execution keeps its prepared code-pool slice until
Tolkara exits. Builtin data/header pages can lose execute permission permanently,
so another process cannot safely treat the used slice as fresh JIT memory.
Wine's per-process no-reuse tracking cannot protect a slice returned through the
host allocator. Untouched allocations from a failed pre-entry spawn can still
be returned. The process-exit fixture checks disjoint next-process allocation
for both host-stack and guest-stack exits and reusable pre-entry rollback.

### Exit surfaces and fresh sequential instances (2026-10-17)

The optional Wine window bridge captures the calling process slot before dispatch
to Cocoa's main thread. `AKSetWindowProcess` tags the host window explicitly.
On `gp_slot_exit`, the AppKit exit callback hides that slot's windows and restores
the frontmost surviving window, without calling exited guest delegates or
destructors. It retains retired window objects for the host session.

For profiles with additional prepared slots/pools, `TOLKARA_PROCESS_RANGE_POOL`
selects a fresh disjoint reservation from a bounded subset of `${LargeReserve}`.
This host allocation policy is cleared for child processes before explicit
process rules are applied; only matching rules opt a child into fresh allocation.
The requested `WINELARGERESERVE` supplies the per-instance size; both it and
`WINESMALLRANGE` receive the selected range before entry. Exhaustion fails closed.
This allows sequential instances without reusing code pages or an exiting
thread's stack. It remains a finite session budget, not instance recycling.
Explicit arenas can be up to2GiB including placed libraries; the normal External
JIT request remains capped at1GiB. Physical sequential-game validation is pending.

### Anonymous software fallback retry (2026-10-17)

A constrained browser layout exposed an infinite Wine `map_view` retry: native
`mmap` exhausted its address space, Tolkara returned a software-backed mapping,
and Wine unmapped that above-limit address and retried the identical request.
`tools/wine-patches/anonymous-software-fallback-no-retry.patch` makes this
ordinary anonymous path free the software mapping and return `STATUS_NO_MEMORY`.
It preserves the existing native-limit policy; explicit software pools are
unchanged. It depends on the existing software-pool integration.

`python3 tests/test_wine_anonymous_fallback.py` compiles the actual loop with
synthetic host results under ASan/UBSan. It covers successful native allocation,
one-attempt software rejection, high-native retry and host error propagation.
The unpatched loop exceeds the fixture's retry bound. The rebuilt library was
deployed and normal authenticated Steam Library navigation verified on iPad.
This fixes the retry hang, not the unresolved repeated-game-launch lifetime
problem. The failed smaller-browser profiles were withdrawn.
