# Windows applications: Wine and FEX under Tolkara

> Design and status for running a Windows x86 program on the iPad through
> Tolkara. First target: *Heroes of Might and Magic III: Horn of the Abyss*
> (GOG build, HotA 1.8.1 with the HD mod 5.8, a 32-bit x86 program),
> profile [`heroes3-hota`](../profiles/heroes3-hota). Each section says
> what is proven, where (Mac, simulator or iPad), and what is not.
>
> **Status, 2026-09-27: Heroes III with HotA plays on the iPad (M4 below,
> "On the iPad"),** with sound, mouse and keyboard.
> M0 was reached on the Mac the day before. A
> native arm64 Darwin process has no address space below 4 GB, and Wine's
> 32-bit side needs it ("The 4 GB floor" below). Tolkara's own branches of
> Wine and FEX work around it ("The downstream forks"): 64-bit programs run
> with `KUSER_SHARED_DATA` moved, and 32-bit programs run with their address
> space at a translated window ("The 32-bit window"). On the Mac, Heroes III
> (HotA 1.8.1 with the HD mod 5.8) reaches its main menu with music on
> Tolkara's arm64 Wine and FEX, no Rosetta involved ("The main menu,
> 2026-09-26 evening").

## The stack

Tolkara runs unmodified arm64 macOS executables. Wine is one: on macOS it is a
native arm64 program that maps Windows PE images and implements the Windows
API on top of the macOS one. Since Wine 10, a Wine built with the `arm64ec`
architecture runs x86-64 Windows code through an emulator module it loads into
the Windows process, and with `i386` and its WoW64 layer it runs 32-bit x86
code the same way. FEX provides those modules: `libarm64ecfex.dll` (x86-64)
and `libwow64fex.dll` (x86). They are PE files that depend only on `ntdll`,
so they work wherever Wine works. This is exactly the pairing Valve ships as
Proton for ARM64 (Steam Frame; Proton 11 with FEX-2604+, Wine 11 with full
WoW64), and the one CodeWeavers shipped in CrossOver's ARM64 preview for
Apple silicon in July 2026 after "making a custom version of FEX compatible
with macOS". Proton's contribution here is its Wine tree: it carries bylaws'
ARM64EC patch series and the loader that lets FEX bring a native `.so`
companion (`MemoryWineLoadUnixLibByName`). That tree targets Linux, though:
on macOS its fsync/ntsync, `win32u` OpenGL, `winedmo` and `bcrypt` changes
do not compile, and none of them matter on an iPad. So
[`tools/build_windows_runtime.sh`](../tools/build_windows_runtime.sh) builds
bylaws' `upstream-arm64ec` (upstream Wine plus the same ARM64EC/FEX series,
the tree FEX's own instructions name) and leaves Proton's tree selectable
with `WINE_REPO`/`WINE_BRANCH`.

```
  Heroes III (x86 Windows program, unchanged)
        │ Windows API, x86 instructions
  Wine PE side (arm64ec/i386 DLLs)  ──►  FEX libwow64fex.dll: x86 → arm64 JIT
        │ Wine's Unix ABI
  Wine Unix side (arm64 macOS: ntdll.so, win32u.so, winemac.drv.so, …)
        │ macOS API: libSystem, AppKit, CoreAudio, Vulkan (MoltenVK), …
  Tolkara runtime + translation (macOS → iPadOS)      ◄── this repository
        │
  iPadOS
```

Every layer above Tolkara exists and is maintained elsewhere. What this
repository has to add is the part Tolkara does not do today for *any* app:
Wine is not a single self-contained program the way a game is.

## The 4 GB floor (measured on macOS 27, the kernel iPadOS shares)

A native arm64 Darwin task's address space begins at 4 GB. Measured on this
Mac, 2026-09-25, with two small programs kept in the session notes:

- An arm64 executable linked with `-Wl,-pagezero_size,0x4000` (or `0x1000`,
  which ld rounds up) is killed at exec with `SIGKILL` before its first
  instruction. With the default 4 GB `__PAGEZERO` it runs, and Wine's own
  loader is built that way: configure's `-pagezero_size,0x1000` is silently
  ignored for arm64.
- Inside a running process, the low 4 GB is not a reservation that can be
  given back: `mach_vm_region` reports the first region at `0x100bdc000`;
  after `mach_vm_deallocate(task, 0, 4 GiB)` (which "succeeds"),
  `mach_vm_allocate(VM_FLAGS_FIXED)` at `0x400000` and `0x7ffe0000` return
  `KERN_INVALID_ADDRESS` and `mmap(MAP_FIXED)` at `0x10000000` returns
  `ENOMEM`. The same holds for an x86_64 binary under Rosetta with the default
  page zero; Rosetta's small-`__PAGEZERO` x86_64 processes are the only ones
  that get low memory, which is how Wine has worked on Apple silicon so far.
