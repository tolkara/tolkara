# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service, Local signing or External JIT), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). Memory preparation at each launch (about 80 s before the 2026-09-27 speed-up; not re-measured since). Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.9 (70003) | iPhone 16 Pro Max, iOS 27.0 | Developer service | User-confirmed startup, opening cinematic, login screen and mouse use with AssistiveTouch; runtime log records graphics window and audio. | Experimental. Region/language configuration required to avoid unsupported RegionPicker. AssistiveTouch required for the tested mouse setup. Account login, world entry, gameplay and controller input unverified. See [iPhone validation](#iphone-validation-2026-10-01). | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`. | Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`. | Developer service not yet validated on this iPad. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 (70170) | iPhone 16 Pro Max, iOS 27.0 | Developer service | User-confirmed login, world entry and about two hours of gameplay without reported problems (2026-10-02). Reported 60 FPS at 50% render scale and graphics quality 2. Controller support enabled using middle mouse click; controller menu navigation works. | Initial tests used a Bluetooth keyboard and AssistiveTouch; physical left mouse click did not activate the tested menu controls, while wheel-button click worked. The new [iOS keyboard and touch trackpad](docs/TOUCH_INPUT.md) were subsequently confirmed working by the user on this iPhone (2026-10-02). See [iPhone validation](#iphone-validation-2026-10-01). | [`wow-forever`](profiles/wow-forever) |
| Heroes of Might and Magic III: Horn of the Abyss (GOG, Windows x86, with the HD mod) | HotA 1.8.1, HD mod 5.8 | iPad Pro M5, iPadOS 27 | Developer service | New games on scenario maps: adventure map, towns, battles, AI turns with up to eight players over several days, saving and loading, music and sound, mouse and keyboard. Runs through Tolkara's builds of Wine and FEX, with the HD mod's GDI renderer. | Local signing cannot run it (FEX translates the game's code while it runs). About 33 s of memory preparation per launch. A double click is not recognised (Enter opens a selected town). Light grey margins when the HD mod letterboxes the game. Saving fails if launched with the development option `--case-insensitive-files`. Performance not measured. | [`heroes3-hota`](profiles/heroes3-hota) |
| Cyberpunk 2077 (GOG, macOS arm64) | 2.3.x (buildId 59052989568257053) | iPad Pro M5, iPadOS 27 | Developer service | Experimental software-memory mode completes all 6,540 initializers, main, GOG initialization, archives, scripts and shader caches, creates the game window, and visibly renders the opening cinematic with a Space-to-continue prompt. | Menu content and gameplay unverified. Early presentation samples are about 5 FPS, then settle near 1 FPS in the cinematic, with long pauses. Manual Space presses reach the adapter queue but have not visibly continued the game; routing 4 GiB pools to software passes the earlier Foundation allocation failure and reaches further loading. Loader and call-wrapper unwind support clears the GOG rich-presence abort on the iPad: the call reports its service error and returns, and loading continues. The merged-main run logs a main-menu presence state; visual menu and gameplay validation remain pending. Tests use a 3600-second watchdog timeout and a two-CPU query cap. See [VM investigation](docs/CYBERPUNK_VM.md) and [software-memory experiment](docs/SOFTWARE_MEMORY.md). | [`cyberpunk-2077`](profiles/cyberpunk-2077) |

## iPhone validation (2026-10-01)

Results updated on 2026-10-02 with the Forever gameplay report below.

Experimental support was tested on an iPhone 16 Pro Max / iOS 27.0 with
Developer service. The generic arm64 build installed successfully. Trusted USB
enrollment and the local authenticated tunnel/capability probe passed. The user
confirmed a cold launch after reboot with the iPhone disconnected from the Mac.
See [the iPhone guide](docs/IPHONE.md) for a reproducible setup.

The user confirmed that both Classic Era and Forever start and work through
the screens described below. Both required AssistiveTouch for the tested mouse
setup. These are manual device observations; the extent of input and gameplay
validation is recorded separately for each client.

### World of Warcraft Classic Era 1.15.9 (build 70003)

Memory preparation took 53–55 seconds for 87,425,024 bytes, all 12,658
initializers returned, and the original main ran. The user reached the opening
cinematic and login screen. The runtime log records a game window, loaded
Metal libraries and audio playback. The user confirmed mouse use with
AssistiveTouch enabled. Successful account login, world entry,
gameplay and performance have not been validated.

Initial launches stopped in `RegionPicker.nib`: its window, controls and
bindings are unsupported by the AppKit adapter. The source installation had
no `WTF/Config.wtf` to copy. Setting only `portal` did not resolve the failure;
setting `portal`, `textLocale` and `audioLocale` together to match the chosen
region and installed languages allowed startup to proceed. See the
[configuration workaround](profiles/wow-classic-era/README.md#region-and-language-before-the-first-launch).
No game executable was modified.

Controller input remains unverified. With `GamePadEnable=1`, a GameSir G8+
using its Switch profile did not control the login screen. A reported crash
in that attempt was a clean guest exit in the captured log: main returned 0,
startup returned PASS, and the host ended its session normally. No related
system crash report was available. The action that triggered the exit is
unknown. The build did not include the experimental controller-hiding adapter.
ConsolePort 3.2.7 installation was subsequently verified (interface 11509),
but addon loading inside a character and physical input were not validated.
These results do not establish gamepad support at login.

### World of Warcraft Forever 1.60.1 (build 70170)

On 2026-10-02 the user confirmed successful login, world entry and about two
hours of gameplay without problems on an iPhone 16 Pro Max / iOS 27.0, using
Developer service. The reported frame rate was 60 FPS at 50% render scale and
graphics quality 2. This is a manual report from the tested session, not a
benchmark across all areas or activities.

The initial setup used a Bluetooth keyboard and AssistiveTouch. The keyboard
was needed to enter account details. With AssistiveTouch
enabled, clicking the mouse wheel (middle button, not scrolling) selected the
controls used to enable controller support; left mouse click did not. The
controller could then navigate the menus. The separate
[touch-input implementation](docs/TOUCH_INPUT.md) now provides an iOS keyboard
and trackpad with two-finger scrolling. Its synthetic and simulator checks
pass, and on 2026-10-02 the user confirmed the new controls working correctly
in Forever on the same iPhone 16 Pro Max / iOS 27.0. Other-device input testing
remains pending. The two-hour gameplay/performance report above predates
these controls.

The working setup uses the beta's own `portal "test"` setting and the default
`TOLKARA_SYSTEM_ROOTS=YES` for the private build. Earlier attempts rejected
login with `BLZ51900003`. Matching the portal alone did not resolve it; the
initial build also lacked `CompatibilityRootCertificates.plist`. Login and
gameplay were confirmed after rebuilding with that public certificate
resource. The existing certificate-adapter tests passed with ASan/UBSan on
the Mac using all 158 packaged candidates.

Build 70170 was copied over 70124 with current Data files verified by path and
size, and the copied client bundle and metadata verified by SHA-256 readback.
Game files and iPhone settings were preserved during the subsequent Tolkara
app update. The original game executable was not modified.

### Palworld 1.0.8

The first native attempt prepared 351,895,552 bytes of executable memory in
209.602 seconds, then stopped before initializers at legacy rebase operation
1,000,001. The loader now bounds rebase work by the loaded image's pointer
capacity instead of a fixed million. A data-only Mac check of the unchanged
executable and its six carried libraries passed: the executable has 1,598,313
rebases and 14,217 binds.

With that fix installed, the next attempt prepared memory in 210.030 seconds,
completed all 5,741 initializers and entered the original main, then stopped.
The log includes unavailable libraries/stubbed imports and an unimplemented
`NSAppleEventManager` call, and ends with Unreal's crash reporter failing to
spawn (`EPERM`). The reporter failure does not identify the preceding fault.
No out-of-memory error was recorded in that runtime log; peak memory and the
original crash cause remain unknown. No game window or gameplay was validated.

## Runtime diagnostics

On 2026-09-26, `--sparse-memory-probe` passed on the iPad Pro M5 / iPadOS 27.
Tolkara's own assembly used 112 GiB of software address ranges and completed
18,600 scalar, SIMD, addressing and atomic fault/resume operations, using
96 KiB of backing pages. The subsequent opt-in Cyberpunk run uses full software
reservations and passes the original first-archive crash on the same iPad.
It opens all 32 archives and `final.redscripts`, then reaches an engine watchdog
timeout after over 33 million handled faults. No gameplay result is validated.
The experiment and instruction limitations are in
[Software-memory experiment](docs/SOFTWARE_MEMORY.md).

An entry records what one person observed. It is not a promise that the
application will keep working, and it says nothing about whether its publisher
permits it: read "Online games and account risk" in the [README](README.md).
