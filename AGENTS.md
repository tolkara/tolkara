# Repository Guidelines

## Project Structure & Module Organization

- `runtime/`: Mach-O loading, guest memory, native execution (Developer service arena, Local signing page container `SignedImage`, or External JIT arena `DebuggerArena`), carried libraries (`GuestLink`), runtime stubs (`GuestStubs`), interpreter diagnostics.
- `translation/`: macOS API adapters (AppKit input/windowing, Metal shader handling, audio, Security).
- `authorization/`: Developer service: bundled pairing, transport, tunnel extension and memory-preparation protocol.
- `launcher/`: the iPad (and experimental iPhone) app. `profiles/`: data-only descriptions of tested applications.
- `management/`: Tolkara Management, the Mac app that guides a user through the self-build, install, enrolment and copying an application (`docs/MANAGEMENT.md`). It runs `tools/` scripts on the source it carries; keep its profile rules (`management/App/Core/Profile.swift`) in step with `tools/check_profile.py`.
- `tests/`: C, Objective-C, Swift and Python tests; `testguest/`: our synthetic guest fixture.
- `tools/`: builds, diagnostics and regression scripts. `docs/`: building guide and architecture.
- `build/` and `logs/` are ignored outputs. Third-party applications and assets are never committed.

## Build, Test, and Development Commands

Requires Xcode, XcodeGen and Python 3. Personal settings (team, bundle ID, device) live in ignored `local.env`; see `local.env.example` and `docs/BUILDING.md`.

```sh
tools/test_emulation.sh     # sanitizer regression suite on the Mac
tools/test_translation_sim.sh   # the UIKit-backed adapters' tests, run in the simulator
tools/test_touch_controls_ui.sh --self-test   # on-screen controls on our own test screen, in the simulator
tools/run.sh sim            # loader diagnostics in the simulator (TolkaraDiagnostics scheme)
TOLKARA_MODE=local-signing tools/run.sh sim   # Local signing: first initializer of testguest (or GUEST_EXE) from an ad-hoc page container
tools/install.sh            # build, sign and install the Tolkara app on the configured iPad
tools/probe_guest.sh "/path/to/Executable"   # inspect an unchanged executable
python3 tools/probe_captured_shaders.py       # compile every shader library a game left on the iPad with the iPad's own Metal (no app code runs)
python3 tools/build_signed_container.py       # build and sign the Local signing page container for GUEST_EXE
python3 tools/make_icon.py                    # redraw the app icon at every size and appearance (needs Google Chrome)
NATIVE_GUEST_SHIMS=GENERIC tools/install.sh   # build for no particular application: one adapter per translation/<Framework>/
tools/package_ipa.sh                          # unsigned generic TolkaraDiagnostics .ipa for External JIT (sideloaded, e.g. SideStore)
tools/test_management.sh                      # Tolkara Management (Mac app) unit tests
tools/package_management.sh                   # Tolkara Management .dmg (Developer ID and notarization when configured)
```

Device installs replace the app under the same bundle ID and keep its data.

## Coding Style & Naming Conventions

Four-space indentation in source files, two spaces in YAML; match surrounding conventions without unrelated reformatting. Preserve module prefixes such as `gm_`, `AK` and `TK`. Tests are named `test_*.{c,m,swift,py}`. Compiler warnings are errors in the regression scripts.

## Testing Guidelines

Standalone native executables and Python `unittest`, with ASan/UBSan where configured. Add focused coverage for memory bounds, malformed modules, protocol failures and adapter behavior. Simulator success does not prove physical Metal or authorization behavior; record device results in `COMPATIBILITY.md`.

## Runtime & Security Constraints

For this branch's Cyberpunk experiment, the user explicitly authorized a rare
exception on 2026-09-26: runtime memory emulation may fetch the faulting
instruction and execute its memory access against software backing. The opt-in
is restricted to Cyberpunk. The general rule below stands for other apps, and
the bans on game-code reverse engineering, binary patches, debugger attachment
after entry, input automation and integrity workarounds still apply. See
`docs/SOFTWARE_MEMORY.md` for the tested scope and current limits.

The original executable is never modified: it is imported as hash-verified data and never patched or re-signed. Three execution modes exist and each user chooses one. **Developer service** never signs application code: the iPad's developer service prepares memory and detaches before any application code runs. **External JIT** (TolkaraDiagnostics only) never signs application code either: a JIT enabler (the user's sideloading tool, or one such as StikDebug) attaches at launch and prepares memory; the runtime asks it to detach and refuses guest entry while any debugger is attached or the arena is not executable. **Local signing** signs only a page container derived locally from the application's final code pages, with the user's own developer identity; containers and captures stay in ignored build output or on the user's device and are never committed. Otherwise sign only our runtime and helpers. Users build Tolkara themselves; docs present that first. As a secondary convenience for External JIT, a `v*` tag publishes the unsigned generic `Tolkara-unsigned.ipa` (`.github/workflows/release.yml`): only our own code, never application code, assets, signing material or anything exported from macOS (it is built with `TOLKARA_SYSTEM_ROOTS=NO`, so no system root certificates). The same tag publishes `Tolkara-Management.dmg`, the Mac setup app: it carries only our own code and the tagged source (files git tracks or does not ignore), and builds Tolkara on the user's Mac with the user's own team, so it remains a self-build. It may be signed and notarized with the project's Developer ID from repository secrets; it never contains a user's signing material. It runs helper scripts only from built-in profiles; a profile a user adds is validated data and is never executed. An online game's profile carries a `setup.risk` notice that the user must accept before it is set up; keep each statement in it backed by a linked source. Runtime stubs for unresolved imports only where no build-time analysis covered them: in generic builds and for carried libraries' imports; in a build for one executable, that executable's unresolved imports fail. No application-memory inspection beyond loading and verifying the image, no automation or integrity-check workarounds. Keep credentials, signing teams, device identifiers and pairing records out of commits and logs. Never attach an external debugger after guest entry. Do not uninstall the app from a user's device without coordination.
