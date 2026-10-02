# Building and installing Tolkara

Tolkara is meant to be built by you: you build it, you sign it with your own
Apple developer identity, and it runs on your own iPad or iPhone. (External
JIT is the one exception to the signing: you build it unsigned and your
sideloading tool signs it; see step 4.) This page takes you from a fresh clone
to a running application.

For the experimental iPhone path, see [IPHONE.md](IPHONE.md). It uses the
same signing and enrollment procedures below; references to the connected
iPad also apply to the iPhone. The guide distinguishes tested iPhone behavior
from the more extensive iPad results.

## What you need

- A Mac with a recent Xcode, plus `xcodegen` and Python 3
  (`brew install xcodegen`).
- An Apple developer account. A paid membership is strongly recommended: the
  app needs the Network Extension (packet tunnel), increased memory limit and
  extended virtual addressing capabilities, which free personal teams cannot
  sign, and free provisioning profiles expire after seven days.
- An iPad or iPhone. Development and testing so far used an iPad Pro (M5)
  on iPadOS 27. Experimental iPhone testing used an iPhone 16 Pro Max on iOS
  27.0; the deployment target alone does not establish compatibility with
  other devices or OS versions.
- A macOS arm64 application that you own, installed on the Mac.

## 1. Enable Developer Mode on the iPad

1. Connect the iPad to the Mac by cable, unlock it and tap **Trust**.
2. Open Xcode once with the iPad connected (Window > Devices and Simulators) so
   that the iPad offers the option.
3. On the iPad: Settings > Privacy & Security > **Developer Mode** > on. The
   iPad restarts; confirm the prompt after it boots.

Tolkara depends on Developer Mode: iPadOS runs development-signed apps only in
Developer Mode, and the Developer service execution mode uses the developer
service that exists only there.

## 2. Configure your own signing

Nothing about your identity is stored in the repository. Copy the template and
fill it in; `local.env` is ignored by git.

```bash
cp local.env.example local.env
```

- `DEVELOPMENT_TEAM`: your 10-character team ID (developer.apple.com >
  Membership details, or Xcode > Settings > Accounts).
- `TOLKARA_BUNDLE_ID`: any identifier unique to you, for example
  `local.tolkara.yourname`. Apple registers a bundle ID to a single team, so the
  default will not work for you. The tunnel extension automatically uses
  `<your id>.authorization`.
- `DEVICE`: your iPad's UDID:

```bash
xcrun devicectl list devices
```

- `GUEST_EXE`: the executable inside the macOS app you own, for example
  `/Applications/Example.app/Contents/MacOS/Example`. To run several apps,
  list all their executables separated by `:` (like `PATH`); the compatibility
  libraries are built for all of them.
- `TOLKARA_PROFILE` (optional): your own profile, if it is not in
  [`profiles/`](../profiles). Every profile there is included automatically.
- `TOLKARA_MODE` (optional): `developer-service` or `local-signing`, see step 4.
  Without it the app asks on first launch.
- `TOLKARA_EXPERIMENTAL_ADAPTERS` (optional, experimental): adapters marked
  `experimental` under `translation/` take part only when named here, separated
  by `:`. Today `GameController` (reports no controllers, real gamepads
  included) and `MetalFX` (presented as absent), both written for one game's
  crashes and not yet validated on a device. They affect every application in
  the build.

Xcode signs automatically (`CODE_SIGN_STYLE: Automatic`). The first build
registers the bundle IDs and the iPad with your team and creates the profiles.
If it reports a signing error, open `Tolkara.xcodeproj` once in Xcode, select
the `Tolkara` and `LocalAuthorizationTunnel` targets, and let Xcode repair
signing under Signing & Capabilities.

When building directly in Xcode, run `tools/generate.sh` after setting up
`local.env`, open `Tolkara.xcodeproj`, and select the **Tolkara** scheme and
your device. The shared scheme runs without a debugger; keep **Debug
executable** disabled. Direct Xcode builds include the generic compatibility
libraries by default. `tools/install.sh` retains its application-specific
default; pass `NATIVE_GUEST_SHIMS=GENERIC` to that script to build without a
particular `GUEST_EXE`. Regenerating the project replaces manual project
settings, so keep personal signing settings in the ignored `local.env`.

