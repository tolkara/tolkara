# Software-memory experiment

The user authorized a Cyberpunk-only exception on 2026-09-26 for runtime
memory emulation: fetching the faulting instruction and executing its memory
access against software backing. On 2026-10-14 the user explicitly extended this exception to Steam. The general
project restriction continues to apply to other applications. This does not authorize binary patches,
debugger attachment after guest entry, game reverse engineering, input
automation, or integrity/anti-cheat workarounds.

The `--sparse-memory-probe` diagnostic runs Tolkara's own assembly fixtures.
Normal game launches still use the existing native memory path.

The experimental game integration requires `--cyberpunk-software-vm` together
with `--app=cyberpunk-2077` and the matching executable path. It attempts native
anonymous mappings first, then supplies a full software range if a large
reservation fails with ENOMEM. It disables the old reservation-downsizing
adapter for that launch. `TOLKARA_SOFTWARE_VM_MB` sets the backing limit (default
4096 MiB; accepted range 64..8192). `TOLKARA_SOFTWARE_VM_FORCE_MB` is a comparison
control that forces eligible reservations at or above that size into software.
In the simulator, setting `SIMCTL_CHILD_TOLKARA_SOFTWARE_VM_FORCE_MB=65536`
on the diagnostic launch reproduces the failed 64 GiB native reservation's
software path. Prepare only the fresh zeroed executable arena and detach before
guest entry, as with other simulator native-startup runs.

The integration bridges bulk copies/fills, file read/write and stdio buffers,
paths, file-status output, and bounded string/comparison scans. Its handler fetches instructions only to execute
memory operations and bounded exclusive-access sequences; it does not dump instruction bytes. Failure
reports include an address, a memory error and aggregate counts. Signal actions
requested by the application are chained, with a bounded history of 127 changes
for SIGBUS/SIGSEGV.

## Mechanism

`GuestSparseMemory` reserves integer address ranges and supplies zero-filled,
16 KiB backing pages on first write. Its metadata and bounded backing arena
are allocated before execution. Mapping, protection and access operations do
not allocate host heap memory. A lock serializes access and atomic operations.
Failed accesses leave output buffers and backing data unchanged.

The diagnostic first obtains a native PROT_NONE guard for its software range.
If that reservation fails, it verifies that the selected software addresses
are above the task's reported maximum address. The signal handler accepts only
instructions inside our fixture. `GuestMemoryInstruction` executes supported
memory accesses and advances the saved PC only after success. Other faults
return to the previously installed handler.