- Wine's `wineboot` under the arm64 runtime therefore stops in
  `virtual_alloc_first_teb`: "failed to map the shared user data" at
  `0x7ffe0000` (`WINELOADERNOEXEC=1` to see it; the normal path re-execs and
  the re-exec'd process dies without output). Upstream's `configure.ac` sets
  no preloader and no reservation segments for `aarch64` on Darwin: nobody
  has made this work in public yet.

What it means for the two kinds of Windows program:

- **32-bit x86 (Heroes III, the HD mod, HotA).** Wine's WoW64 layer keeps
  the 32-bit process's address space in the low 4 GB of the 64-bit process,
  and FEX's `libwow64fex.dll` runs the guest with guest addresses equal to
  host addresses (bylaws' Wine series even forces every host allocation out
  of the 32-bit range to keep it free for the guest). With no memory below
  4 GB there is no 32-bit address space to give. Running such a program on
  arm64 Darwin needs a 32-bit guest at a translated base address, which
  upstream FEX does not have; QEMU's user mode has that (`guest_base`) but
  no Darwin host. Tolkara's FEX branch adds it ("The 32-bit window" below).
- **64-bit x86.** The guest's own allocations live above 4 GB anyway. What
  sits below is `KUSER_SHARED_DATA` at `0x7ffe0000`, which Wine maps at that
  address because Windows programs read it there directly. Wine's ARM64EC
  code reaches it through a pointer and could map it anywhere; x86-64 guest
  code that hardcodes the address would have to be caught by FEX. CrossOver's
  ARM64 preview on macOS runs 64-bit programs, so CodeWeavers have done this
  in their unpublished FEX and Wine changes; it is a bounded patch.

On the iPad the floor is the same kernel rule, so nothing Tolkara does can
lift it; the arena Tolkara prepares also lives above 4 GB. With upstream FEX
this profile cannot reach M0; it depends on the 32-bit window in Tolkara's
Wine and FEX branches ("The 32-bit window" below), and with those the
milestones apply to this 32-bit game as well as to 64-bit programs. The
alternatives for this particular game are in "Working rules".

### The downstream forks

Decided 2026-09-26: Tolkara carries its own branches of Wine and FEX for
arm64 Darwin, in this order: first the 64-bit path (relocate
`KUSER_SHARED_DATA`, which also validates FEX's JIT on 16 KiB pages and
without TSO with a 64-bit program), then the 32-bit window (a translated
base in FEX's 32-bit JIT and a movable WoW64 address range in Wine).

Both projects refuse code written with LLM tools (FEX's `CONTRIBUTING.md`:
"No AI/ML/LLM/etc code contributions."; Wine's Clean Room Guidelines: "Don't
use an LLM tool to generate code."). The changes on Tolkara's branches were
written that way, so they are **downstream only and will not be submitted
upstream**; each fork says so in its `TOLKARA-FORK.md`. They keep each
project's coding style and one-change-per-commit convention so that they
stay reviewable and rebaseable, not to prepare them for upstream. Should
either project publish its own arm64 Darwin work, Tolkara moves to it.

Both branches are published, as `tolkara/darwin-arm64` in
[tolkara/wine](https://github.com/tolkara/wine) and
[tolkara/FEX](https://github.com/tolkara/FEX);
[profiles/heroes3-hota/README.md](../profiles/heroes3-hota/README.md) says
how to build the runtime from them.

The Wine branch is `tolkara/darwin-arm64` on bylaws' `upstream-arm64ec`;
`tools/build_windows_runtime.sh` builds whatever is checked out in
`build/windows-runtime/src/wine`. Its first commits, and what each fixed:

- `configure`: the arm64 loader keeps the 4 GB page zero. Configure's macOS
  flags asked for a 4 KiB one, the linker obliged for `loader/wine`, and the
  kernel killed every re-exec of it at exec time (the silent `SIGKILL` seen
  at first).
- `ntdll`: the address space starts at 4 GB on arm64 macOS; the
  `KUSER_SHARED_DATA` page and the TEB block fall back to where the host can
  put them; the PE side asks the Unix side for the page's address
  (`unix_get_user_shared_data`) and other modules read it through
  `__wine_get_user_shared_data()` instead of hardcoding `0x7ffe0000`
  (`kernelbase`, `kernel32`, `ntoskrnl.exe`).

Three more Darwin rules surfaced while bringing `wineboot` up, each measured
with a small C program and each now handled on the Wine branch:

- **No W+X memory, ever.** `mmap`/`mach_vm_map` with write and execute
  together fail (`EPERM`) for anonymous and file mappings alike; only
  `MAP_JIT` gives both, and then a thread has *either* write or execute
  access, toggled with `pthread_jit_write_protect_np`, starting
  write-protected. RW→RX `mprotect` is allowed. So Wine maps a PE image RW,
  copies it in, and gives each section its final protection (`ntdll`
  `map_image_view`). A JIT (FEX's code buffers) has to be `MAP_JIT` plus the
  toggle; see "The JIT pool" below for what the kernel allows there and how
  the Wine branch serves it.
- **Protection faults arrive as `SIGBUS`, `si_code 1`,** the same code as
  alignment faults; the ESR in the signal context tells them apart
  (`DFSC 0x21` is alignment). Wine's arm64 `bus_handler` treated every
  `SIGBUS` as `STATUS_DATATYPE_MISALIGNMENT`, so guard-page hits and access
  violations were never handled; it now classifies by ESR.
- **`x18` is not preserved.** It survives a fast syscall but is zeroed by
  any context switch and by every return from a signal handler (the
  handler's `ucontext` still shows it). Windows ARM64 keeps the TEB in
  `x18`, so PE code and Wine's dispatchers cannot rely on it here.
  `TPIDR_EL0` is user-writable but the kernel reuses it (CPU number), and
  `TPIDRRO_EL0` is read-only and points at the thread's pthread TSD array.
  The TEB therefore lives in TSD slot 767 (`0x17f8` from `TPIDRRO_EL0`, above
  the keys `pthread_key_create` hands out from 258): `NtCurrentTeb()` in PE
  code compiled for this host is `mrs`+`ldr` (`-D__WINE_TEB_TSD_OFFSET`),
  the five PE assembly sites that read the PEB through `x18` use the same
  sequence, and both dispatchers reload `x18` from the slot on entry from
  PE code. Native ARM64 Windows *applications* would still break; x86
  programs under FEX never touch `x18`, and FEX's own Windows code gets the
  same `NtCurrentTeb()` treatment in its fork.

A fourth rule closed the last gap for `wineboot`: **Apple's arm64 ABI packs
stack arguments at their natural alignment** (a `ULONG` tenth argument sits
four bytes into the ninth's slot), while the syscall dispatcher copies the
PE caller's arguments as the Windows ABI lays them out, one 8-byte slot
each. Every system call with more than eight arguments (25 of them) got a
wrong tenth argument. On Darwin the syscall table now points at generated
wrappers (`tools/make_darwin_syscalls`, `dlls/ntdll/unix/syscall_darwin.h`)
whose stack parameters are all `ULONG_PTR`.

### The JIT pool

FEX asks Wine for its code buffers with `NtAllocateVirtualMemoryEx`,
`PAGE_EXECUTE_READWRITE` and the `MEM_EXTENDED_PARAMETER_EC_CODE` attribute
(so that the EC bitmap marks them as native code), then writes and runs
them continuously and re-protects pieces (a guard page at the end of each
buffer). What `MAP_JIT` memory allows on this kernel, each point measured
with a small program on 2026-09-26:

- A `MAP_JIT` mapping can only be placed where the kernel chooses:
  `MAP_JIT|MAP_FIXED` is `EINVAL` even into a hole that was just
  deallocated. A pool therefore has to be reserved once, up front.
- Reserving it `PROT_NONE` is fine; every `mprotect` transition on its
  pages is allowed *except leaving read-write-execute* (`EACCES`, also
  through `mach_vm_protect`). Once a page has been RWX it stays RWX.
- `madvise(MADV_FREE_REUSABLE)` works on the pages, `MADV_ZERO` does not
  (`EPERM`); `mach_vm_map` with `VM_FLAGS_FIXED` over them fails, so Wine's
  own address-space reservations cannot clobber the pool.
- The write/execute switch is per thread, in user mode
  (`pthread_jit_write_protect_np` is an `msr` on a commpage-provided value),
  survives syscalls and context switches, and new threads start executable.
- **A signal handler always runs with the pages executable, and after it
  returns the thread is writable whenever it was writable before the signal
  or the handler left it so.** A handler can switch a thread to writable;
  it can never switch it back to executable.

The Wine branch (`ntdll`, two commits) serves those requests from a pool
reserved in `virtual_init` (4 GB by default; `WINEJITPOOL` gives the size in
megabytes, or `start-end` names a region the host mapped already, which is
how Tolkara will hand over arena memory on the iPad). Views get a
`VPROT_JIT` flag and are placed by walking the view tree inside the pool;
in an ARM64EC process only EC-code allocations qualify, because RWX memory
that x86 code asks for is never executed natively. The pool is never
unmapped: freed or decommitted pages are zeroed and advised away, and a
protection change the kernel refuses is kept in Wine's page tables only.
Outside the pool the executable bit is dropped from writable mappings as
before. Faults do the switching: a write fault on a committed RWX pool page
turns the thread writable inside the handler; an execute fault parks the
full register state on the thread's stack and points the thread at a
16-byte routine in `ntdll.so` that calls `pthread_jit_write_protect_np(1)`
and traps, and the `SIGTRAP` handler restores the parked state. A block
compile thus costs three signals; FEX switching explicitly (it has a
Windows-to-Unix bridge, `FEXUnixLib`, and Wine can export a call) is the
optimisation for later, with the fault path as the safety net.

The FEX branch needed one more change for this to run: its dispatcher still
read the TEB through `x18` in three emitted sequences (the EC bitmap check,
the syscall-callback flag, the SRA spill path), which worked until the
first return from a signal handler zeroed `x18` in the middle of the
dispatcher; all TEB reads now go through one `LoadTEB` helper.

**State of the branches, 2026-09-26 (Wine: 14 commits on
`upstream-arm64ec`; FEX: 3 on main):** `wineboot -u` creates a complete
prefix on this Mac in 73 s, Wine's own `notepad.exe` (ARM64EC) runs with a
window, and **an x86-64 Windows program runs under FEX**: a hello program
prints, loops 50 million iterations in 110 ms and exits with its return
code, and
[`testguest/windows/shared_data_probe.c`](../testguest/windows/shared_data_probe.c)
reads the relocated `KUSER_SHARED_DATA` correctly through the API
(`GetTickCount64`, `QueryPerformanceCounter` at 10 MHz,
`GetSystemTimeAsFileTime`, a `Sleep(15)` measured as 17–25 ms), and its
direct read of `0x7ffe0320` inside `__try` is caught as
`EXCEPTION_ACCESS_VIOLATION` by the program's own handler, delivered
through Wine's ARM64EC `ntdll` and FEX's context reconstruction (a
`RaiseException` inside `__try` unwinds correctly too). One false alarm on
the way: clang's `__try` covers calls, not a plain load that faults (the
`-fasync-exceptions` flag is a no-op for the mingw target), so the probe
reads through a non-inlined function. Two conclusions for the game: a
program that hardcodes `0x7ffe0000` faults here, so FEX or Wine would have
to catch and emulate such reads if HotA or the HD mod do that; and x86
structured exception handling works under this stack.
Remaining noise: FreeType, GnuTLS and SDL2 are `dlopen`ed by bare soname and
not found in the bundled runtime (configure should record `@rpath` sonames
and the build script bundle them); no Vulkan (MoltenVK) yet.

### Vulkan graphics (development, 2026-10-02)

Wine can load a builder-supplied macOS MoltenVK library using the configure
cache setting `ac_cv_lib_soname_MoltenVK=@rpath/libMoltenVK.dylib`. Bundle that
library in `Wine/lib`, add `@loader_path/../..` to the rebuilt Unix bridge
libraries, and sign the runtime libraries again. A Windows game may need a
Direct3D translator such as DXVK's macOS fork: forcing Unity's Vulkan renderer
does not help when the game's shipped build has only Direct3D shaders.

For Tolkara, set `TOLKARA_VULKAN_RUNTIME` to the **native iOS** MoltenVK framework
binary, or its **iOS simulator** binary when building for the simulator.
`tools/embed_vulkan_runtime.py` checks the arm64 platform and Metal surface
exports, bundles it as `aklibMoltenVK.dylib`, and maps Wine's dlopen name to that
native backend. Generic builds discover it by adapter name. It is signed with
Tolkara's compatibility libraries; the macOS MoltenVK library remains outside
the app. Retain MoltenVK's supplied licence when distributing a build.

The downstream Wine driver accepts the Metal surface extension without requiring
the deprecated macOS-only surface extension, which iOS MoltenVK does not export.
On the Mac, MegaBonk's unchanged Steam Windows build now initializes Direct3D 11
and creates a Metal-backed swap chain through Wine/FEX, DXVK macOS and MoltenVK.
Gameplay and physical iPad graphics remain unverified.

The same downstream Wine build passes our original offscreen Direct3D 11
fixture on the Mac with `WINESINGLEPROCESS=1`, `WINEJITPOOL=dual:256` and
`FEX_MAXCODEBUFFERSIZE=24`: compile vertex and pixel shaders, draw a triangle,
then verify every pixel in a 16×16 staging readback. This exercises real GPU
rendering without game code or automated input. Hybrid ARM64EC/ARM64X image
code must be placed in the executable pool, and ARM64X relocation writes must
use its writable alias. A separate 32-bit parent/child fixture verifies image
name pointer conversion, inherited environment and child exit status.

Tolkara's iOS 27 simulator now loads the native simulator MoltenVK backend and
passes the x86-64 startup and public Vulkan capability fixtures. Its Apple2
GPU reports no BC compression, precise occlusion queries, multiple viewports,
cube arrays or indirect draws with a nonzero base instance. DXVK rejects the
Direct3D feature levels requested by the game. This matches Apple's documented
[simulator GPU limits](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator).
It does not establish what the physical iPad's GPU supports; that needs a
separate device test.

On 2026-10-03 the standalone window fixture exposed another single-process
issue: a server-created desktop belongs to the current process but has no
client-side `WND`, so `NtUserGetAncestor(GA_ROOT)` failed while traversing it.
The Wine fork now recognizes that desktop as `WND_DESKTOP`. The fixture passes
root and child ancestry, invalid-handle rejection, swap-chain presentation and
all readback pixels both in a standalone single-process session and in normal
Wine mode. MegaBonk then creates its Metal swap chain and loads its assets with
the aliased executable pool enabled. Visible gameplay remains unverified.
An original Win32-only fixture also passes top-level and child ancestry and
invalid-handle rejection with this fix under Tolkara's iOS simulator.

On 2026-10-06, the physical M5 iPad passes the original Vulkan capability,
Direct3D 11 shader/triangle/readback, visible-window and 40-thread allocation
fixtures. FEX's allocator now requests aligned virtual spans directly, and
omits the 256 MiB L2 reservation when that cache is disabled. MegaBonk runs
with a 4 GiB Wine reservation and two Unity job workers. AppKit inserts Wine's
Metal child view into the layer tree and honors its resizing mask. AudioUnit
resolves the output adapter before its native reexport; output callbacks carry
nonzero samples without errors. The user confirms a playable run, with a camera
mouse problem. The installed confinement/recentering fix passes our original
UIKit input fixtures. An original physical Wine cursor fixture now verifies
that pointer lock activates, repeated recentering returns exact positions,
and release unlocks the pointer without failed warp errors. The missing
`convertRectFromScreen:` implementation had prevented confinement from
activating. Manual camera feel validation remains pending.

The native Steam Cloud client uses the user's approved Steam session over TLS,
with the remembered login in the iPad Keychain. It imports three genuine saves
before guest entry. After the user's run, the iPad uploaded both changed saves;
an independent authenticated download matches all three iPad files byte for
byte. Synchronization runs before launch, every minute during play, and on clean
exit. Final synchronization passes through an original physical Wine fixture:
the exit observer runs once, all three saves are verified, and completion is
logged before process shutdown. The coordinator keeps the main event loop
responsive while waiting. Embedded wineserver must not schedule SIGKILL against
its shared native host when the logical Windows process exits; the fork now
marks that process dead without killing the host. An original Mac exit fixture
also survives three seconds of host finalization. Force-close or crash skips the
final attempt; pending saves are checked on the next launch. The final attempt
runs when the game calls `exit`, before its `atexit` handlers and destructors:
a save written only there is uploaded at the next launch.
The first synchronization pulls and backs up local files. Later syncs
compare both sides against verified hashes, preserve conflicts, and defer
remote replacement while the game is running. This is independent of the
Windows Steam client's login; it does not supply a pretend Steam identity to
the game. The game currently saves under its working directory's
`Saves/CloudDir/0`; the configured remote path uses the authenticated account.
Full sanitizer and UIKit fixture suites pass. The simulator's feature limits
remain as described above.

### The 32-bit window (design, 2026-09-26)

The kernel rule behind the 4 GB floor is explicit in XNU's Mach-O loader
(`bsd/kern/mach_loader.c`, `load_machfile`): every 64-bit `CPU_TYPE_ARM64`
binary must have a hard page zero of 4 GB, the check has no bypass (the
compatibility clause covers 32-bit non-PIE apps only, and only Rosetta
processes are exempt), and the map's minimum offset is committed at exec.
So the identity-mapped 32-bit address space that Windows-on-ARM's WoW64 and
FEX's 32-bit JIT assume cannot exist here, on the Mac or the iPad. HotA and
the HD mod are 32-bit; they need a translated window.

The window is 4 GB of host address space at a 4 GB-aligned base `W`
(chosen at startup from Wine's reserved areas, above the loader, the
shared cache and the JIT pool). A 32-bit guest address `g` lives at host
address `W | g`, so **the guest address is the low half of the host
address**: converting host to guest is truncation, which is what Wine's
WoW64 layer already does everywhere (`PtrToUlong`, `put_addr`), and only
the widening direction (`ULongToPtr`, `get_ptr`, `addr_32to64`) has to
learn about `W`. Any 32-bit structure's host address gives `W` (the
32-bit PEB, the 32-bit TEB), so no new interface carries it.

*Wine, Unix side (`ntdll`):* reserve the window in every 64-bit process
(4 GB of address space costs nothing) the way the Linux preloader range is
treated: ordinary allocations avoid it, allocations bounded inside it
are served from it. A request with a 32-bit bound (`zero_bits`, the WoW64
user-space limit, a 32-bit image's preferred base) is shifted by `W`;
the TEB block, whose 32-bit TEBs must be guest-addressable, goes there
too; the `KUSER_SHARED_DATA` section is mapped a second time at
`W | 0x7ffe0000`, so a 32-bit program that hardcodes the address works
(the 64-bit relocation stays for ARM64EC and x86-64 code). The Unix side
touches 32-bit pointers in a dozen places (the i386 exception, APC and
callback frames it builds on the guest stack, the 32-bit PEB); those use
one `wow64_ptr()` helper.

*Wine, PE side:* `wow64.dll` and `wow64win.dll` convert every argument
through `get_ptr`/`ULongToPtr`/`addr_32to64` from their private headers,
about a thousand sites through three helpers; the headers redefine the
widening helpers with `W` (from the 32-bit PEB the module already holds).
The aarch64 `ntdll.dll` has a few dozen WoW64 conversions of its own to
review one by one.

*FEX (`libwow64fex.dll`):* the JIT keeps guest semantics in its IR (every
address is a 32-bit guest address, segment bases are guest values) and
maps to host addresses at the last step: in 32-bit mode a reserved host
register holds `W`, and each memory operation forms its address with one
`add Xt, Xw, Wn, uxtw` before the load or store, which also keeps the
unaligned-access backpatcher looking at a plain register operand. The
C++ side gets a `GuestToHost` helper for the places that read guest
memory directly: the frontend's instruction fetch, the syscall bridge
that reads the guest stack, and the WoW64 module's use of 32-bit
pointers; host addresses that arrive from Wine (memory notifications,
fault addresses, image bases) are truncated to guest addresses for the
invalidation and image trackers. Windows' own 4 KiB page semantics for
32-bit programs are already emulated by Wine's page tables on this 16 KiB
host, and FEX's trackers work in 4 KiB guest pages.

**Result, 2026-09-26: 32-bit x86 programs run.** Wine's branch (four
more commits: the window and its allocation rules in `ntdll`, the WoW64
widening in `wow64`/`wow64win`, host addresses for the NLS tables the
32-bit `ntdll` hands the 64-bit PEB, and symbolized fault traces) and FEX's
(`FEX_GUEST_ADDRESS_WINDOW`, built into `libwow64fex.dll` only; the
ARM64EC module's register set has no room and runs only 64-bit guests) get
a WoW64 process from the 32-bit `ntdll` through `kernel32`, `user32`,
`setupapi` and `rundll32`: the prefix's `syswow64` fake DLLs (833 files)
were installed by the 32-bit `rundll32 setupapi,InstallHinfSection
Wow64Install` running under FEX, a 32-bit hello program prints and returns
its exit code, and
[`testguest/windows/window32_probe.c`](../testguest/windows/window32_probe.c),
a freestanding 32-bit program that needs no DLL, passes its twelve checks
(loads, stores, a `strcmp` binary search, `rep movsb`/`stosb`, 64-bit
arithmetic, deep calls, `push`/`pop`, `fs:` TEB reads, `lock xadd`).

Things learned on the way, each now handled on the branches: the shared
cache and a kernel reservation occupy nearly everything between 4 GB and
448 GB, so Wine reserves the first TB of holes rather than 64 GB and the
window sits at 448 GB; a 32-bit main image is never at its preferred base
here, so `STATUS_IMAGE_NOT_AT_BASE` must count as success or every 32-bit
program takes a detour through `start.exe`; the WoW64 thunks compared
widened host addresses against the 32-bit user space limit (the first
`NtQueryVirtualMemory` from the 32-bit loader failed on that, leaving its
`ntdll` module entry with base 0); arguments that are values, not
addresses (`NtContinueEx`'s alertable flag, APC parameters) must not be
widened; and the 32-bit `ntdll` writes its NLS table pointers into the
64-bit PEB, where `win32u` dereferences them. A prefix whose `syswow64` is
empty (one created before the window worked) is repaired by `wineboot -u`
run with `WINEBOOTSTRAPMODE=1`, which is what lets the 32-bit installer be
found as a builtin without a fake file; a fresh prefix gets it at creation.

Still open on this path: FEX's `MonoBackpatcherWrite` and the
gather-without-base loads translate only the base register; a fault on a
64-bit process's `0x7ffe0000` read stays as before; each block compile
still costs the three signals of the JIT pool.

**The game, 2026-09-26 afternoon.** `h3hota HD.exe` now runs its whole
start-up under the window without a guest crash: the HD mod's patcher and
its `HD_*` libraries, HotA, `opengl32`, the Miles and Bink libraries,
Galaxy and the Discord library load and initialize, and worker threads
run. Five more fixes got it there, six commits across the two branches:

- FEX's x87 stack pass read and wrote the x87 register file through a host
  address it formed from the CPU state, and under the window every memory
  operation's address is taken as a guest address, so the game's first x87
  code faulted. The pass now uses the context-relative indexed loads and
  stores (FEX).
- The Unix side of every builtin (`opengl32.so`, `win32u.so`, …) widened
  guest pointers with the identity `ULongToPtr`; `unixlib.h` now routes it
  through `ntdll_wow64_ptr` (Wine).
- A 32-bit request bounded below 4 GB with no lower limit was shifted to
  the window base itself, so one allocation landed at guest address 0 and
  the guest saw `VirtualAlloc` return NULL: HotA then built a hook bridge
  around a NULL routine and jumped to 0. Such requests now start at 64k, as
  on Windows (Wine).
- FEXCore hands guest addresses to the WoW64 module's executable-range
  hooks, whose tracker is host-addressed, and the decoder derived the
  "RIP" it range-checks from the host pointer; valid guest code was
  declared non-executable or the decoder looped (FEX, two commits).
- **16K host pages defeat 4K guard pages.** Wine gives a host page the
  most permissive protection of the 4K pages in it, so FEX's 4K guards
  around the call-return stack and at the end of its JIT buffers never
  trapped; the call-return stack ran 24 MB past its region and overwrote
  other memory. The fork sizes those guards at 16K. Any guard-page scheme
  on this host needs the same care.

Where it stopped then: after start-up the main thread ran at full CPU in a
loop through `win32u` menu calls and never created the game window.

**The main menu, 2026-09-26 evening.** `h3hota HD.exe` reaches the HotA
main menu on the Mac with music and the system cursor, on the arm64
runtime (fifteen more commits: twelve on the Wine branch, three on FEX's).
What stood in the way, in the order it showed up:

- *No 32-bit window could be created.* `winemac.drv`'s Unix side read the
  localized menu strings through 64-bit parameter fields the 32-bit side
  fills with zero-extended pointers, so the driver's init faulted in every
  WoW64 process and top-level windows fell back to the null driver.
- *Every user handle the game created was invalid.* A program without the
  NX compatibility flag makes ntdll add `PROT_EXEC` to every host mapping;
  macOS refuses that for shared file mappings, and ntdll then read them in
  as private copies. The session's shared memory (where win32u looks up
  user handles) became a snapshot of the moment it was mapped, so menus the
  game had just created were "invalid" and it looped on them. Emulated code
  never needs host execute permission; the branch no longer forces it.
- *Widening, round two.* Values are not addresses: atoms and resource ids
  (below 64k), window procedure handles and -1 (the top 64k, which a large
  address aware 32-bit process no longer gets, as on Windows), `opengl32`
  handles and `GLintptr`/`GLsizeiptr` values stay as they are. Addresses
  that were missed are now widened: the pointer arguments of
  `NtUserCallOneParam`/`TwoParam`/`HwndParam` codes and of messages
  (following win32u's own list of messages that carry pointers), socket
  ioctl buffers, `opengl32`'s pointer arrays; and `NtMapViewOfSection`
  checks a fixed 32-bit view address against its 32-bit bounds (DirectPlay
  maps its shared data at `0x50000000`).
- *Deadlocks under FEX.* `rpmalloc`, FEX's heap, tells threads apart by
  `NtCurrentTeb()`, which mingw reads from `x18`; after any preemption or
  signal return a thread saw itself as "another thread", pushed its own
  blocks onto its deferred free list and spun there holding FEX's code
  cache locks. The FEX branch force-includes the TSD-slot `NtCurrentTeb()`
  into rpmalloc. Separately, Wine now honours FEX's suspend doorbell for
  WoW64 threads (it did so only for ARM64EC), so a thread suspended by the
  game is parked at a consistent point rather than inside a compile.
- *Two more window translation slips in FEX's JIT.* `MemSet` (`rep stos`)
  formed the updated `EDI` from the translated host address, and a segment
  register load (`pop es`, Miles' mixer does it) looked its descriptor up
  through a host pointer taken for a guest address; descriptors now live in
  the CPU state and are read with a context-relative load.
- *16 KiB pages once more.* Decommitting pages that share a host page with
  committed ones left their contents in place; programs rely on recommitted
  memory being zero (rpmalloc hands it out for `calloc`). Those pages are
  now zeroed.

The staged copy sets two HD mod options (`profiles/heroes3-hota/install.py`,
`hota.ini`): no update check at start (it offers to replace the game's own
libraries and runs its installer as a second process) and renderer mode 2,
which draws through GDI. The mod's automatic choice, its OpenGL renderer,
presents frames but uploads them empty under this runtime (the same game
under x86-64 Wine and Rosetta shows the menu that way), which is still to
be explained; GDI suits the iPad anyway, which has no OpenGL. FreeType and
GnuTLS are now bundled with the runtime and opened by `@rpath` name; the
menu shows with nothing from Homebrew on the library search path. Wine's
Unix-side libraries have header room for one more `LC_RPATH` only, and
dyld refuses a library that names the same run path twice, which silently
takes `winemac.drv` (no window) and `mountmgr` down with it.

Still open on the Mac: the OpenGL renderer's empty frames; `winemac.drv`
gives ordinary windows a squashed client area on this macOS (a 400x300
window shows 392x63, 64-bit programs too; the HD mod's windowed mode is
affected); the game pauses while it is not the active Mac application, as
on Windows, so runs started from a terminal show nothing until the window
is clicked; performance is unmeasured. In the FEX branch, libc++abi's exception
globals still read `x18`; a fourth FEX commit translates emulated vector
gathers through the window (the game does not use them).

## On the iPad (2026-09-27)

The same runtime, prefix and game run on an iPad Pro 11-inch (M5), iPadOS
27, Developer service: `h3hota HD.exe` reaches the HotA main menu, drawn
through the HD mod's GDI renderer into a full-screen window of 1210x834
points, the lightning over the menu animating. What it took, beyond M0:

- *One process* (W4, `WINESINGLEPROCESS=1`): `wineserver` is built a second
  time as `bin/wineserver.so` and runs as a thread of the game's process
  (per-thread working directories, its socket under the prefix's
  `.wineserver`, the registry flushed at exit, volatile keys such as the
  CPU description kept in `volatile.reg` because `wineboot` never runs
  there); `win32u` loads the display driver itself instead of asking
  `explorer`; `CreateProcess` is refused.
- *A code pool* (W2, profile key `codePool`): the prepared arena gets 96 MB
  after the images; the launcher hands it to Wine as
  `WINEJITPOOL=start-end@alias`. Its executable view never changes
  protection: Wine and FEX write code through the writable alias, native
  ARM64 PE modules are placed and relocated there, and memory outside the
  pool is never made executable on the host (a page that was executable
  cannot become writable again on iOS; the emulator only reads 32-bit
  code). `WINEJITPOOL=dual:<MB>` makes such a pool on the Mac, where the
  menu shows the same way. Preparing the arena, 110 MB with the images,
  takes 33 s at each launch.
- *Wine's Unix libraries placed at startup* (W3, profile key `libraries`):
  `ntdll.so`, the server, `win32u.so`, `winemac.so` and the rest are placed
  by the loader like an application's own libraries, and `dlopen` by path
  finds them.
- *AppKit on UIKit for `winemac.drv`* (W5): panels, tracking areas,
  frame/content rectangles, `updateLayer` drawing, layers anchored and
  scaled as AppKit's, window ordering that does not re-enter Wine's
  overrides, colours and bitmap graphics contexts, display gamma and
  capture calls, `SessionGetInfo`, input-source types.
- *The simulator first*: the whole stack runs in the iOS Simulator
  (`--case-insensitive-files` covers `fstatat`; the simulator needs no
  helper to prepare memory), which is where the AppKit gaps were found. The
  simulator is portrait-only from the command line; the HD mod's scaler
  draws a portrait desktop with stale patches, which the landscape iPad
  does not show.

Two failures were the device's own: the in-process server looked for its
NLS files next to the host executable (the simulator could read the Mac
build's absolute data path), and `smackw32.dll`'s code became
non-executable to FEX after its relocation failed to make the page writable
again. Both are fixed on the Wine branch.

Later that morning the game itself ran on the iPad: a scenario started and
played with sound, mouse and keyboard, after fixes on both branches and in
the adapters. Wine now tells FEX when a program turns data execution
prevention off, and FEX leaves a block on a write to translated code only
when the write reaches that block's own bytes (it re-ran a `pop` to memory
in the HD mod's hook bridges). Clicks needed Quartz events on AppKit's
events and window numbers, sound an AudioUnit adapter and the session's
route as CoreAudio's output device, saves the game's empty `games` folder
on the iPad, and the keyboard has Option as Alt and Command ignored.

FEX grows its code buffer by doubling up to 128 MB, and each new buffer has
to fit in the code pool beside the one being replaced (and any a thread that
has not run since still holds). A game with eight players hung on the iPad
when its AI turns filled a 64 MB buffer and the next one did not fit in the
96 MB pool; the FEX branch caps the buffer (`FEX_MAXCODEBUFFERSIZE`, in MB),
and the profile sets 24, so that three buffers and the native modules fit.
A full buffer at the cap is replaced by a new one of the same size.

Still open: a double click is not recognised on the iPad (it is on the Mac),
modifier tracking after Alt and a click awaits a test on the device, the
light grey margins around the game when the HD mod letterboxes it, GnuTLS
(not in the device runtime), and performance.

## What Wine needs from its host, and what Tolkara has

| Wine needs | Tolkara today | Work item |
| --- | --- | --- |
| A command line and environment for the runtime (`wine "h3hota HD.exe"`, `WINEPREFIX`) | Profiles named only an executable and a folder | **W1, done on this branch.** Profiles may name a `runtime`, `arguments` and `environment` ([profiles/README.md](../profiles/README.md)); the launcher sets the variables and passes `argv`. |
| Executable memory it allocates itself: PE images mapped from files (`NtMapViewOfSection`), and FEX's code buffers, written and executed continuously | One arena, prepared once before any application code runs; `mmap(PROT_EXEC)` outside it goes to the host and is not executable; `pthread_jit_write_protect_np` is a no-op. Developer service arenas go up to 512 MiB at about 3.3 MB/s of preparation on an iPad Pro M5 (Heroes III's 110 MB in 33 s; 1.1 MB/s before the helper wrote one byte per page); `nc_create_managed` accepts up to `NC_MAX_ARENA` (1 GiB) or what memory allows (`nc_launch_limit`). A third mode, External JIT (`runtime/DebuggerArena.c`, TolkaraDiagnostics only, untested on a device), has a sideloading tool's debugger allocate the region on request before detaching. | **W2, measured (M1 below): only prepared memory executes.** So the arena must be over-provisioned at startup with a JIT pool, and `guest_mmap`/`guest_mprotect` serve `PROT_EXEC` requests from it: an RW alias for writes (as `NativeCodeMemory` already does) and the RX view for execution; the PE side's `PAGE_EXECUTE_READWRITE` becomes that pair. Wine's PE images plus FEX's code cache must fit a budget of a few hundred MiB, prepared at the rate above; a file-backed PE mapping is copied in rather than mapped. External JIT may suit the pool if a device confirms it. `--jit-probe` overlaps the execution probe of `runtime/HostDiagnostics.c` (`hd_collect(..., probe_execution, ...)`); fold it in there rather than keep two. |
| Loading its own Unix libraries at run time: `wine` dlopens `ntdll.so`, which dlopens `win32u.so`, `winemac.drv.so`, `ws2_32.so`, … (about forty arm64 Mach-O dylibs) | `runtime/GuestLink.c` loads the libraries an application carries at startup (up to 64, from its bundle or the executable's folder), resolves imports as dyld does, initializes them in dependency order, and answers the application's own `dlopen`/`dlsym`/`dlclose` for those *placed* images by any name dyld takes; a host `dlopen` of anything inside the application folder is refused (`gl_inside`) rather than handed to iOS dyld | **W3.** Build on GuestLink: place a library that was *not* loaded at startup when `dlopen` first names it, into arena space reserved for it (W2), with its fixups, initializers and registration as for a carried one; let the root be the runtime folder rather than the `.app`; follow dlopen chains (`ntdll.so` → `win32u.so` → …). Check each of Wine's dylibs first with `guest_probe <file> --library --validate-fixups` and `--carried-libraries`. |
| More than one process: `wineserver` (the process that owns handles, objects and synchronization) plus one Unix process per Windows process; `wineboot` starts `services.exe`, `plugplay.exe`, `explorer.exe` | None: iPadOS cannot spawn processes; `posix_spawn`, `system` and `popen` are logged and pass through to fail | **W4, single-process Wine.** `wineserver` becomes a thread in the same process (it already talks to clients over a Unix socket in the prefix and, on macOS, reads client memory through Mach task ports and suspends client threads through Mach thread ports, which work in-process). The Windows side is limited to one process: the prefix is created on the Mac (`wineboot` already run, `services.exe` never started), `CreateProcess` is refused, and the game executable is started directly instead of through the HD mod's launcher. Wine's `fork`/`exec` sites (`server.c` start_server, `process.c` spawn, `loader.c` exec_wineloader) are reached through the loader-owned function table in `runtime/NativeGuest.m` (README, "What Tolkara does to the application"); adding `fork`, `execv` and `posix_spawn` to that table has to be documented there. |
| AppKit for windows, events, cursors and screens (`winemac.drv`) | AppKit on UIKit for what WoW and Cyberpunk use, including `NSWindow` geometry, `NSScreen` coverage and opt-in local event monitors; a generic build (`NATIVE_GUEST_SHIMS=GENERIC`) stubs at run time what nothing provides | **W5.** Classify `winemac.drv.so` and the other Unix libraries with `tools/classify.py` (`--bundled` takes carried libraries); the driver subclasses `NSApplication`, uses `NSWindow`/`NSView`, `CGDisplay*`, `CGWarpMouseCursorPosition`, and `NSOpenGLContext` for GL. Fill the gaps in `translation/AppKit`; GL is not available (see W6). |
| A GPU path: HotA/HD mod render through DirectDraw or Direct3D 9 | Metal passes through | **W6.** Wine's `wined3d` needs OpenGL or Vulkan; iPadOS has neither natively. Vulkan through MoltenVK (which supports iOS) is the route: `winevulkan` → `libMoltenVK.dylib` built for iOS and bundled in the runtime as a translation library → Metal. DXVK's `d3d9` (built for arm64ec) on top of that is the combination CrossOver and Whisky use for Direct3D 9 on Macs. |
| Audio through CoreAudio (`winecoreaudio.drv`) | CoreAudio/AudioToolbox on AVFAudio for the calls WoW makes | **W7.** Classify and fill, like W5. |
| 4 KiB page semantics for x86 code on a 16 KiB kernel | n/a (the arena is 16 KiB aligned) | **W8, upstream.** FEX's Linux mode requires a 4 KiB host kernel (Asahi runs it in a 4 KiB microVM); on Windows/ARM64EC Wine mediates memory, and CrossOver's Mac preview shows it can be made to work on 16 KiB pages, but those FEX changes are not published yet (CodeWeavers' source page carries 26.3; the ARM64 work is due with CrossOver 27 in early 2027). Until then this is the least certain layer: watch upstream FEX (FEX-2609 as of September 2026), `bylaws/FEX` (`arm64ec`, `asahi` branches) and `bylaws/wine` (`upstream-arm64ec`). |
| Memory-model emulation | n/a | Apple silicon has no user-selectable TSO outside Rosetta; FEX falls back to explicit ordering, at a cost. Heroes III is a 1999 program; this should not matter. |

Also upstream, not in Tolkara: Wine's own `virtual.c` has no `MAP_JIT` handling
on macOS at all (CrossOver's tree has some; upstream Wine 11 does not). The
Wine branch adds it as "The JIT pool" above; on the iPad the same code takes
its pool from the prepared arena through `WINEJITPOOL=start-end`, and
whether the arena's pages honour the per-thread switch there is still to be
measured (M1 ended before that stage).

## Milestones

Ordered so that each layer is proven before the next depends on it.

- **M0 — the runtime runs the game natively on the Mac.** No Rosetta, no
  Tolkara: `tools/build_windows_runtime.sh`, then
  `profiles/heroes3-hota/install.py --installer … --stage-only` and the command
  it prints. This validates Wine's arm64ec build on macOS, FEX's modules and
  the prefix. Everything in W8 shows up here first.

  **Result, 2026-09-25, M4 Pro, macOS 27.** The runtime builds (wine-10.13
  arm64: 32 Unix-side libraries, 1052 PE DLLs for arm64ec and i386, FEX's
  `libarm64ecfex.dll` and `libwow64fex.dll` built with llvm-mingw 20260922)
  and `wine --version` runs natively. The installer unpacks with innoextract.
  Prefix creation fails: `wineboot` cannot map `KUSER_SHARED_DATA` at
  `0x7ffe0000`, see "The 4 GB floor". M0 is not reached and cannot be for a
  32-bit program with the current FEX.

  **Result, 2026-09-26, with the Wine and FEX branches.** The 64-bit half
  of M0 is reached: the prefix is created, ARM64EC programs run, and x86-64
  programs run under FEX with the JIT pool (see "State of the branches").
  Later the same day the 32-bit half followed: 32-bit x86 programs run
  through WoW64 and FEX with the address window (see "The 32-bit window").
  The game is staged with `profiles/heroes3-hota/install.py`, and that
  evening `h3hota HD.exe` reached the HotA main menu with music, natively
  on this Mac ("The main menu, 2026-09-26 evening" above). **M0 is reached**
  with the HD mod's GDI renderer.
- **M1 — the device JIT measurement.** Launch the installed, enrolled app
  once with `xcrun devicectl device process launch --device "$DEVICE"
  "$TOLKARA_BUNDLE_ID" --local-game-startup --jit-probe` (any library app will
  do: the probe runs after the arena is prepared and the helper has detached,
  and skips guest entry) and record the `[jit-probe]` lines from
  `Documents/native-guest.log` here. This decides the shape of W2.

  **Result, 2026-09-25, iPad Pro M5, iPadOS 27, Developer service, this
  branch at 1b4d23a.** After the helper prepared an 87,425,024-byte arena in
  81.5 s and detached: `MAP_JIT` allocation denied (`EPERM`); an anonymous
  page the process mapped, wrote and `mprotect`ed to RX was executed and
  the kernel ended the process with `SIGBUS`, `KERN_PROTECTION_FAILURE` at
  that page (`Tolkara-2026-09-25-185053.ips`). The process's code-signing
  flags at that point were `0x32000305`: `CS_DEBUGGED` set, `CS_HARD` and
  `CS_KILL` still in force. The RWX stage was never reached. Conclusion:
  only memory the developer service prepared can execute; a JIT has to live
  in a pool reserved inside the prepared arena (W2 above). The same
  measurement under External JIT is still to be made.
- **M2 — `wine --version` under Tolkara.** Wine's loader reaches its Unix side
  (W3 and the first half of W2).

  **Result, 2026-09-26, iPad Pro M5.** Reached: the loader, placed by
  Tolkara from the profile, prints its version on the device.
- **M3 — `wineserver` in-process and a Wine-shipped program on screen**
  (`notepad.exe` or `winecfg`, both Wine's own; W4, W5).
  Passed over: the game itself was the first program on screen.
- **M4 — Heroes III main menu.** W6, W7, and the game's own DLLs under FEX.

  **Result, 2026-09-27, iPad Pro M5, iPadOS 27, Developer service.** The
  menu shows ("On the iPad"). W6 was not needed for it (the GDI renderer);
  W7 is unverified.
- **M5 — a game played through**, recorded in
  [COMPATIBILITY.md](../COMPATIBILITY.md).

## Working rules specific to this stack

- The game's files are copied unchanged and hash-verified by the install
  script (every `.exe`, `.dll` and `.asi`). The HD mod and HotA libraries are
  part of the game as GOG ships it and are treated the same way.
- Wine and FEX are our runtime: built from source by the user, signed under
  the user's identity like the rest of Tolkara's libraries, and never
  committed. Their licences (LGPL 2.1+, MIT) are compatible with that.
- The single-process model (W4) is a Tolkara constraint, not a policy: when
  iPadOS offers a way to run helpers, `wineserver` can go back to being one.
- A native alternative exists for this particular game: VCMI, an open-source
  reimplementation of the Heroes III engine with an iPadOS build. It cannot
  run HotA's own code, which is why this profile runs the real program.
