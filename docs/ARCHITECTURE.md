# Architecture

Tolkara has the same shape as Wine: a loader that places an unmodified program
in memory, and a set of libraries that implement the operating-system interface
that program expects. macOS and iPadOS share a CPU architecture, a kernel, an
Objective-C runtime and most low-level frameworks, so far less needs translating
than between Windows and Linux. The work is in the parts that differ: process
loading, executable memory, the desktop UI frameworks and the shader format.

```
  original macOS executable (data, unchanged)
                 │ loaded by                 executable memory, one of:
        ┌────────▼────────┐                ┌──────────────────────────────┐
        │    runtime/     │◄───────────────┤ Developer service:           │
        └────────┬────────┘                │   authorization/             │
                 │ imports resolve to      │ Local signing: signed page   │
        ┌────────▼────────┐                │   container (SignedImage)    │
        │  translation/   │                │ External JIT: a JIT          │
        └────────┬────────┘                │   enabler's debugger         │
                 │ calls                   └──────────────────────────────┘
          iPadOS frameworks (UIKit, Metal, AVFAudio, Security, …)
```
## runtime/: the loader

- `GuestImage` parses thin and fat arm64 `MH_EXECUTE` and `MH_DYLIB` files with
  bounds checks (including `LC_RPATH`, re-exports and `__init_offsets`
  initializers) and maps segments at their preferred addresses in a guest
  address space.
- `GuestLink` finds the libraries an application carries in its own bundle
  (`@rpath`, `@loader_path`, `@executable_path`; nothing outside the bundle is
  opened) and loads them as data like the executable. They are placed in the
  same arena, get their own thread-local storage, and run their initializers
  before the application's, each after the carried libraries it links, as
  with dyld. Local signing refuses such an application: its container holds
  only the executable's pages.
