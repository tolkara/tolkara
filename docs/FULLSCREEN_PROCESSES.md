# Full-screen two-app execution: physical iPad evidence

Tested 2026-10-13 and 2026-10-14 on iPad Pro M5, iPadOS 27.0.1.
The lifecycle measurements below use our own Swift probes, not Steam; no
guest debugger or XCTest session was running. A separate finite Wine child
handover also passed; see [physical Wine evidence](MULTIPROCESS.md#physical-wine-handover-passed-2026-10-14).
Sustained Steam execution remains unverified.
Both apps were launched with devicectl. Device Hub showed the host full screen.

## Ordinary apps

The peer entered background at 20:03:36 UTC. The first ping succeeded during
transition; subsequent pings timed out beginning at 20:03:40. A Unix socket
connection is not proof of execution: the kernel can queue it while the server
is suspended. Only a matching nonce reply counts.

The peer originally wrote stale replies without SO_NOSIGPIPE. On reactivation,
closed clients could terminate the probe with SIGPIPE. The probe now suppresses
that signal per accepted socket. This fixes a test-fixture defect, not suspension.

## Continued-processing task

Peer/ContinuedProbe.swift adds a visible button that submits one finite
BGContinuedProcessingTask, with progress counting 120 successfully written
nonce replies. It handles expiration, reports completion, and does not silently
resubmit. The peer declares processing background mode and its task identifier.

A fresh host run EE4BAE83 began at 20:11:01 UTC. There were four replies before
this host restart and one during transition. Host pings 2 through 116 were
115 matching replies while the peer reported background and the host active:
20:11:04 through 20:17:04 UTC, six minutes, with no intervening failures.
The peer completed 120/120 at 20:17:04. Host ping 117 then timed out at
20:17:09; later requests failed, with connection refused by 20:17:52 (12 failed
requests after completion). These logs alone do not distinguish suspension
from later process termination. This demonstrates the lifetime
of the execution allowance rather than an indefinitely runnable helper.

Local raw evidence: /private/tmp/codex-process-probe.log and
/private/tmp/codex-continued-probe.log (temporary files, not committed).

## Extended finite test (2026-10-14, completed)

The six-minute endpoint above was the probe's own 120-reply completion,
not an observed operating-system time limit. The peer now offers explicit
120- and 600-reply buttons. The host observes 800 requests (approximately
40 minutes), allowing observation after the longer task completes. Neither
probe resubmits a completed or expired background task.

Both targets built successfully. The 600-reply task was started through Device
Hub, followed by ordinary devicectl host launch. Peer PID 1944 replied in the
background. After extending and reinstalling the host, run 0DE4D367 started
at 08:43:25 UTC, with peer progress already 33/600; the host became active
at +0.3 seconds. The task subsequently completed normally (results below). Count earlier replies
separately from this host run; do not claim a full 30-minute continuous run
from its start. This remains a light IPC lifecycle test, not a Steam workload
or proof of indefinite service.

At 08:49:33 UTC, this same host run had 117 qualifying replies spanning
364.7 uninterrupted seconds, with no failed requests or continuity breaks;
the peer task had reached 150/600. This exceeds the earlier six-minute
observation without reaching the task endpoint. The completed result is recorded below.
`tools/analyze_process_probe.py` selects the latest host run and splits
continuity on failed replies, foreground-state changes, PID changes, missing
sequence numbers, or observation gaps over ten seconds. It does not assert
that a saved log is fresh or that a Steam workload works.

Raw observations: `/private/tmp/codex-continued600-peer.log` and
`/private/tmp/codex-continued600-host.log`; observation helper:
`/private/tmp/codex-continued600-status.py`. Build logs end in BUILD SUCCEEDED.

### Completed result

The peer reported `completed 600/600` at 09:13:06 UTC, with no expiration
or cancellation event in this task. Host run 0DE4D367 received 567 replies
while the host was active and peer PID 1944 was backgrounded: 1778.3 seconds
(29 minutes 38.3 seconds) of uninterrupted observed communication. Its first
reply during the inactive transition is excluded. The earlier 32 peer replies
precede this host run and are not added to that continuity interval.

After task completion, host requests timed out, then connection attempts were
refused by 09:13:35. Thus the test's endpoint was again explicit successful
completion, not a demonstrated operating-system duration limit. These logs do
not distinguish suspension from subsequent termination. The test was launched
normally through devicectl, with the task initiated through the visible button
in Device Hub; no XCTest or debugger session was used to hold either app alive.

This passes the extended *light IPC* experiment. It leaves the full Steam
lifecycle gate open: realistic runtime memory/CPU load, a supported task tied
to actual finite work, and successful Steam/browser/game handover remain to be
verified. Do not replace real progress with probe pings in a production runtime.

## Decision boundary

Finite background execution is proven for light IPC on this device. Continuous
Steam service, realistic memory/CPU/GPU load, installation, and game execution
are not proven. Do not treat this test as the two-app architecture passing.
Do not manufacture progress, repeatedly submit completed tasks, or play silent
audio to keep a helper alive. A real finite installation might fit this API,
but generic browsing/game-service lifetime still needs a viable design.

Apple documents user-initiated finite jobs, progress reporting, cancellation,
and possible expiration:
https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados
https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask

Background URLSession downloads transfer work to a system process; they do
not keep arbitrary Wine/Steam code running:
https://developer.apple.com/documentation/foundation/downloading-files-in-the-background

## Single-app follow-up: restricted-address-space control

On 2026-10-13, an isolated APFS clone of the Mac Steam prefix was used for
bounded tests, without launching a game or changing the source prefix. Steam
started its browser with the current allocator switches, but neither a roughly
2 GiB nor a roughly 4 GiB ordinary-memory region reached browser rendering
under the 448–512 GiB address-space restriction. The 4 GiB control wrote no
new CEF or webhelper log bytes. Existing logs from an earlier unconstrained
run must not be counted as evidence for these runs.

Wine module diagnostics reported psapi.dll and shell32.dll load failures with
STATUS_ACCESS_VIOLATION, followed by a delayed-load exception. A small program
we own reproduced the DLL load failures after reserving the three large regions
at 0x7c00000000 (16 GiB), 0x7800000000 (16 GiB), and 0x73ffff0000
(16 GiB + 64 KiB). Without those reservations the libraries loaded successfully.
Adding stack-location logging changed the outcome of the one- and two-region
variants; the three-region variant still failed. This is a reproducible loader/
layout investigation, not proof that Steam exceeds the smaller region. The
cause and the sensitivity to probe layout remain unresolved.

The Mac control must set early Wine configuration in the Unix environment
before Wine starts. WINEAPPENDENV only modifies the Windows child environment
and did not apply these early address-space settings in the first attempt.
Do not copy the entire device profile environment into a Mac control: it
contains unresolved app-group paths and host-only process settings. A useful
control helper should whitelist portable settings, verify the startup limit
markers, and capture log offsets before each run.

Local temporary evidence: /private/tmp/codex-steam-fit-early.log,
/private/tmp/codex-steam-fit-4g.log, /private/tmp/codex-steam-fit-loader.log,
and /private/tmp/codex-loader-probe-3.log. The synthetic reproducer is
/private/tmp/codex-loader-probe.c. These are diagnostic runs, not physical-iPad
Steam compatibility results. No successful Steam download or game launch has
been established.

### Mac control correction

Further tracing located native Wine malloc allocations inside the original
448–512 GiB test window (for example 0x79cd034000). The experimental
WINELARGERESERVE path assumes ownership of its whole range even when its
attempt to reserve that range on the Mac fails. Subsequent fixed pool mappings
can overwrite native allocator memory. Therefore the original Mac loader
failures are not evidence of an iPad address-capacity limit. Moving the same
64 GiB layout to 0x70000000000–0x71000000000 made the three-pool loader probe
pass without changing either DLL.

The shifted test exposed a second control defect: fixed allocations below
WINEADDRESSLIMIT's lower boundary were accepted. A 16 GiB browser reservation
at 0x62400000000 escaped the intended window, invalidating that preliminary
Steam result too. The lower-bound fix is retained as
`tools/wine-patches/restricted-address-lower-bound.patch`, against the current
experimental Wine fork; it is already applied to the local Wine source/build.
This patch is not automatically applied to unrelated upstream Wine trees.

`testguest/windows/reserved_loader_probe.c` checks the boundary and DLL loading
with three pools in the shifted window. Compiled with -Wall -Wextra -Werror,
the original runtime failed both boundary assertions; the corrected runtime
passed both and loaded psapi.dll and shell32.dll successfully. Temporary
section diagnostics were removed. This validates the Mac test boundary only;
it does not establish single-app Steam feasibility or device compatibility.

The regression also spawns a child. After the initial lower-bound fix, the
parent passed but the child still failed: WINEPRELOADRESERVE lowered the bound
again at startup. The retained patch now preserves a valid explicit test
window against that preload hint. Both parent and child pass all boundary and
DLL-load checks. Intermediate Steam runs that still allowed child escape are
not valid capacity measurements.

With both bounds preserved, a 120-second 4 GiB control reached CEF startup
but not ReadyToRender (`codex-steam-fit-window4.log`). A subsequent 120-second
control added WINEJITPOOL=dual:512 and WINEMAINSTACKSIZE=8 to match the device's
separate executable arena and main-stack requirement more closely. It also
failed before rendering (`codex-steam-fit-dual4.log`). The runtime reported
3980 MiB of views in a 4093 MiB small reservation, with 181 views in the
16–64 MiB bucket totaling 2896 MiB. A 16 MiB aligned data allocation failed;
Steam retried its browser. No game was launched and the isolated server was
stopped after each bounded run.

The FEX fork already reduces rpmalloc spans from 256 MiB to 16 MiB, but these
are still reserved per thread heap. This is a concrete overhead candidate,
not yet proven to account for every observed region. Investigate its allocation
policy before declaring the single-app design impossible. The upper allocator
pools remain 48 GiB plus a guard, leaving little room for ordinary allocations
once both V8 reservations are needed. Smaller data-region feasibility and
combined Steam/browser execution are still unproven.

The final lower-bound patch gates new lower-bound enforcement on a valid
explicit WINEADDRESSLIMIT, preserving ordinary Wine behavior. Its parent/child
regression passes after that scoping change. Temporary diagnostics are absent
from the final local source; the prior runtime library remains backed up at
/private/tmp/codex-ntdll-before-section-diag.so.

## Compact FEX allocator control

The 4 MiB span experiment lowers pooled large allocations to 2 MiB and routes
larger requests through rpmalloc's huge path. A bounded version of upstream
allocator tests passes ASan/UBSan for both the original 16 MiB configuration
and the compact configuration. Tests found two compact-policy issues: retaining
an excessively large allocation on shrink, and a full one-block page entering
the empty-page path without first leaving the full list. Both are corrected.
The test harness also had a thread-argument lifetime bug, reproduced in both
configurations; the bounded test patch preserves arguments until all joins.
Patches and reproduction notes are in `tools/fex-patches/`.

The 120-second compact-span Steam control still did not reach ReadyToRender.
A subsequent 60-second diagnostic run reported 3899 MiB of views in the
4093 MiB ordinary region and a failed 4 MiB aligned allocation. Smaller spans
alone do not establish feasibility. FEX also reserves MAX_L1_SIZE per thread
regardless of the initial dynamic L1 size: 1M entries mean another 16 MiB per
thread, even with L2 disabled. A separate 64K-entry/1 MiB cap is under test.
These are Mac capacity controls, not physical iPad success.

The combined compact-span / 1 MiB L1-cache control also failed to render in
120 seconds (`codex-steam-fit-compact-l1-4.log`). It progressed to additional
512 MiB and roughly 1 GiB reservation attempts, which failed. The first
allocation diagnostic reported 3669 MiB of views in the 4093 MiB ordinary
region; a browser retry later reported 3905 MiB and failed a 4 MiB span.
This does not prove the requested combined execution fits. The temporary
failure diagnostic threshold was lowered to 4 MiB for these controls; its
original 16 MiB threshold is restored after the experiment.

### Smaller pages and congruent reservation handling

The compact configuration now uses 1 MiB spans, 512 KiB medium pages, 1 MiB
large pages, and a 512 KiB largest pooled block. The bounded ASan/UBSan suite
and focused one-block transition test pass. The threaded L1 collision test
also passes with this allocator. This is still an experimental configuration.
Intermediate 4 MiB-span/512 KiB-medium-page control used 2864 MiB at its first
large reservation failure. The 1 MiB-span control used 2575 MiB but also failed
to render in 120 seconds. Reducing total use alone did not solve placement.

Wine's WINERELOCATEHINTS path skipped the entire ordinary region even when
free space remained there. `testguest/windows/congruent_hint_probe.c` reserves
all other regions and requests a 512 MiB congruent hint: it failed before the
fix and passes afterwards. The second reservation also preserves data in the
first. `tools/wine-patches/congruent-small-region.patch` uses Wine's existing
free-area allocator for candidates wholly inside the ordinary region; it
never blindly fixed-maps over that region. It applies after the earlier
restricted-address-lower-bound patch in this local Wine fork.
Parent and child boundary checks, DLL loads, and the threaded L1 collision
probe pass against the combined Wine/FEX changes. The combined 120-second Steam control (`codex-steam-fit-congruent4.log`)
still did not reach ReadyToRender. Its first failure now included a 512 MiB
placeholder reservation (type 0x42000), with 3156 MiB of views in the
4093 MiB ordinary region. The relocation fix is independently verified but
does not complete browser startup. Both early window markers were confirmed;
only new log bytes were counted, and the isolated server was stopped.

### Scratch-buffer retention

Temporary read-only allocation diagnostics measured the largest usable gap at
the exact 512 MiB placeholder failures: 436 MiB and 410 MiB in a 30-second
control (`codex-steam-fit-placeholder4.log`). Total free space alone was
misleading. The temporary gap instrumentation has been removed.

An optional hint-packing experiment preserved the trailing alignment bits of
power-of-two hints instead of their entire offset modulo the allocation size.
It passed an owned alignment/non-overwrite fixture but failed the 60-second
Steam control. Guarded pools were excluded. This is not an adopted fix.

FEX's shared translation scratch pools retain disowned buffers for five
seconds. `tools/fex-patches/immediate-scratch-reuse.patch` instead returns them
to the existing unclaimed list at the existing safe-release boundary on
bounded Darwin hosts. The owned native fixture with real 5000 ms / 500-use
parameters observed 32 buffers with the original policy and one with the new
policy for 32 sequential clients. Eight concurrent owners pass ASan/UBSan;
the translated x86-64 threaded collision fixture also passes. Reuse may cost
additional mutex traffic, so performance remains to be measured.

With immediate reuse, Steam reached three roughly 512 MiB regions before
failing another placeholder reservation. The first report showed 3311 MiB
used: the 16-64 MiB bucket fell to 235 MiB while the 64 MiB-1 GiB bucket grew
to 1973 MiB. This represents later allocations, not a direct identical-state
memory comparison. The 120-second run still did not reach ReadyToRender
(`codex-steam-fit-release4.log`). The isolated server was stopped.

### Combined packing and bounded decoder controls

Immediate scratch reuse plus the opt-in hint-packing experiment reached four approximately 512 MiB data regions, but failed a 16 MiB ordinary allocation with 3995 MiB of 4093 MiB occupied (`codex-steam-fit-pack-release4.log`, 60 seconds). The saved `tools/wine-patches/experimental-packed-hints.patch` remains an experiment, disabled unless WINEPACKHINTS is set.

FEX also reserved decoder space for 65536 instructions even when its configured block limit was 5000. The bounded-decoder patch sizes this scratch buffer to the configured limit and explicitly checks capacity. An owned long-block/eight-thread fixture passes with a limit of 17 instructions. The 60-second Steam control still failed a 0x501000-byte allocation requiring 1 MiB alignment, after the JIT report reached 294 MiB (`codex-steam-fit-decoder4.log`).

A follow-up with FEX_MAXINST=1000 and FEX_MULTIBLOCK=0 reached a JIT report of 358 MiB, then failed the same-size allocation (`codex-steam-fit-smallblocks4.log`, 60 seconds). Both controls confirmed the early 64 GiB window and 4 GiB ordinary-region markers, checked only newly appended browser logs, did not reach ReadyToRender, and stopped the isolated Wine server. These are Mac capacity controls; Steam startup, downloads, and game launch on the iPad remain unverified.

The repeated smaller-block control with allocation metadata enabled reached a different first failure: 16 MiB at 3974 MiB occupied of 4093 MiB (`codex-steam-fit-smalloom-filtered4.log`). The largest ordinary-region views included four approximately 512 MiB reservations, plus 226 MiB and 211 MiB views. The JIT report had reached 390 MiB. Roughly 119 MiB total remaining does not imply a contiguous usable 16 MiB gap. This confirms combined capacity/fragmentation pressure; it does not identify all remaining allocations as expendable.

Diagnostic improvement: the existing once-only layout report ignores allocations below 16 MiB and can be consumed by expected low-address bootstrap failures if enabled indiscriminately. A future diagnostic option should filter to the configured ordinary address region, report the first failure there regardless of request size, and include the largest gap satisfying the actual alignment. Temporary WINEOOMLAYOUT instrumentation was used for this investigation and is removed from the runtime afterward.

The filtered diagnostic control ended after 120 seconds, confirmed both address-window markers, appended fresh browser logs without ReadyToRender, and stopped the isolated Wine server. The source and deployed ntdll were then restored without the temporary diagnostic switch.

### Smaller allocator spans

A 512 KiB span / 512 KiB large-page configuration removes the 512 KiB pooled size class (its header would not fit) and retains pooled classes through 448 KiB. The bounded ASan/UBSan allocator suite, a largest-class full-to-empty test, and both translated thread/decoder fixtures pass. The incremental patch is `tools/fex-patches/half-megabyte-spans.patch`.

In the same 120-second Steam control, this reached a JIT report of 424 MiB before a 16 MiB allocation failed. Ordinary-region occupancy was 3988 MiB of 4093 MiB (`codex-steam-fit-halfspan4.log`). The fresh browser logs still contained no ReadyToRender. Both early address-window markers were confirmed and the isolated server was stopped. This is later startup activity, not evidence of a usable Steam client.

The minimum-L1 follow-up also ended without ReadyToRender after 120 seconds (`codex-steam-fit-minimum-l1-4.log`). It failed a 16 MiB allocation with 3990 MiB of 4093 MiB occupied. Both markers were confirmed, fresh logs were checked, and the isolated server was stopped.

Source review then found a separate ownership defect: named_monotonic_page_buffer_resource had no destructor calling release(), although its list entries only stored raw backing pointers. An owned fixture observed seven leaked backing regions after one destruction in the original code. Adding the destructor release passes 100 cycles, explicit/repeated release, alignment, and reuse under ASan/UBSan. This is a confirmed FEX resource leak; its contribution to the Steam failure has not yet been established.

The leak-corrected runtime passed both translated fixtures. Its 120-second Steam control (`codex-steam-fit-pmr-release4.log`) reached a JIT report of 472 MiB, then failed a 16 MiB ordinary allocation at 3970 MiB of 4093 MiB occupied. No fresh ReadyToRender was logged; markers were confirmed and the isolated server stopped. The leak fix is correct independently, but insufficient for Steam startup.

### Serialized translation

The first 120-second serialized-translation control (`codex-steam-fit-serial4.log`) did not log an ordinary-region allocation failure. It reached login-window creation and then main desktop-window creation. It still did not emit ReadyToRender. A longer control is needed to distinguish usable UI from window creation alone. The owned concurrent invalidation test passed both before and after serialization; decoder and L1/thread fixtures also passed.

Read-only macOS window inventory during the extended run confirms Wine-owned on-screen windows, including a 1280x800 window at the position logged for the main desktop. Pixel capture remains unverified: the normal UI tool rejects unbundled Wine processes, and the shell screenshot fallback reports no screen-capture authorization. No privacy setting was changed.

The 300-second serialized control (`codex-steam-fit-serial-long4.log`) initially passed main-window creation, but the final log showed repeated 16 MiB executable allocation failures (protect 0x40, attributes 0x40), followed by a 0x801000-byte data allocation failure. The browser JIT report reached 474 MiB of its 512 MiB pool. This is not a stable startup success. Both window markers were confirmed and fresh logs showed main-window creation; ReadyToRender was absent. The macOS inventory confirmed the main 1280x800 window and another 706x830 window. Pixel content, navigation, downloads, and physical iPad execution remain unverified. The isolated Wine server was stopped at the deadline. Chromium also logged DNS_ERROR_NO_DNS_SERVERS from GetAdaptersAddresses; investigate this independently before claiming networking works.

### Restoring the profile's code-buffer sizes and fixing DNS enumeration

With the existing Steam profile's 32 MiB client / 128 MiB browser buffers, the 120-second control emitted a fresh `FriendsUI ReadyToRender` message but later failed a 0x2801000-byte data allocation at 3981 MiB of 4093 MiB occupied (`codex-steam-fit-normal-buffers4.log`). Restoring FEX_MAXINST=5000 and FEX_MULTIBLOCK=1 reduced the browser JIT report to 216 MiB; that control also emitted the Friends UI marker, but later logged a 512 KiB allocation failure and a second Chrome startup marker (`codex-steam-fit-normal-translation4.log`). Neither is stable end-to-end success.

The owned network_config_probe.c established that DNS configuration enumeration and GetAdaptersAddresses failed with 9852 (DNS_ERROR_NO_DNS_SERVERS), while adapter enumeration skipping DNS and actual Steam hostname resolution succeeded. Temporary count-only diagnostics showed res_init returning success while the global state inspected by Wine remained uninitialized. Using Apple's explicit __res_state() accessor fixed the AF_UNSPEC and IPv4 configuration and adapter calls. The optional --require-ipv4-dns fixture mode now verifies those results and hostname resolution. IPv6-only DNS enumeration still reports no servers on this IPv4-DNS host. Native standalone resolver probes worked with both access forms, so this evidence identifies the failing Wine context rather than a universal Apple resolver defect.

`tools/wine-patches/apple-resolver-thread-state.patch` preserves the tested source change; the temporary diagnostics have been removed. The corrected dnsapi.so was atomically replaced and signed as our runtime component. Its 120-second Steam control again emitted the Friends UI marker, but failed a 0x801000-byte ordinary allocation (`codex-steam-fit-resolver-fixed4.log`). Downloads and iPad behavior remain unverified.


### Two unused guard reservations

The 120-second `codex-steam-fit-two-guards20.log` control increased the existing WINEPHANTOMPOOLS limit from one to two and gave ordinary views 20 GiB in the same 64 GiB window. Both 16 GiB + 64 KiB guarded reservations were recorded outside host backing. No commitment to those unbacked reservations was attempted; the runtime still rejects such a commitment. Fresh browser logs contained one Chrome startup and one FriendsUI ReadyToRender marker, with no ordinary allocation failure. This is an experimental reservation policy, not evidence that those guards remain unused for every workload.

The five-minute control (`codex-steam-fit-two-guards20-long.log`) completed with both layout markers, one Chrome startup, one Friends UI marker, no ordinary allocation failure, and no commitment to either unbacked guard. Browser JIT reporting reached 352 MiB. The isolated server was stopped at the deadline. A subsequent control reduces the browser's total reservation to 56 GiB and its ordinary region to 8 GiB, leaving 8 GiB outside its range for other host processes in a prospective device layout. The 64 GiB Mac control gives each native process its own window; it does not establish that their combined iPad host fits. Pixel verification is additionally unavailable while the Mac is locked.


The 180-second 56 GiB / 8 GiB ordinary-region control completed with one browser startup and one Friends UI marker, no ordinary allocation failure, and no commitment to the unbacked guards (`codex-steam-fit-two-guards56-small8.log`). The early log confirms 0x70000000000–0x70e00000000 and the ordinary region 0x70c00000000–0x70e00000000. Its summary initially printed a false early-limit check because that check retained the previous 64 GiB endpoint; direct inspection confirmed the intended bound, and the check was corrected. The isolated Wine server stopped at the deadline.

An uninstalled device candidate is `build/mptest/profile-steam-single56.json`: 56 GiB reserved from 448 GiB, ordinary browser views at 496–504 GiB, three slots, an 800 MiB shared code pool with 550/150/80 MiB browser/client/helper shares. Profile validation passes. These sizes remain unverified on the physical iPad, especially the combined address-space, code-arena, and memory-pressure requirements.


The candidate was built successfully and installed over the existing app without uninstalling it. Only our ntdll.so, dnsapi.so, and libarm64ecfex.dll (runtime and prefix copy) were updated. The physical launch used the saved Developer service mode and local authorization; the fresh run-tagged native log reported 894173184 bytes required, below the runtime's 1073741824-byte cap, but preparation returned NC_REJECTED immediately and guest entry remained blocked. No Steam code ran in this attempt.

Source inspection explains the rejection: ArenaControl.c and DebugArenaRequest.swift impose a separate 512 MiB ceiling, chosen for the 900-second RSP preparation deadline. LocalArenaPublisher rejects the oversized request during encoding. Raising the candidate's capacity requires coordinated protocol/session-timeout changes with boundary tests, not merely changing its profile. The launcher currently exposes the runtime's larger cap and then a generic errno=1 failure; it should report the selected backend's actual capacity before preparation.


The local Developer service cap now matches the runtime's 1 GiB maximum. Its transaction deadline is 1800 seconds, with a 1830-second publisher wait and a bounded 1850-second transport envelope. Full zero preflight, per-page preparation/readback, exact process/challenge checks, one-shot attachment, and confirmed detach before guest entry remain required. The publisher reports oversized requests explicitly. Native ASan/UBSan IPC and publisher tests and Swift request tests pass at the exact boundary and reject one page above it. The independent synthetic RSP peer passes existing failure-path tests plus sustained simulated work beyond the former 900-second bound and expiry at 1800 seconds. The updated iPad build succeeded; physical preparation with the larger arena is being retried.


The retried physical preparation succeeded for all 894173184 bytes in 249.476 seconds; the extension reported Prepared and detached. Steam and its browser then executed in slots 0 and 1. The host could not reserve the requested contiguous 57344 MiB region, but continued with an empty WINELARGERESERVE; Wine ignored WINESMALLRANGE because it was not contained in a valid large reserve. The browser subsequently attempted to commit at 0x1c00001000 inside the second unbacked guarded reservation. Wine rejected that commitment and startup failed. This contradicts extending the Mac observation of unused guards to this physical layout. It is not a successful single-app Steam startup.

Next actions: make a required large-reserve failure stop startup explicitly, inspect the host VM layout before guest entry, and determine a feasible reservation arrangement. Do not permit commitment into the unbacked guard or treat the Mac startup marker as proof of device compatibility. Source apps remain unchanged, and no debugger was attached after guest entry.


Moving the required large reservation to the beginning of ng_initialize, before loading runtime libraries and preparing executable memory, succeeds on the physical iPad: 57344 MiB reserved at 0x7000000000. The new startup order refuses guest entry if that required reservation cannot be obtained; it no longer silently passes an empty range to Wine. It also checks that the requested size fits the task bounds before subtracting it. The iPad build passes, and the fresh early-reservation launch is now in executable-memory preflight. This establishes that the earlier failure was sensitive to allocation order, not that a 56 GiB reservation is intrinsically impossible. Browser execution under the successful reservation remains to be checked.


With early reservation, physical preparation completed in 247.977 seconds and confirmed detach. Wine accepted the browser's 496–504 GiB ordinary range, and both guarded reservations remained uncommitted through this startup. CEF logged its current Chrome startup and a CreateBrowser milestone. The browser then reported an unhandled stack overflow on its main thread; its reported stack was 1 MiB. The device candidate omitted WINEMAINSTACKSIZE=8, which was present in the passing Mac controls and the previous browser-only profile. The candidate now includes that setting for a retry. Native PE section-protection failures for hnetcfg.dll and imagehlp.dll were also logged and remain separate unresolved observations. No usable Steam UI or download is established.


### Eight-MiB stack retry and image mapping investigation

The physical eight-MiB stack retry prepared 894173184 bytes in 247.948 seconds and confirmed detach. It accepted the early 56 GiB reservation and browser ordinary range, then logged another main-thread stack overflow with an eight-MiB range. Thus the omitted stack setting did not explain the failure. Repeated native mswsock.dll executable-section protection failures also occur. Steam UI, download, and game launch remain unverified.

A candidate preserve-image-alias.patch prevents map_file_into_view from replacing prepared executable pool pages with file mappings; it uses the existing alias-aware pread path. This candidate is under validation and has not been deployed to the iPad. Initial owned ARM64EC DLL fixtures also fail in controls and are not sufficient evidence. The first Mac Steam regression with the candidate attempted commitment inside the second unbacked guard, was rejected, and restarted its browser before eventually logging FriendsUI ReadyToRender. This further demonstrates that the previously unused guards cannot be assumed unused in every startup. No permission to commit unbacked memory was added.

The three-minute Mac candidate control completed with the intended address bounds, two Chrome starts, and a Friends UI marker after the rejected guard commitment. A reduced native ARM64 fixture avoids CRT/ARM64EC startup dependencies and loads a 64 KiB-section / 16 KiB-file-aligned owned DLL, reads a relocated pointer, and checks its exported result. Both the original and candidate loaders pass this Mac smoke test; it does not reproduce iPad executable-protection enforcement. The candidate loader was restored after that comparison. The failed physical trial was stopped before replacing only our ntdll.so, then a fresh launch began with the unchanged stack/layout profile. No debugger was attached to running guest code.

An additional Mac control reserves 60 GiB (0x70100000000–0x71000000000), uses 0x70800000000–0x70a00000000 for ordinary views, and allows only one unbacked guard. It fails before a fresh Chrome startup: the browser first reserves two real 16 GiB ranges, then cannot fit another 16 GiB + 64 KiB reservation and its 32 GiB fallback. Thus this particular layout does not resolve the guard problem. It is a Mac capacity result, not a device test.

The physical image-alias candidate prepared and detached in 250.016 seconds. Initial observations show one executable-section failure (imagehlp.dll .hexpthk), compared with 1105 failures in the prior eight-MiB-stack run, and no immediate stack overflow. However, its native log then stops growing at 127928 bytes, with 166 generic mprotect errno=22 reports and no fresh CEF startup. This is not startup success and the protection-error count alone does not establish causality. The host mprotect failure diagnostic now includes address, size and requested protection and preserves errno across logging, to make the next trial actionable. The saved native ARM64 aligned-image smoke fixture passes; it does not reproduce the physical protection rules.


### Prepared-pool reuse diagnostic

The protection-diagnostic iPad run prepared and detached in 254.349 seconds. It reproduced the browser stack overflow. Error 22 requests were mostly four-KiB-aligned ranges outside the native code pool. Error 13 requests included read-execute transitions inside the prepared pool, including a 128 MiB FEX code allocation and native image sections. Source review shows find_jit_pool_area can reuse ranges released by delete_view even though former writable data pages cannot necessarily regain execute permission on this host. This is a hypothesis supported by protection metadata, not a proved complete explanation of the stack overflow.

The opt-in experimental-no-pool-reuse.patch uses opposing high/low allocation watermarks inside an aliased pool when WINEJITPOOLNOREUSE=1. It leaves the default allocator unchanged. Freed ranges are not reused in this diagnostic mode; capacity can consequently be exhausted sooner. The aligned_image_probe native fixture performs eight load/execute/unload cycles, checks relocated values, and verifies distinct bases when this mode is enabled. It passes on the Mac. The matching iPad candidate builds successfully and validates as a profile. A bounded Mac Steam capacity control is running before physical deployment.

The no-reuse three-minute Mac control completed with both intended address-window markers, one fresh Chrome startup, one FriendsUI ReadyToRender marker, and no logged unhandled exception, stack overflow, allocation failure or commitment to an unbacked guard. The eight-thread owned-code invalidation fixture also passes with this mode enabled. The no-reuse profile and runtime were installed after stopping the failed physical run, and the fresh physical attempt confirmed WINEJITPOOLNOREUSE=1 while preparing memory. These Mac results are not proof of iPad UI or download support.

The physical no-reuse trial prepared and detached in 249.211 seconds, started Chrome at 01:28:46 local device time and created its browser at 01:29:08. It logged no native DLL executable-section failures, no allocation failure and no commitment into the unbacked guards. It nevertheless reproduced the same eight-MiB main-thread stack overflow. This separates the pool-protection defect from the remaining browser crash; the no-reuse mode does not establish usable Steam startup. Existing mprotect error-13 reports during release of demoted ranges remain, but those retired ranges are no longer reused for new allocations.

A further opt-in experimental-exception-metadata.patch records at most 64 Unix-to-Windows forwarded exceptions per runtime instance, logging exception code, program-counter address and stack-pointer address only. It does not read guest instructions or stack contents and does not attach a debugger. It is enabled by WINEEXCEPTIONMETADATA=1 before signal handlers are installed. The rebuilt Wine passes the owned concurrent invalidation fixture with both diagnostic modes enabled; the iPad profile builds successfully. A fresh physical launch is now preparing memory to distinguish an exception-delivery cascade from ordinary stack exhaustion.

The first bounded exception-metadata physical run prepared and detached in 248.759 seconds. Its log limit was consumed by normal translated-code alignment faults and initial access violations at a stable native stack pointer. The app remained present in devicectl process inventory, but output stopped changing at 145175 bytes; no new overflow was recorded during that observation window. Lack of new output is not evidence of process termination. The diagnostic is refined to retain per-thread stack-pointer transitions (at most 32 per thread) and always report STATUS_STACK_OVERFLOW. It uses only runtime-owned thread bookkeeping and signal-context addresses. The rebuilt runtime passes the concurrent owned-code invalidation test. The previous live observation is intentionally stopped to deploy that refinement, not restarted on an assumed crash.

The per-thread transition diagnostic reproduced the physical overflow. Browser thread 0040 logged eight transitions: initial translation faults, a native transition near the top of its eight-MiB Windows stack, return to the FEX execution stack, one STATUS_STACK_OVERFLOW, then access violation during exception delivery near the bottom of the Windows stack. It did not show a cascade of forwarded exceptions draining the stack. The matching three-minute Mac diagnostic control reached a fresh Friends UI marker. A single 32 MiB main-stack control is prepared to distinguish bounded platform-specific stack use from runaway recursion; it is not yet evidence that increasing stack capacity fixes startup.

The 32 MiB physical control prepared and detached in 248.028 seconds, but failed before usable browser startup with a rejected 4 KiB commitment at 0x1c00001000 inside the second unbacked guarded reservation. The main stack allocation was confirmed as 32 MiB. No stack overflow or native DLL executable-section failure was recorded before this different failure; this does not establish that the stack problem is fixed. The owned host process remained present after the browser exception. The pre-entry VM map confirms the proposed low-address phantom range is already a host-owned no-access region, so it cannot safely be converted into backing. Commitment rejection remains required. A viable layout must reserve real available address space for any pool that may receive commitments; the two-phantom control is not a reliable Steam configuration. Raw local evidence: /private/tmp/codex-steam-stack32-native.txt.

### Allocator source check after the 32 MiB trial

Chromium tag 126.0.6478.183, matching the version reported by CEF, explains the reservation shape in `PartitionAddressSpace::Init`: the non-glued BRP pool allocation is `brp_pool_size + PageAllocationGranularity()`, aligned with a negative-granularity offset. Only the leading granularity unit is the forbidden zone; the remaining pool is registered as usable. Therefore allocation shape alone cannot justify classifying the entire reservation as never committed. This is primary-source context, not inspection of Steam application code or proof of Valve's exact build configuration.

Source: https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/base/allocator/partition_allocator/src/partition_alloc/partition_address_space.cc (Init, non-GLUE_CORE_POOLS branch).

The physical trace independently records two 16 GiB backed reservations and two 16 GiB + 64 KiB unbacked reservations, followed by commitment in the second unbacked one. Giving all four disjoint reservations real native backing requires more than 64 GiB, even before ordinary allocations. The currently available high address interval is only 448–512 GiB and contains other host allocations. The existing extended-virtual-addressing entitlement is already requested. This rules out simply backing all four within the current native-address layout. It does not prove that every other execution architecture is impossible. Do not enable commitments over the host-owned no-access region or report this profile as working.