Supported fixture instructions include scalar and SIMD immediate/register
loads and stores, pairs, LDAR/STLR, LDAPR, single-register CAS, CASP, and the nine
scalar LSE read-modify-write operations. SIMD LD/ST1–4 multiple-structure, single-lane and load-replicate forms support 64/128-bit vectors and post-index addressing. Unsupported instructions are rejected.
Exclusive accesses execute as a bounded sequence: at most 32 instructions in
a 128-byte window, including supported register arithmetic, branches and scalar
reads from software memory. A store-exclusive, other supported write or CLREX
ends the sequence. No software monitor survives a
return to native execution; an isolated store-exclusive fails. Unsupported
sequences leave registers and backing data unchanged. Each backing page has a write generation. Writes on other pages do not
invalidate a monitor; mapping changes invalidate all monitors to cover
protection and backing-page reuse. Writes elsewhere on the same page may
conservatively cause extra exclusive-store failures.
See section 3.2.4 of Arm's
[synchronization guide](https://documentation-service.arm.com/static/68c223238a337a2bc6645c0a?token=)
for monitor clearing by CLREX and exception return.

## Evidence and limits

On an iPad Pro M5 running iPadOS 27, the expanded scalar/SIMD/addressing/atomic
fixture successfully used three distinct 16, 64 and 32 GiB software ranges.
It handled 18,600 faults, touching six backing pages (96 KiB) in 0.036765 seconds.
The same process refused a native 112 GiB reservation and reported its maximum
address as 512 GiB; the software ranges began at 1 TiB. These are small fixture
accesses, not a game-performance measurement. The diagnostic checks hardware
LSE support before running the atomic fixture.

Mac sanitizer tests also compare randomized mapping operations against the
existing dense memory model, test page recycling and capacity failures, and
contend on atomic-add, compare-and-swap and exclusive counters from eight
threads. Original native assembly supplies an independent reference for all
nine scalar LSE operations at byte, halfword, word and doubleword widths.
The full `tools/test_emulation.sh` suite passed on 2026-09-26, including the
new sparse-memory tests. The focused instruction test was also rerun after
adding the explicit Armv8.1 assembly target and hardware feature check.

Additional kernel/framework pointer bridges and instruction coverage may be
needed. Memory is bounded by the preallocated backing arena; there is no disk
eviction. There is no Cyberpunk gameplay result from this experiment yet.

## Game startup evidence

The initial integrated iPad run completed all 6,540 initializers and entered
the original main function with the full 64 GiB software reservation. It
handled about 829,000 faults before requiring LDAPR. With LDAPR implemented,
the next run handled about 3.16 million faults and used 334 backing pages
(5.2 MiB), then stopped at an exclusive-access operation. Both runs preserved
the original executable and detached the Developer service before guest entry.
The exclusive sequence implementation passes native differential fixtures,
six-thread counter contention, and failure-atomicity tests on the Mac. A forced
64 GiB software reservation reproduced the same failure in the simulator:
a memory access inside an exclusive sequence needed support. With that support
added, the simulator opens all 32 archives and handles over 16 million faults.
The matching iPad run also opens all 32 archives and `final.redscripts`, then
reports an engine watchdog timeout after over 33 million handled faults.
This clears the original null-plus-0x18 archive crash, but is not a menu or
gameplay result.

Instruction fetch can now read the current word through the loader-owned
shared arena, avoiding a Mach read syscall for every access. There is no code
cache and no copied block execution; mutation of the shared bytes is visible
on the next fetch. Remapping or revoking read access disables this shortcut.
Bounds, fresh bytes and invalidation are covered by synthetic tests.

A placement probe on the iPad retains a 233 MiB arena and a native 64 GiB pool
alongside a 64 or 256 MiB bank; 1 or 4 GiB banks fail in either allocation order.
`TOLKARA_SOFTWARE_VM_NATIVE_POOL_MB` selects one exact large size for native
placement and routes other eligible reservations of at least 64 MiB to
software. This is a comparison control, not the default: the simulator with
256 MiB backing and a 65536 MiB preferred pool times out earlier, during
archive loading. The matching iPad run keeps the 64 GiB pool native but reaches over 67 million
faults and the same watchdog failure. The native-first default is retained.

A separate `engine/config/platform/mac/tolkara-memory-test.ini` on both the
simulator sets `[Engine/Watchdog] TimeoutSeconds = 600`; the iPad now sets
`TimeoutSeconds = 3600` to distinguish slow startup from
its next functional failure. No binary patch or third-party mod is installed.
The INI experiment follows the setting described by the
[watchdog configuration mod's author](https://www.nexusmods.com/cyberpunk2077/mods/16297).
With the 600-second setting, both simulator and iPad finish scripts and load shader caches.
The simulator then reaches its known private-heap assertion. The iPad passes
that heap operation and reached an unsupported SIMD structure instruction;
implementing those forms clears that fault. Telemetry shows the iPad continues substantial computation after display
setup, with about ten workers active. Rendering is not validated. Remove the separate INI to restore the default timeout.

The SIMD structure decoder is compared against 164 original native assembly
fixtures, with three input patterns and aligned/unaligned page-crossing cases.
Tests cover register wrap, post-index updates, permissions and rejected
encodings. A signal/resume fixture also matches native output. String bridges
cover page edges, unsigned comparisons, native/software combinations and
zero-length operations. The full sanitizer suite passes with these additions.

Current experiments build the runtime with `GCC_OPTIMIZATION_LEVEL=2`.
Simulator launch-to-heap-assertion time improved only from about 6m20s to 6m10s
(including arena preparation), so this has not solved the fault overhead.
A false-returning `CGDisplayModeIsUsableForDesktopGUI` stub was replaced with
an implementation for the UIKit screen mode; its physical-device test is in
progress.

With `--trace-guest`, the runtime reports fault totals and increments, backing
page counts and kernel thread states every ten seconds for at most one hour.
It also reports active imported mutex, condition, rwlock and semaphore wait
boundaries. These diagnostics use runtime-owned counters and kernel metadata;
they do not read application registers, stacks or memory. The display usability
fix removed the stub call on the iPad. The apparently quiet phase after a
worker's memory-capacity query is active computation: fault totals keep rising.
The 600-second run reached about 219 million handled faults before the watchdog
fired, with about 354 MiB of sparse backing. Single-threaded script loading ran
at about 630,000 faults/sec; the following worker phase slowed to 140,000–170,000
faults/sec in total.

The sparse lock now waits with atomic reads and an ARM yield hint instead of
repeated atomic writes to the lock's cache line. An original eight-thread
backend benchmark improved from about 2.4M to 7.1–9.0M operations/sec on the Mac;
this is not yet a measured iPad game improvement. Focused signal/resume and
page-local monitor tests and the full sanitizer suite pass. The next iPad run
combines these changes with the longer watchdog timeout.

`TOLKARA_SOFTWARE_VM_CPUS=1..64` is an optional comparison control for guest
CPU-count `sysctlbyname`, numeric `sysctl`, and `sysconf` queries. It caps successful CPU counts without
increasing them, and leaves other queries and the default launch unchanged.
It does not set host thread affinity. This is intended to test whether fewer
guest workers reduce fault overhead. The first device test capped `hw.ncpu` at 2
but still ran about ten workers at the original throughput; it covered only
`sysctlbyname`. Numeric `sysctl` and `sysconf` coverage is built for the next run.
A separate original assembly loop on the Mac, with distinct data per thread,
measured aggregate fault/resume throughput of 448K/s with one thread, 432K/s
with two, 341K/s with four and 176K/s with eight. The iPad's first worker samples
with the lock changes remain close to the earlier baseline. The direct-backend
benchmark improvement therefore does not establish a game improvement.

## Window-initialization checkpoint

The 3600-second iPad run reached audio plug-in discovery and language selection,
then crashed in CoreFoundation dictionary construction after 273,212,724 handled
faults. The invalid key `0x394d4109b00000a8` exactly matched the first eight bytes
of Tolkara's own generated `NSImageHintInterpolation` function stub. Apple's SDK
declares this symbol as an NSString global. No game instructions were examined.
The adapter now supplies typed image-hint string constants, and the build-time
and runtime classifiers recognize all three hint names. Synthetic chained-fixup
and dictionary tests cover the error. The display bridge also answers pixel
width and the single integrated screen's mirror/built-in status. Physical-device
validation is in progress with a two-CPU query cap and presentation timestamps.

The image-hint fix passed the physical-device checkpoint: at 274.6 million
handled accesses, Cyberpunk created its window at 1210×834 logical pixels.
The invalid dictionary-key crash is cleared. Metal presentation and the game
menu have not yet been observed. This run uses the first, sysctlbyname-only
CPU cap; the additional numeric CPU-query adapters are built but not installed.

Progress telemetry also exposes the sparse backend's existing successful-write
counter. It counts nonempty writes and successful atomic updates; reads, failed
compare-exchanges, rejected writes and mapping changes do not increment it.
This adds no per-access work and does not inspect application data. Its purpose
is to distinguish repeated read faults from workloads that keep writing data.

The window run later reached GOG Update and about 405 million handled accesses,
then hit a native stack guard. The crash report identifies `gsv_copy` allocating
its 64 KiB scratch buffer on a worker with a 64 KiB stack. Transfer scratch is
now 4 KiB. A synthetic worker with an explicitly supplied, guarded 64 KiB stack
reproduces SIGBUS with the old buffer and passes copy, overlapping copy, fill,
and file/stdio bridges with the new one. The suite runs this case both with
sanitizers and without them, because ASan enlarges pthread stacks. Device
validation cleared this stack failure and reached Metal presentation.

The expanded CPU-query experiment reached the first worker phase on the iPad.
`sysconf(_SC_NPROCESSORS_ONLN)` now returns 2; startup creates eight fewer
threads. That phase processes roughly 570K–630K faults/sec, compared with
140K–170K in the prior run. These are approximate rates from ten-second
samples. This is a startup improvement, not a frame-rate result.

The small-stack fix reached at least 60 presented Metal frames on the iPad.
Timing samples were 4.7–5.3 FPS, with a 14.6-second pause; this does not establish
menu content or gameplay. The run then raised NSMallocException in a native
Bluetooth-audio plug-in while allocating a Foundation object. Its last native
4 GiB mapping ended just 1 GiB below the task address ceiling. The next comparison
uses `TOLKARA_SOFTWARE_VM_FORCE_POOL_MB=4096` to put exact-size, anonymous,
nonfixed 4 GiB reservations in software without shortening them. Default
placement is unchanged. Kernel footprint, resident/virtual sizes and remaining
physical-memory allowance are now logged to test whether host address-space
pressure explains the failure. The exception alone does not prove that cause.


The 4 GiB software-pool comparison survived the previous allocation-failure
point and continued into `tweakdb.bin`, with repeated Metal presentation. The
post-window quiet interval did not recur after the fullscreen lifecycle fix.
At the end, the process had handled about 595M faults and reported a 6.65 GiB
physical footprint with 9.35 GiB remaining. This supports address-space pressure
as the earlier failure's cause but does not prove it in isolation.

The next failure was an uncaught `gog::UnauthorizedAccessError` on the first
`SetRichPresence` call. Two independent original C++ fixtures exposed missing
exception support: the call logger lacked unwind metadata, and guest images'
compact/DWARF unwind tables were not registered with libunwind. Either omission
causes the corresponding fixture to abort; both fixes preserve catches,
rethrows and destructors. The loader now registers the original table locations
before entry using Darwin's dynamic unwind lookup SPI. No exception result is
altered, and no game instruction is inspected or changed for this fix. Device
validation is pending; the exception's presence alone does not prove that the
game has a handler for this particular call.


On 2026-09-27, the optimized iPad build after merging main (`2c7a63e`)
passed the previous rich-presence abort. At about 597M handled accesses,
`SetRichPresence` logged its service error for a main-menu presence state,
returned through the wrapper, and the game continued to open
`r6/config/bumpersSettings.json`. No service result was suppressed or changed.
This validates the combined unwind fix on the device; it does not isolate the
two omissions from each other. Original fixtures cover them separately and
also pass derived-class exceptions caught through a standard-library base
across placed/host image boundaries, including cleanup and DWARF frames.
The run presented at least 60 Metal frames, with early samples near 5 FPS and
long loading gaps. Visual menu content and interactive gameplay remain unverified.

A direct system screenshot later confirmed the opening cinematic on the iPad,
including its Space-to-continue prompt and subtitles. The capture used the
CoreDevice screen-capture service, without a debugger, GPU readback injection,
or game input. The screenshot stays in ignored local logs. More than 1,200
Metal shader-library loads succeeded with no rejection logged in this run.
Further menu interaction and gameplay validation require a manual keypress.

## Small-block backing comparison

`TOLKARA_SOFTWARE_VM_SMALL_BLOCKS=1` preallocates the bounded backing capacity
as individual 16 KiB allocator blocks instead of one contiguous mmap. All blocks
and metadata are allocated before the signal handlers are installed. Pages are
zeroed before first use or reuse; accesses, atomics and recycling share the same
implementation and tests for both layouts. The default remains contiguous.

The standalone iPad probe on 2026-09-27 held a native 64 GiB reservation alongside
1 GiB of small blocks, in either allocation order, and verified their contents.
The same probe could not hold the native reservation alongside a contiguous
1 GiB or 4 GiB bank. This establishes an allocation-placement option; game
performance still requires a separate comparison. The experimental combination
uses `TOLKARA_SOFTWARE_VM_NATIVE_POOL_MB=65536`, routing other large reservations
through software while attempting the full 64 GiB reservation natively. The
preferred pool is reserved before guest initializers and is handed out only for
an exact eligible anonymous request, after applying its requested protections.
An unused pending reservation is released at shutdown or when changing the
preference.

The larger 4 GiB small-block probe failed to retain the native pool: only about
1.6 GiB of its blocks stayed below the large-mapping window, and the remainder
used that window. The first 4 GiB game comparison likewise fell back to software
for all three large pools. Its first 87 million emulated accesses fetched more
than 99.9% of instructions from the loader alias, so checked kernel instruction
reads were not the main cost in that interval. With 1 GiB backing and early reservation, the subsequent iPad game launch
successfully received the full native 64 GiB mapping. The launch then ended with SIGTRAP on `redIOWorker0` while opening the first
archive, before its first ten-second progress sample. The main thread was
waiting on a condition variable. This establishes placement only; it has not
improved the playable state, and the I/O failure hypothesis needs API tracing.

Trace progress now reports aggregate instruction-fetch counts for the loader's
readable alias and the checked kernel fallback. It records no instruction
contents and continues after the first hour of execution.

## Steam integration (authorized 2026-10-14)

`--steam-software-vm` requires `--app=steam-windows` and the Steam/Wine native
loader path. Ordinary library launch can opt in with profile environment
`TOLKARA_STEAM_SOFTWARE_VM=1`; the launcher passes the selected profile identity
to the runtime, which requires `steam-windows` and the same loader path.
An environment value alone cannot authorize another profile. It is mutually exclusive with the Cyberpunk flag and rejects
Local signing. This is an experimental opt-in, not an assertion that Steam works.
The multiprocess signal dispatcher first offers hardware memory faults to the
software-memory handler, then routes unhandled signals to the owning Wine slot.
Wine address-space integration and physical Steam verification remain pending.

The first integration checks pass: the owned two-process signal fixture executes
software-backed memory accesses and separately raises SIGSEGV in each tagged
thread, verifying that each slot receives only its own signal. The existing
software-VM concurrency, chaining, mapping and buffer-bridge fixture passes with
ASan/UBSan. The generic iPad Tolkara build succeeds. None of these checks proves
Steam startup or Wine's large-reservation path; no new device success is claimed.

### Cost control for the Steam experiment

`tests/bench_software_memory.c` compares the same owned ten-access assembly
routine with ordinary memory, software memory using checked instruction fetch,
and software memory using a registered readable code view. On the development
Mac, an optimized build measured approximately 3.0 ns, 26.66 us, and 22.01 us
per call respectively. The final sample handled 1,000,000 faults in 100,000
calls, about 2.2 us per fault. This is a tiny warm-memory microbenchmark; its
roughly 7,452-fold ratio is not an application slowdown prediction or an iPad
result. It demonstrates that frequently accessed pools should remain native
where possible. Steam's fault frequency and end-to-end responsiveness remain
unmeasured. The two-app alternative is not abandoned by this experiment.

The software allocator now supports page-aligned reservations with a power-of-two
alignment and offset, using non-replacing maps and retrying collisions. The
sparse-memory fixture validates two 16 GiB pools and two 16 GiB + 64 KiB pools,
independent committed contents, inaccessible leading guards, invalid alignment,
capacity failure and reuse after release. The software-VM fixture executes our
assembly against a committed page in an aligned pool and verifies executable
protection is rejected. Both fixtures pass with ASan/UBSan. Wine has not yet
been connected to this API; its address-limit and mapping bookkeeping require
adaptation before another Steam device run can exercise it.

The experimental Wine patch now discovers the opt-in host allocator through
three loader-provided symbols. It retains native limits for ordinary allocations,
adds software-range coverage to page-protection bookkeeping and valid commit /
query paths, and uses software backing only after a native guarded-pool
reservation cannot fit. The unbacked phantom mode must be disabled for this
experiment. `software_pool_probe.c` passed on the Mac with the paired
`software_pool_test_host.c`: two pools used native Wine space and two used real
host test backing above Wine's artificial limit. All four passed reserve,
commit, independent writes, query, protection changes, and release. This test
isolates Wine bookkeeping; the test host does not emulate memory accesses.
The physical iPad version with real software backing is launched separately.

Physical iPad control: the owned Wine fixture passed reserve/commit/query/protect/
release with actual software backing after 265,027,584 bytes of executable arena
were prepared in 75.385 seconds and the developer service detached. The log
records three aligned software reservations and actual handled memory faults,
then `PASS software pool Wine reserve/commit/query/protect/release`. Raw local
capture: /private/tmp/codex-steam-software-fixture-ipad.txt. This is not a Steam
workload. A later free-region query bound correction and query-after-release
assertion pass the Mac control; that additional assertion was not in this iPad
run. The upcoming Steam policy must avoid letting an early native guarded pool
fragment space needed by the two ordinary pools; selective software placement
must be explicit, rather than relying only on allocation order and fallback.

`WINESOFTWAREPOOLS=1` retains native-first fallback. Mode `2` prefers software
for the guarded-pool reservation shape while leaving ordinary pools native.
The owned Windows fixture passes reserve, commit, query, protection, release,
and query-after-release with all four guarded pools placed through the test
host. The Steam physical trial uses mode 2 only for its browser process,
512 MiB of bounded software backing, the existing 56 GiB native reservation,
and no phantom reservations. It was launched after a successful generic iPad
build; results are pending. The two-app alternative remains under consideration.

The first Steam software-pool trial prepared 894,173,184 bytes in 245.506
seconds and detached before guest entry. Both guarded browser pools received
software backing. It then failed after 29,194 handled faults with GM_INVALID
on a write; 53 backing pages were resident (well below the 512 MiB capacity).
There was no fresh CreateBrowser or ReadyToRender marker in the collected
browser logs. This passes the previous unbacked-reservation failure but is not
usable Steam startup and cannot establish responsiveness. Current evidence
suggests an access-semantics issue rather than backing exhaustion. A narrow
failure diagnostic reports only ordered-access width and alignment remainder
when the existing decoder rejects such an access; it does not dump instruction
bytes or change memory semantics. Raw local evidence is preserved in
/private/tmp/codex-steam-software56-native.txt.

The alignment-diagnostic physical trial instead encountered an earlier browser
main-thread stack overflow with WINEMAINSTACKSIZE=32. Preparation completed
in 249.249 seconds and detached. Both guarded pools were reserved through
software, but no handled software faults or alignment failure were logged.
The newest webhelper section contains CreateBrowser but no ReadyToRender;
this does not prove usable startup. The raw runtime log is preserved at
/private/tmp/codex-steam-alignment-trial-stackoverflow.txt. The next controlled
trial changes only the configured main-stack minimum to Wine's existing
64 MiB maximum; memory-instruction semantics remain unchanged. FEX's own
Arm64.cpp handles unaligned LDAR/STLR, but the suspected software-memory
alignment failure is still unconfirmed by the new diagnostic.

The 64 MiB main-stack trial prepared/detached in 251.222 seconds. It did not
record a stack overflow or handled software-memory faults, but exhausted
Wine GDI object handles immediately before an unhandled breakpoint exception.
Fresh webhelper logs reached CreateBrowser, not ReadyToRender. The saved
runtime log is /private/tmp/codex-steam-stack64-gdi-exhaustion.txt. A bounded
Wine allocator diagnostic now reports live handle counts by type only on the
first exhaustion, without reading object contents or changing capacity.
This will distinguish the exhausted object class before changing allocation
or drawing behavior; neither software alignment nor usable startup is proven.

The owned native ARM64 gdi_handle_probe passes on the Mac with the rebuilt
Wine: it exhausts the handle table with 65,480 regions, receives the expected
region-dominant aggregate diagnostic, releases all its regions, then completes
70,000 create/delete cycles. This validates diagnostic classification and
normal reuse on the Mac, not the source of Steam's iPad exhaustion. The GDI
diagnostic runtime is installed on the iPad and its fresh trial is preparing.

The GDI-diagnostic run instead reproduced the software-access failure after
15,092 handled faults, with 28 backing pages resident. Preparation took
253.870 seconds. The ordered-access diagnostic confirms width 4 and address
remainder 1. Source review of FEX Arm64.cpp confirms translated x86 ordered
loads/stores already have unaligned handling for native memory. The Steam
opt-in now permits unaligned LDAR/STLR/LDAPR in software backing under its
existing lock, without patching instructions. Default ARM behavior and
exclusive/read-modify-write alignment requirements remain unchanged.
Sanitized tests pass for widths 2/4/8, every unaligned offset, cross-page
protection failures without partial retirement, and actual owned assembly
signal recovery. Physical Steam validation is still pending. Raw evidence:
/private/tmp/codex-steam-confirmed-unaligned-store.txt.

The first physical ordered-access compatibility trial prepared/detached in
255.657 seconds and handled at least 8,192 software faults without a logged
alignment rejection. It still failed with GDI exhaustion: 21,818 DCs, 21,816
regions and 21,826 fonts were live. This suggests nested or repeated setup,
not proof of a particular leak. Bounded in-flight entry/exit counters in Wine's
OpenDC and SelectFont paths will distinguish nesting from returned allocations.
Evidence: /private/tmp/codex-steam-gdi-type-counts.txt. Steam remains unverified.

The in-flight diagnostic physical trial prepared/detached in 254.017 seconds
and reproduced the same DC/region/font exhaustion. No OpenDC or SelectFont
in-flight count reached 16. This excludes deep simultaneous nesting within
those calls; it does not exclude recursion in their caller. Next is the owned
x86-64 gdi_text_probe on the same device/runtime to compare API-visible font
metrics and display values without analyzing Steam's executable. Evidence:
/private/tmp/codex-steam-gdi-inflight-result.txt.

The owned x86-64 text probe completed on iPad after 76.607 seconds of memory
preparation. Screen dimensions/DPI were valid, but every tested font returned
failed/zero metrics and extents. FreeType dlopen was refused. The incremental
win32u.so copy lacked LC_RPATH: tools/build_windows_runtime.sh normally adds
@loader_path/../.. during packaging. Restoring this run path on our runtime
and re-signing it makes the same Mac probe return valid metrics without
DYLD_LIBRARY_PATH. The corrected physical fixture run is now preparing.
Incremental deployment must preserve/reapply packaging before signing; raw
make output is not a deployable equivalent of the assembled Wine runtime.
Evidence: /private/tmp/codex-gdi-text-ipad-missing-freetype.txt.

Physical font-fix verification: the same owned x86-64 probe completed after
76.373 seconds preparation/detachment, with no FreeType load failure and
valid font metrics, extents and ABC widths both with and without DIB backing.
Tahoma message height 13, Arial height 16; all tested calls succeeded. This
confirms the missing packaged run path caused the fixture's font failure.
Steam is now retried with the corrected runtime; its exhaustion cause and
end-to-end result remain unverified. Evidence: /private/tmp/codex-gdi-text-ipad-fixed.txt.

The corrected-font Steam run prepared/detached in 258.183 seconds but still
exhausted the same DC/region/font counts before rendering, with no FreeType
load failure. Therefore the packaging correction fixes the owned font probe
but is not sufficient for Steam. Bounded numeric font-request and text-metric
result counters are added to distinguish failed or unusual measurements in
Steam's API workload. No strings, caller code or stack contents are inspected.
Evidence: /private/tmp/codex-steam-fontfix-gdi-result.txt. The temporary log
collector now copies to a pending file and replaces the last capture only
after success, preventing a transient transfer failure from truncating it.

Steam's numeric metrics diagnostic prepared/detached in 256.913 seconds, then
reproduced GDI exhaustion. Repeated font requests sample height -13 while
measurements succeed with height 13/ascent 11. Valid metrics do not establish
that the requested font was selected. A bounded selection-return diagnostic
now also reports the requested face/height from Wine-owned font objects; it
does not read application strings or stack memory. Raw evidence:
/private/tmp/codex-steam-fontmetrics-result.txt.

The previous selection diagnostic's partial transfer was recovered on
2026-10-14 from `/private/tmp/codex-steam-single56-cap-native.txt.pending`
(run `steam-software56-ddf00b9104c54f8191f3bc86bf29c5f9`). This is a truncated
10,000,000-byte capture, not a complete final log. Its recorded samples show
successful font selection, including Tahoma at height -13, and successful
height-13 metrics before the same GDI capacity exhaustion. This does not support
failed font selection as the explanation. It still does not identify the
caller causing retained DC/font/region allocations. Do not repeat the identical
selection diagnostic merely because the completed-transfer file was stale.

### DirectWrite font collection failure and physical repair (2026-10-14)

The owned `testguest/windows/dwrite_font_probe.c` isolates DirectWrite factory,
system collection, family lookup, face/glyph creation and GDI interop. It builds
with -Wall -Wextra -Werror. The isolated Mac control passed (210 families), but
the physical iPad returned zero families and CreateFontFromLOGFONT 0x88985002.
Its copied system registry still pointed Tahoma and Arial to Mac-only
Z:\System\Library\Fonts\Supplemental paths. Working GDI metrics therefore
did not establish usable DirectWrite fonts.

The probe's explicit `--install-wine-fonts` mode registers only the two Wine
bundled Tahoma files after confirming they exist in Windows Fonts. Those files
were copied from the packaged Wine runtime into this Steam prefix; both font
registry keys now use local filenames. Existing other entries are preserved.
The original registry capture is retained locally. The physical retest passed:
one Tahoma family, a 988-glyph face, glyph 54 for S, valid metrics and successful
GDI interop. Raw evidence: /private/tmp/codex-dwrite-ipad-before.log,
/private/tmp/codex-dwrite-ipad-fixed.log, /private/tmp/codex-dwrite-ipad-system.reg.
The helper's default mode only observes; its install mode changes this prefix's
font registrations and must not be silently enabled for unrelated prefixes.

Chromium 126.0.6478.183 source supplies a plausible connection to the earlier
GDI exhaustion: PlatformFontSkia::InitFromDetails retries default initialization
if CreateSkTypeface fails; default initialization obtains the system font,
whose GetFontFromLOGFONT constructs another PlatformFont while its GDI objects
remain scoped. This is a source-derived hypothesis, not inspection of Steam's
code or proof of Valve's exact build. Sources:
https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/ui/gfx/platform_font_skia.cc
https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/ui/gfx/system_fonts_win.cc

A fresh Steam trial with the repaired private prefix and existing software56
profile has been launched. Its result is pending. The shared App Group prefix
used by future two-app Steam tests has not received this font repair. No Steam
binary was altered. A deployment fix must package/register portable font paths
rather than rely on the source Mac's font registry or claim this helper alone
makes Steam usable.

### First visible Steam sign-in window after portable fonts

Run `steam-dwrite-repaired-831eb99aae734d2eb0dd79751ec9ddd0` reached guest entry
with no GDI exhaustion in the captured startup prefix. Device Hub then showed
Steam's sign-in panel, empty text fields, button background, and a blurred QR
area with spinner. Text labels remained absent in a later screenshot. This is
visible rendering progress, not a usable signed-in client. Both font registry
keys were copied back and confirmed to persist the local Tahoma filenames.

Fresh-only CEF output (baseline file sizes captured before entry) reported
remote_font_face_source.cc:392. In matching Chromium source this is a missing
last-resort fallback font. The fallback implementation tries Sans, Arial and
additional Windows families; the probe established these families were missing
from the repaired one-family collection. Source:
https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/third_party/blink/renderer/core/css/remote_font_face_source.cc
https://chromium.googlesource.com/chromium/src/+/refs/tags/126.0.6478.183/third_party/blink/renderer/platform/fonts/skia/font_cache_skia.cc

The probe's explicit install mode now adds missing Wine Fonts/Replacements
entries for Arial, sans, Segoe UI and Microsoft Sans Serif using Tahoma. It
preserves any existing replacement value. Installation-mode validation requires
all four queried families to resolve, with actual face/glyph checks. The live
Steam trial was intentionally stopped to run this repair/validation, not
because a log-transfer error was treated as process death. A native-log copy
failed with a closed file-service socket; it cannot establish later absence
of errors. The fresh CEF log also contains network error 10045 and bootstrap
update-download failures, which remain to investigate independently.

The physical fallback repair passed: DirectWrite now exposes five families;
Tahoma, Arial, Segoe UI and sans each resolve to a working 988-glyph face,
with glyph lookup and GDI interop successful. These are deliberate Wine
replacement aliases, not newly installed distinct typefaces. Evidence:
/private/tmp/codex-dwrite-ipad-fallbacks.log. Steam has been relaunched with
these persistent prefix changes; label rendering and networking are pending.

The subsequent `steam-font-fallbacks` physical run rendered the Steam sign-in
screen with readable account/password labels, button text and help links.
The blurred QR spinner persisted, so successful authentication is not proven.
Fresh CEF output no longer included the observed last-resort-font NOTREACHED;
it still reported Winsock error 10045. The updater again failed all three
manifest download hosts with HTTP error 0. No credentials were entered.

`testguest/windows/http_transport_probe.c` now checks the public Steam update
manifest through DNS, nonblocking TCP/select and WinHTTP HTTP/HTTPS, without
credentials or certificate-validation exceptions. The Mac control passes:
connect completes through select and both HTTP modes return 200 with 64 bytes
read. The same owned probe has been launched against the iPad Steam prefix to
separate transport/TLS failures from Steam-specific behavior. Physical outcome
is pending; the visible Steam trial was intentionally stopped for this test.

The physical transport probe completed: DNS resolved, nonblocking connect
returned WSAEWOULDBLOCK as expected, select completed with SO_ERROR=0, and
plain HTTP returned 200 with 64 bytes. HTTPS failed with WinHTTP error 12157
(secure-channel error), zero status and no response bytes. Evidence:
/private/tmp/codex-http-ipad-initial.log. This narrows the owned probe's failure
to secure transport, but does not yet prove Steam's separate Winsock 10045
has the same cause. A fresh credential-free probe run enables Schannel,
Secur32 and WinHTTP diagnostics; certificate verification is unchanged.

The Schannel trace completed TLS negotiation but rejected the server certificate
with WinHTTP 12045 (invalid CA), surfaced as 12157. Wine called unimplemented
SecTrustSettingsCopyCertificates and SecItemExport adapters while importing
roots. The Security adapter now enumerates the existing native-trust-filtered
public system roots for domain 2 and exports certificate DER only. User/admin
trust domains, key export and unsupported export options remain unavailable.
No certificate-verification override is enabled. The ASan/UBSan regression
passed with 158 native-trusted candidates, matching native DER export and
rejecting unsupported queries; the physical iPad build succeeded. A fresh
physical HTTP/HTTPS validation is running; its outcome remains pending.

Physical run `http-trust-01bb7a8ceae9493dbae95214b467b5fa` passed DNS,
nonblocking TCP/select, HTTP and HTTPS against the public Steam manifest. Both
HTTP modes returned 200 and read 64 bytes; the probe exited 0. The adapter
reported 158 native-trusted public roots, and neither missing Security export
was logged as a stub. Certificate checks stayed enabled. Evidence:
/private/tmp/codex-http-ipad-trust-passed.log. This proves the owned WinHTTP
request, not Steam authentication or a Steam-managed game download.

The actual Steam run with the certificate adapters fetched manifest version
1791918634 (previously installed 1788652215), downloaded 112,630 KB and
reported update installation complete. Its automatic relaunch allocated a
second steam.exe slot, which failed its address-space setup and exited 1
(shared user data allocation c0000017). The updater download is real Steam
traffic, but is not a game download. Evidence: /private/tmp/codex-steam-trust-
delta-bootstrap_log.txt and /private/tmp/codex-steam-trust-native.log. A fresh
ordinary launch will test the installed update without the updater coexisting.

Fresh run `steam-updated-ab52c6d01b7f4b3d8c79bd697dde56e8` reached the updated client (1791918634).
Steam completed WebSocket connection setup, cleared its transient Waiting for
network screen, and visibly displayed readable sign-in fields and a populated
QR code in Device Hub. The CEF log still contains 10045, but it did not prevent
this sign-in state; do not treat that warning alone as a blocking failure.
Authentication awaits the user; game download and launch are unverified.
Evidence: /private/tmp/codex-steam-updated-delta-bootstrap_log.txt,
/private/tmp/codex-steam-updated-delta-cef_log.txt and the live device view.

After the user completed QR authentication, Steam reported LogOnResponse OK
and processing complete at 12:32:09 local time. It fetched 28 app metadata
updates and successfully wrote its 496-entry appinfo cache. Device Hub showed
the account loading screen; the library UI and game download remain unverified.
When ProcessProbe became foreground, the original Steam host was confirmed
alive and reactivated with the same PID (no restart). Its runtime log contains
repeated native-buffer EAGAIN reads (errno 35), flooding diagnostics rather
than proving a fatal I/O error. Suggested improvement: bound or sample these
expected nonblocking outcomes while retaining unexpected-error diagnostics.
Raw account-bearing logs remain private temporary files, not repository data.

Post-login UI diagnostics report LoginState Success, a completed library asset
queue, and ongoing browser callbacks, while the visible account-loading screen
persists. A reported 67,957 ms UI stall overlaps the user's accidental switch
to ProcessProbe; it is not a clean foreground performance measurement.
The native EAGAIN logging hot path is now suppressed for ordinary native
buffers only, preserving syscall return values and errno, software-buffer
errors and unexpected native errors. The software-VM ASan/UBSan regression
passes. This change is not yet installed in the authenticated device session;
no improvement in library loading is claimed.

The same signed-in run later reported SP Desktop WasHidden 0 and
UI.NotifyAppInitialized, but Device Hub displayed the Tolkara loading overlay.
This is evidence to investigate window presentation, not proof that the guest
failed library initialization. The reduced-I/O-log build succeeded. A controlled
restart now enables the existing --guest-window-covers-launcher option, keeping
the Steam prefix and app data. Baselines are saved under
/private/tmp/codex-steam-window-before-*. The visibility outcome is pending.

Source audit during the launcher-cover trial found that Wine's
WineWindow orderBelow:orAbove:activate: calls orderWindow:relativeTo: when
ordering a window against another visible window (cocoa_window.m around 1795).
Tolkara's NSWindow adapter currently has no implementation of this selector;
AKStubObject forwards it as an unimplemented no-op. This is a concrete API gap
consistent with missing main-window presentation, but the actual call must be
confirmed in diagnostics or reproduced with an owned multiwindow fixture.
NSApplication keyWindow/mainWindow also currently return the last-created
window, not the visible/key one. Do not equate browser WasHidden 0 with physical
presentation. The running cover-mode trial is not yet a verified fix.


On 2026-10-14 the quiet-I/O, launcher-cover trial still showed the launcher,
although Steam logged its main desktop as visible at 12:44:16 and created its
library browser. The native log now explicitly records the missing
`-[WineWindow orderWindow:relativeTo:]` call. The adapter implements that
operation, maintaining back-to-front ordering and fractional UIKit levels
below system UI, and excludes hidden windows from key/main lookup. The
simulator adapter suite passes, including relative ordering and reordering
existing windows. Physical presentation with this change remains to be tested;
this is not evidence of a completed game download or launch.

The physical ordering trial then reached guest entry and logged a successful
relative-order call (`number=38 mode=1 relative=24 visible=1`). At 12:54 the
iPad visibly showed the authenticated Steam desktop with Store, Library,
Community and Manage Downloads controls. The Store content area was black;
this verifies desktop presentation, not full browser functionality. The user
was asked to open Library and choose a small game for the next test, respecting
the repository input-automation restriction. No game download or launch has yet
been verified. The running session was preserved.


The user reported that taps had no effect on the displayed Steam desktop and
selected Vampire Survivors as the first game, followed by GTA V. The native
log explains a separate failure: hardwareupdater.exe entered slot 2, failed its
4 GiB small reservation, then Wine's mmap_init fallback reserved all remaining
host holes. The host reported 520159 MiB mapped and no free interval, followed
by UIKit NSMallocException; no mouse events reached the adapter. Wine's local
virtual.c now preserves host address space when a bounded reservation fails
under WINESINGLEPROCESS>=2, rather than taking the standalone-process fallback.
The ntdll.so build passes and is deployed for a fresh physical trial. This is a
runtime-source change; Steam binaries are unchanged. Physical outcome pending.

The fresh physical reservation trial hit the same bounded-reservation failure,
logged "preserving host address space", and the helper exited without an
NSMallocException in the observed log. Steam progressed to a rendered Friends
window. User tap validation remains pending. The focused source change is
saved in tools/wine-patches/experimental-bounded-reservation-failure.patch
(reverse-apply check passed). An ignored candidate profile excludes the optional
hardware updater via the existing WINENOSPAWN mechanism to preserve slot 2 for
Vampire Survivors; that candidate has not been deployed. The current session
is retained for input validation.

The user subsequently authorized interactive Steam taps through Device Hub.
The game-slot profile was deployed with the bounded-reservation fix and an
opt-in `--window-input-diagnostics` flag. Steam Library rendered its game list
and recent-game artwork on the physical iPad, visible after Home and selecting
the Steam window again. Selecting Vampire Survivors and typing in Library
search produced no visible response. Tolkara's own Diagnostics menu responds
to the same Device Hub clicks after stopping the test instance; this narrows
but does not yet identify the guest input failure. No game download is verified.

CoreDevice file transfers then failed for both the host and authorization app,
including after stopping Steam and refreshing Mac-side CoreDeviceService.
The saved runtime log has not been overwritten. A development-only
`--export-window-input-diagnostics` launch argument reads selected `[ak]`
input/window records from that saved file to stdout and exits before guest
loading. It avoids exporting Steam account/network records and provides a
console fallback for this file-service failure. The device build passes;
physical export validation is pending.

The console export was validated on the physical iPad: 120 allowlisted records
were recovered while file transfer remained unavailable. They confirm UIKit
hit-testing, paired mouse-down/up events for Library selections, and keyboard
events reaching AKHostView. The Friends overlay becomes hidden after its close
click. Thus Device Hub transport is working; downstream dispatch/guest handling
is the next diagnostic boundary. No cause is established yet.

A subsequent dispatch trial confirmed WineApplication/WineWindow/WineContentView
with an active NSApplication loop and one pending event at the first click.
Later Friends-close attempts were absent from that trial's UIKit event records,
so downstream event delivery is not yet a complete explanation. A new opt-in
`--defer-appkit-input` trial queues translated events until the outer AppKit
loop can drain them, rather than calling Wine from the UIKit input callback.
It is experimental and leaves default behavior unchanged. With
`--window-input-diagnostics`, selected input records are also mirrored to a
retained launch-console descriptor; arbitrary guest log text is not mirrored.
The updated device build passes; the deferred-input physical trial is running.

The deferred-input trial reached a rendered Friends overlay but did not improve
its response. Live console mirroring worked and showed the overlay visible
and non-key above a visible/key main window; attempted close presses produced
no UIKit input records. A separate opt-in `--frontmost-guest-input` trial now
makes an ordered-above guest window key and restores a visible guest key window
when that window is hidden. This is a diagnostic hypothesis about UIKit window
routing, not a verified fix. Deferred delivery is not enabled in that trial.

Physical iPad follow-up (2026-10-14, frontmost input trial): with `--frontmost-guest-input`, Friends window 45 became key; a Device Hub close click delivered down/up to WineContentView and hid it. Main window 38 became key. Subsequent Device Hub clicks opened Library and selected Vampire Survivors, visibly showing its selected row and loading page. This establishes interactive navigation in this run, not yet game download or launch. No deferred-input flag was used.