- `GuestFixups` applies dyld rebases and binds, from opcode streams or chained
  fixups (plain arm64 pointer formats; each chain stays on its page). Binds
  resolve through a short table of loader-owned functions (listed in the
  README), then the application itself as dyld would search it (the carried
  library a bind names; the executable's own exports for weak-definition,
  flat and main-executable binds, before any carried library), then the
  translation library mapped for that import, then the process's own symbols.
  Where no build-time analysis covered an import (a generic build, or a carried
  library's imports, which `classify.py` reads only for the libraries in the
  application's `Contents/Frameworks`), one that nothing provides becomes a
  runtime stub (`GuestStubs`) that logs and returns zero; in a build for one
  application, its executable's unresolved imports fail.
- `NativeCodeMemory` (Developer service, External JIT) holds the image in memory with two
  views: a read-write view used for loading and for the program's own later
  code writes, and a read-execute view the CPU runs from. The executable view is
  never writable.
- `SignedImage` (Local signing) checks a signed page container against the
  executable before any of its pages are used; see below.
- `GuestTLS` provides macOS thread-local variables. `NativeGuest` registers the
  image's Objective-C metadata with the runtime, runs the original initializers
  in order, and calls the original `main`.
- `NativeGuest` also answers the application's own `dlopen`: the executable or
  a carried library yields the placed image (`dlsym` searches its exports), a
  library the map names opens its adapter, or nothing where the map marks it
  absent on iPadOS, and any other code inside the application's folder is
  refused rather than handed to the system's loader. `dladdr` names the carried
  library an address belongs to.
- `GuestPaths` (case-insensitive file lookups) and `GuestVMBudget` (a budget
  for large virtual-memory reservations) back two experimental, opt-in
  development aids; see [BUILDING.md](BUILDING.md#development-runs-on-the-ipad).
- `GuestModule` and `tools/package_guest.py` import an executable as a separate,
  hash-verified module under Documents. It refuses to write into a signed bundle.
- `GuestMemory`, `DarwinMemory` and `GuestCPU` are a software MMU and a scalar
  arm64 interpreter. They are a correctness reference for tests, not the path
  applications run on.

The file on disk is never changed. Rebases, binds and any code the program
unpacks for itself exist only in memory, and, with Local signing, in the signed
page container derived from it.

## translation/: the macOS API layer

`tools/classify.py` reads an executable's import table, and those of the
libraries its bundle carries in `Contents/Frameworks`, and sorts every symbol:
present on iPadOS (re-exported from the real framework), hand-written in
`translation/<Framework>/`, or missing. `tools/build_shims.py` then builds one
library per macOS framework. Missing functions become stubs that log their first
call and return zero, which is how new applications reveal what they need.
Marker files in an adapter's directory change that: `standalone` replaces a
library iOS has instead of re-exporting it, `absent` presents the library as
unavailable (the runtime neither opens it nor binds anything to it), and
`experimental` keeps the directory out of every build that does not name it in
`TOLKARA_EXPERIMENTAL_ADAPTERS`. In a generic build, `opt-in` makes the runtime
use the adapter only for an application whose profile names it in the
`TOLKARA_ADAPTERS` environment variable (listed in `Guest/opt-in.json`); every
other application gets the iOS library.

A generic build (`NATIVE_GUEST_SHIMS=GENERIC`) is made for no particular
executable: one adapter per hand-written `translation/<Framework>/` and no import
map. On the device the runtime finds each library by name (our adapter, else the
iPadOS library), stubs at load time what `classify.py` would have stubbed, and
AppKit reads the application's own compiled nibs (`NibArchive`) where no
build-time nib metadata exists.

Hand-written areas today:

- **AppKit** on UIKit: application and event loop, windows and views, keyboard,
  text input, mouse and pointer, cursors, menus, alerts, screens, images, and
  nib loading from metadata extracted by `tools/inspect_nib.py`.
- **Metal**: devices and presentation pass straight through to the iPad GPU.
  macOS shader libraries are validated and rewrapped in an iOS container around
  the unchanged AIR bitcode, and the iPad's own compiler builds the pipelines:
  legacy containers (AIR 2.0, 2.1 and 2.3, as World of Warcraft ships) and
  current ones (AIR 2.6 and 2.7). Only a library the iPad refuses falls back to
  a translation made on a Mac by `tools/serve_shader_translation.py` (the same
  AIR retargeted by Apple's compiler) and, failing that, pauses the game with a
  message instead of substituting a shader. The Diagnostics menu's **Captured
  shaders** check (`tools/probe_captured_shaders.py`) loads every library a
  game ever left for translation through the on-device path. On a GPU without
  BC texture sampling (A16 and older iPhones), BC textures are stored
  uncompressed and the guest's uploads are decoded on the CPU
  (`BCTextures.m`, `BCDecode.c`; see [IPHONE.md](IPHONE.md)); the guest still
  sees its BC formats.
- **CoreAudio / AudioToolbox** on AVFAudio, **Carbon / CoreServices** keyboard
  layout services, **CoreGraphics** display queries, and **Security** (system
  trust roots exported from the builder's own Mac at build time, a keychain
  subset, and the legacy CDSA crypto calls on CommonCrypto).
- Experimental and opt-in (`TOLKARA_EXPERIMENTAL_ADAPTERS`): **GameController**
  (also opt-in per application: only Cyberpunk 2077's profile uses it)
  as a Mac with no controllers, and **MetalFX** presented as absent. Both work
  around one game's crashes and are not yet validated on a device.
- Experimental launch arguments, each off by default and not yet validated on
  a device: `--appkit-event-monitors` (NSEvent local monitors run before
  dispatch), `--guest-window-covers-launcher` (the launcher's windows hide
  while a guest window is up) and `--metal-managed-storage` (Managed storage
  requests become Shared).

## Executable memory: three modes

iPadOS refuses to execute pages that are not covered by a valid code signature.
Tolkara has three ways to satisfy that, and each user chooses one.

### Developer service (authorization/)

The supported exception to the signature rule is development: when a debugger
prepares memory in a development-signed app, the kernel allows it to become
executable. JIT-based apps have long relied on a Mac or a second app to do this.

Tolkara does it alone. The app embeds a packet-tunnel extension that gives the
app a route to the iPad's own developer service. Over that route it implements
Apple's RemotePairing handshake, the CoreDevice tunnel, RemoteXPC service
discovery and the debugserver wire protocol, all written for this project. It
asks the service to prepare one zero-filled region: once every byte reads back
as zero, it writes one zero byte into each 16 KiB page (a debugger write
prepares the whole page it lands in) and reads it back. It then confirms the
debugger has detached **before any application code is copied in or run**. If any step is uncertain, entry is blocked and the app asks to be
restarted.

Pairing keys are created once by `tools/enroll.sh` and kept in a device-only
Keychain group shared by the app and its extension. The tunnel carries a single
private address; no other traffic is routed and nothing leaves the device.

Protocol detail and the history of what was tried are in
[LOCAL_AUTHORIZATION.md](LOCAL_AUTHORIZATION.md).

### Local signing (runtime/SignedImage)

The application's final `__TEXT` pages go into a *page container*: a minimal
arm64 dylib whose first 16 KiB page is its own header and whose single
16 KiB-aligned section holds those pages byte for byte, with the marker symbols
`tolkara_container_v1` and `tolkara_container_final` at its start.
`tools/build_signed_container.py` builds it from the executable, or, for an
application that rewrites its own code at launch, from a capture of its final
pages, and signs it with the user's identity through `tools/sign_guest_local.m`.
That signer is a `codesign` equivalent written only against Security and
CommonCrypto, so that it can later run on the iPad; today containers are built
and signed on a Mac. The launcher looks for the container at
`Documents/LocalSigning/page-container.dylib`.

At startup the runtime `dlopen`s the container, so the kernel validates its
signature and pages. Before any page is mapped, `SignedImage` checks the layout
and binds the container to the executable: the image must be exactly the size of
the executable's `__TEXT` and start with its header and load commands, byte for
byte, which include `LC_UUID`. Every page after the last one the application
rewrites at launch is identical to the executable's own; those pages, which must
include the application's first initializer, are then `vm_remap`ped from the
container into the arena as read-execute. Every page up to and including the
last rewritten one stays anonymous and writable while that initializer runs. The
runtime then compares what that initializer produced with the container, byte
for byte, and only then replaces the range with the validated pages. Any
difference stops startup before more application code runs, and later writes
into signed pages must reproduce the signed bytes exactly. Custom file mappings
of the container are not executable on iPadOS; only pages dyld has validated
are remapped. No debugger is involved.

### External JIT (runtime/DebuggerArena)

Only in the TolkaraDiagnostics build, which `tools/package_ipa.sh` produces as a
generic build without a signing team (ad hoc, only to declare the two memory
capabilities), for a sideloading tool to sign with the user's Apple ID. JIT is enabled by the sideloading tool or a separate JIT enabler such
as StikDebug, which attaches a debugger when the app opens and so marks the
process `CS_DEBUGGED`.

On current iPadOS the enabler also provides the executable region: Tolkara asks
for it with a breakpoint (`brk #0xf00d`, command in `x16`) that the enabler's
script services, and maps a writable alias of what it returns. The launcher asks
as soon as the app opens, because an enabler stays attached only briefly; a
reserved region another route uses instead is given back, and one too small for
the application stops the launch, since nothing is attached to ask again. Where
no enabler answers
but the process may run unsigned code, Tolkara maps its own region, as JIT apps
did on earlier systems. The breakpoint is only executed while a debugger is
attached; with none it would stop the process.

Before any application code runs, the runtime asks the debugger to detach and
refuses entry while any debugger is still attached or the region is not
executable. Nothing of the application is signed.

## launcher/ and profiles/

The launcher is a small UIKit app built around a library of applications
(`launcher/App/AppLibrary.m`). Adding an executable records it once; afterwards
it starts with one tap. An executable inside Tolkara's Documents folder runs in
place, with the folder containing its `.app` bundle as the working directory, so
it finds its resources. One picked from elsewhere is copied, verified, into
`Documents/GuestModules/<sha256>` (executable only). The library itself lives in
`Library/Application Support/Tolkara/apps.json`, outside the user-visible folder,
with paths relative to Documents; each start re-checks that the executable is a
regular file inside Documents, or that a copy still matches its hash.

Every profile in `profiles/` is packaged at build time. When a profile's files
are present in Documents the library adds that app under the profile's name,
so a profile's install script is enough to make an app appear. Profiles are
data; they cannot carry code or patches. A profile may name a compatibility
runtime with its command line instead of a macOS `.app`: the first such
runtime, Wine with FEX for a Windows program, is described in
[WINDOWS.md](WINDOWS.md).

The execution mode is chosen once for all apps (asked on first launch, changed
with the mode button in the library). With Local signing each app uses its own
page container, `Documents/LocalSigning/<SHA-256 of its executable>.dylib`,
falling back to the single-application `page-container.dylib`; the runtime
refuses a container that does not match the executable.

Development checks, the Developer service route controls and the runtime logs
are in a separate Diagnostics menu. Checks that load compatibility libraries or may be
terminated by the system end the session: iPadOS allows one guest startup per
process, so Tolkara must be reopened before starting an app. An app that
closes ends the Tolkara process after a short note, making the next tap on
the icon a fresh library; that includes an app whose `main` returns a nonzero
code, which the note then shows. The end is bounded (`runtime/ProcessEnd.c`):
`exit()` runs the application's exit handlers while its audio, Metal and
network threads are still alive, and one that waits for such a thread would
otherwise leave a dead screen, so after 3 seconds the process ends anyway
(30 while a clean exit uploads Steam Cloud saves, which itself waits at most
20). `-[NSApplication terminate:]` ends the process the same way. Launch arguments
used by `tools/` keep their plain status screen; `--app=<identifier>` selects a
library app for `--native-startup` and friends.

## Testing

`tools/test_emulation.sh` builds and runs standalone C, Objective-C, Swift and
Python tests with ASan and UBSan: memory semantics, malformed Mach-O input,
fixups, packaging, the pairing, tunnel and debug protocols against independent
peers, the page-container contract, the signer and a macOS end-to-end container
load, shader containers, keyboard and text input, and crypto parity with
macOS. Device behaviour has to be checked on a device; record what you tested
in [COMPATIBILITY.md](../COMPATIBILITY.md).