## 3. Build and install

This builds the Tolkara app, which offers Developer service and Local signing.
For External JIT, skip to [External JIT](#external-jit-sideload-an-unsigned-build)
in step 4: it needs the TolkaraDiagnostics app built unsigned instead, and no
signing team of yours.

```bash
tools/install.sh
```

This generates the Xcode project, inspects which macOS frameworks and symbols
your executable imports, builds and signs **only Tolkara's own code** (the app,
its tunnel extension and the translation libraries), and installs the app. Your
executable is read for analysis; it is not copied into the app, modified or
signed. (Local signing signs a separate page container derived from it; see
step 4.)

On first launch iPadOS may ask you to trust your developer certificate:
Settings > General > VPN & Device Management.

## 4. Set up your execution mode

Tolkara runs the application's code in one of three ways; the README's
[Three ways to run code](../README.md#three-ways-to-run-code) compares them. Choose
one. The app asks on first launch unless `TOLKARA_MODE` preselected a mode, and
**Execution mode…** in the app changes it later. You only need to set up the
mode you use.

### Developer service: enrol local authorization (once)

```bash
tools/enroll.sh
```

With the iPad connected and unlocked, this creates a pairing identity for the
Tolkara app over the Mac's existing trusted USB session and stores it in the
app's device-only Keychain. Approve the prompt on the iPad. The temporary file
is deleted from the Mac afterwards.

The first time you start an app, iPadOS asks permission to add a VPN
configuration. This is Tolkara's own on-device packet tunnel. It routes one
private address to the iPad's own developer service and carries no other
traffic; nothing leaves the device. How it works is documented in
[LOCAL_AUTHORIZATION.md](LOCAL_AUTHORIZATION.md).

After enrolment the Mac is no longer needed: launches, relaunches and reboots
work on the iPad alone. You need to repeat steps 3 and 4 only when your
provisioning profile expires or you change the bundle ID or Keychain group.

> `tools/enroll.sh` packages the procedure used during development into one
> command. If it fails, the individual steps are readable in the script and
> each prints its own diagnosis.

### Local signing: build the page container

With `TOLKARA_MODE=local-signing` in `local.env`, `tools/install.sh` does this
after installing. By hand:

```bash
python3 tools/build_signed_container.py
```

It reads `GUEST_EXE`, `TOLKARA_CAPTURE`, `DEVELOPMENT_TEAM` and `SIGN_IDENTITY`
from the environment or `local.env`, puts the executable's `__TEXT` pages into
`build/signed-image/page-container.dylib`, signs it with your Apple Development identity and verifies the signature. The
first signature asks macOS whether the signing tool may use your signing key:
choose **Always Allow**. The approval belongs to that build of the tool, so it
is asked again after the tool is rebuilt. Signing on the iPad itself is not
implemented yet.

Copy the container into the Tolkara app's Documents as
`LocalSigning/page-container.dylib` (in the Files app: On My iPad > Tolkara >
LocalSigning). `tools/install.sh` with `TOLKARA_MODE=local-signing` copies it
for you.

With several apps, each needs its own container, named after the SHA-256 of
its executable file: `LocalSigning/<sha256>.dylib` (`shasum -a 256` prints it;
an app's details in the library show it too). `tools/install.sh` builds and
copies one per `GUEST_EXE` entry; give `TOLKARA_CAPTURE` one entry per
executable, in the same order, separated by `:` (empty for the on-disk code,
`skip` for none). An app without its own container uses `page-container.dylib`
if present, and the runtime refuses it unless it belongs to that executable.

Without `--capture`, the container holds the executable's code as it is on
disk. That is right only for applications that do not rewrite their own code at
launch. For one that does, such as the tested World of Warcraft client, the
container must be built from a capture of the final code pages
(`--capture FILE`, or `TOLKARA_CAPTURE` in `local.env`), and Tolkara cannot
produce that capture yet. A container that does not match the executable, or
what its own startup code produces, stops the launch before any more
application code runs; the app may close, and `Documents/native-guest.log` says
why (`[signed-image] FATAL …` or a rejection). Rebuild the container whenever
the application is updated.

### External JIT: sideload an unsigned build

External JIT needs no signing team of yours and no Mac after the build. A
sideloading tool (SideStore or similar) signs the app with your Apple ID, and
JIT is enabled when the app opens, by that tool or by a JIT enabler such as
StikDebug. A free Apple ID can sign it, but free signing drops the
increased-memory-limit and extended-virtual-addressing capabilities, so large
applications may not fit in memory.

```bash
tools/package_ipa.sh
```

It builds `Tolkara-unsigned.ipa`: the TolkaraDiagnostics target with no signing
team (only an ad hoc signature that declares the two memory capabilities, so
your sideloading tool knows to request them), as a generic build (`NATIVE_GUEST_SHIMS=GENERIC`, one adapter per framework and no
`GUEST_EXE`), with External JIT preselected. As a convenience, each `v*`
release carries the same build, made by `.github/workflows/release.yml`, with
install links for SideStore and LiveContainer in its notes; building it
yourself remains the supported way. The release build leaves out the public
root certificates a build exports from your own Mac, so an application that
reads macOS's system root certificate store finds none there. Install it with your sideloading
tool, open it with JIT enabled, then add your application in the app. Opened
without JIT, Tolkara says so instead of starting the application. Sideloading
tools usually change the app's bundle identifier: copy your application's files
with Finder or the Files app, or set `TOLKARA_BUNDLE_ID` to the installed
identifier before running a profile's `install.py` (step 5). This mode has
not been run on a device yet; report what you find in
[COMPATIBILITY.md](../COMPATIBILITY.md).

A generic build also works with the other modes where they are available:
`NATIVE_GUEST_SHIMS=GENERIC tools/install.sh` needs no `GUEST_EXE` (with Local
signing, set `GUEST_EXE` anyway so its page containers are built). Imports that
no adapter or iPadOS library provides become stubs at launch and are listed in
`Documents/native-guest.log` (`[native] stub …`).

## 5. Copy your application's files

The application's files live in the Tolkara app's Documents folder on the iPad,
visible in the Files app under On My iPad > Tolkara. A profile says where the
launcher expects them. For the tested profile:

```bash
python3 profiles/wow-classic-era/install.py
```

An app whose profile is in `profiles/` appears in Tolkara's library by itself
once its files are there. For anything else, copy the application's folder with
Finder or the Files app, then tap **+** in Tolkara and choose its executable (or
its `.app`). Tolkara remembers it; you do not pick it again. Optionally write a
profile: see [profiles/README.md](../profiles/README.md).

## 6. Run

Open Tolkara on the iPad, choose the execution mode if it asks, and tap the
app in the library. With Developer service, keep Tolkara in the foreground
while it prepares memory (about 3 MB per second: 33 seconds for Heroes III). One app can start per
session: to start another, open Tolkara again. When an app closes cleanly,
Tolkara ends itself after a short note, so the next tap on its icon opens the
library ready to start another app.
Runtime output goes to `Documents/native-guest.log`; the Diagnostics menu
(stethoscope) shows it and the other logs, and holds the development checks.

## Developing without a device

```bash
tools/test_emulation.sh
```

```bash
tools/run.sh sim
```

The first runs the sanitizer regression suite on the Mac. The second builds the
`TolkaraDiagnostics` scheme and runs the loader diagnostics in the simulator
against a synthetic test application from [`testguest/`](../testguest). To try
Local signing in the simulator:

```bash
TOLKARA_MODE=local-signing tools/run.sh sim
```

It builds an ad-hoc signed page container for the test application (or for
`GUEST_EXE` if `local.env` sets it) and runs its first initializer through
Local signing.
Simulator builds need no signing team. A simulator pass says nothing about
Metal behaviour or native execution on a real iPad.

To build the full app for the simulator by hand:

```bash
tools/generate.sh && xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/integrated-sim ARCHS=arm64 build
```

## Development runs on the iPad

Tools under `tools/` start the app with launch arguments instead of the
library, for example `xcrun devicectl device process launch --device <iPad>
<bundle id> --native-startup --app=<profile id>`; such runs keep a plain status
screen. Diagnostics that change what the runtime does are opt-in and never on
for apps started from the library:

- `--local-native-authorization` (Tolkara build, with `--native-startup` or
  `--native-initializer`): this iPad's Developer service prepares memory, as
  for a library launch, instead of a debugger on the Mac. It needs the
  enrolment from step 4; the setup report is `Documents/local-game-setup.txt`.
- `--sample-native`: samples the guest's threads every 10 seconds and keeps
  crash evidence in `Documents/native-signal.log`.
- `--trace-guest`: logs the guest's failed file access (with errno), the
  directories it creates and the environment variables it reads, each distinct
  line once, with paths shortened as elsewhere in the log; a variable's value
  appears only when it lies in the app's home, otherwise only its length.
  Meant for bringing up a new application; it slows file access.
- `--case-insensitive-files` (experimental): a file lookup that fails is
  retried with each missing folder or file name matched ignoring case, as on
  macOS, and the log names the folder. Files being created and Foundation's
  own file APIs are not covered, and each miss costs a directory listing. For
  a known case, prefer a profile's `caseAliases` (see
  [profiles/README.md](../profiles/README.md)). Not for Wine, which ignores
  case itself: with it, a folder spelled differently is found for a lookup
  but not for a file created in it, so a Windows game cannot save there.
- `--guest-arguments=<arguments>` and `--guest-environment=NAME=value` (with
  `--local-game-startup` or `--native-startup`): replace a profile's command
  line (tab-separated) or set one variable over its environment for this
  launch, for a compatibility runtime's own diagnostics (Wine's `WINEDEBUG`
  channels, say) without building the app again. `--guest-environment` may
  be given more than once.
- `TOLKARA_VM_BUDGET_MB=<megabytes>` in the launch environment (experimental):
  anonymous reservations of 64 MiB and more count against this budget; past
  it they are mapped smaller than requested, followed by a guard page. Counted
  reservations are kept outside earlier requested ranges, including their
  unmapped tails; if no suitable location can be mapped, allocation fails.
  The guest still believes it received the full length, so accesses beyond
  the grant can fault. This does not make Cyberpunk fit on the tested iPad:
  separate large ranges fail during startup. See [the VM investigation](CYBERPUNK_VM.md).
- `--vm-probe` (experimental): instead of starting an app, measures how much
  virtual memory iPadOS lets Tolkara reserve (single, cumulative, `PROT_NONE`,
  at fixed addresses, file-backed) and writes `Documents/vm-probe.txt`. It only
  reserves and releases free address space of its own.

## Things that will bite you

- Never attach a debugger (Xcode, lldb) to the app once application code is
  running. Tolkara deliberately runs with the debugger detached.
- Deleting the app from the iPad deletes the application files you copied, the
  enrolment and the page container. Installing over it keeps them.
- Do not commit `local.env`, provisioning profiles, pairing records, page
  containers, captures or anything from `build/` or `logs/`.


### Preparation status

Developer-service launches show connection, memory preparation, and app-loading
messages with an elapsed clock. The clock and activity indicator use Core
Animation so they keep moving while the service pauses the host process. There
is no measured completion percentage during that pause. Preparation failures
stop the indicator and expose the existing diagnostics action.

Below the clock, every launch mode shows what startup is doing until the app's
own window appears: the runtime's current step (loading, linking, the app's
startup code with a count of its initializers, the check against the page
container, then the app's own startup) with its duration, and the file the app
most recently wrote in its folder with its size and age. These lines are
redrawn from a background queue, so they keep changing while application code
holds the main thread; a long wait while the app writes, say, a crash report
into `Errors/` shows as such.

To check the display without loading application code, boot an iPad simulator
and run `tools/test_launch_progress.sh` (or pass a simulator ID and `--dark`).
This installs only our standalone UIKit fixture, holds its main thread for six
seconds while a stand-in step counts and a file grows, then pauses it for three
seconds and resumes it, saving screenshots in `build/launch-progress/`. Verify
that the activity lines advance between `busy-1` and `busy-2`, and that the
clock advances during suspension. The fixture uses a separate bundle ID and
does not start authorization or run a guest.
