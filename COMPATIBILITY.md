# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service, Local signing or External JIT), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). Memory preparation at each launch (about 80 s before the 2026-09-27 speed-up; not re-measured since). Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.9 | iPhone 16 Pro Max, iOS 27 | Developer service | Startup, opening cinematic and login screen. | Experimental; login and gameplay not yet tried. A client without a saved region and language opens a region picker the AppKit adapter cannot show (see the profile). About 55 s of memory preparation. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPhone Duo, unfolded, iOS 27.2 | Developer service | Login and play (2026-11-01) with the [on-screen controls](docs/TOUCH_INPUT.md) only: walking with the movement stick, pointer, clicks and camera from the trackpad, keys 1 to 0, Jump, Escape and Tab from the side columns, and the iOS keyboard for the login. | Experimental. The game draws between the side columns, not under them (from 2026-11-02; not yet checked in the game). While Device Hub mirrors the iPhone, iOS counts the Mac's keyboard as a hardware keyboard and shows only the bar above its own keyboard; type on the Mac then, or disconnect Device Hub. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPhone 15 Plus (A16), iOS 27 | Developer service | Login with an authenticator, world entry, about 1.5 minutes in the world, audio, clean exit (2026-10-10), with the BC texture fallback engaged. About 49 s of memory preparation. | Experimental. The A16 cannot sample BC textures, so they are stored uncompressed (4 to 8 times the texture memory); rendering quality, frame rate and memory over a longer session are not yet checked. On-screen controls are hard to use for this game. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`. | Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`. | Water rendered black until 2026-10-11: the iPad hides its GPU from the registry, so the client took it for an AMD GPU. Since the GPU is reported as on a Mac with Apple silicon, the water renders (user check at graphics quality 8, about 60 FPS; client 1.60.1.70338). Developer service runs on this iPad ended without a report after 6 to 8 minutes, with diagnostics on; under investigation. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1.70338 | iPad Pro M5, iPadOS 27 | Developer service | Login screen with an Xbox Wireless Controller over Bluetooth, beside mouse and keyboard (2026-10-13; reported by 3phedra in pull request #5, with a build of that pull request's branch): the left stick moves the cursor and A clicks. The client reads the pad through the GameController driver in its own SDL build, which talks to iPadOS's GameController framework directly; Tolkara puts nothing in between. | Only the login screen was tried: play in the world with a controller is untested, and so are the released client the profile runs now and a build of the current `main`. The tested build declared controller support in `launcher/Info.plist` (`GCSupportsControllerUserInteraction`); `main` does not, because the framework delivers controllers without it. The beta client's other backend, Paddle, failed its own initialization (`ASSERTSAFES(res == pdCreateInstanceResult::Success, ...)`, `GamePadPaddle.cpp:262`) and left no gamepad input, so the gamepad backend is best left at its default. Pair the controller to the iPad first: an Xbox pad plugged into a computer over USB sends its input there and the iPad receives nothing. A sleeping pad woke on a button press, at launch or later. Tolkara → Diagnostics → Controller input shows what the GameController framework delivers to the app. | [`wow-forever`](profiles/wow-forever) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPhone 16 Pro Max, iOS 27 | Developer service | Login, world entry and about two hours of play (2026-10-02) with a Bluetooth keyboard and an AssistiveTouch mouse, at 60 FPS, graphics quality 2 and 50% render scale. The on-screen keyboard and touch trackpad worked in a later session. Launch without a Mac, including after reboot. | Experimental. Needs the beta's own `portal "test"` setting and a build with the system root certificates (the default); see [docs/IPHONE.md](docs/IPHONE.md). With AssistiveTouch, a left click did not press in-game buttons; a middle click did. | [`wow-forever`](profiles/wow-forever) |
| Heroes of Might and Magic III: Horn of the Abyss (GOG, Windows x86, with the HD mod) | HotA 1.8.1, HD mod 5.8 | iPad Pro M5, iPadOS 27 | Developer service | New games on scenario maps: adventure map, towns, battles, AI turns with up to eight players over several days, saving and loading, music and sound, mouse and keyboard. Runs through Tolkara's builds of Wine and FEX, with the HD mod's GDI renderer. | Local signing cannot run it (FEX translates the game's code while it runs). About 33 s of memory preparation per launch. A double click is not recognised (Enter opens a selected town). Light grey margins when the HD mod letterboxes the game. Saving fails if launched with the development option `--case-insensitive-files`. Performance not measured. | [`heroes3-hota`](profiles/heroes3-hota) |
| Cyberpunk 2077 (GOG, macOS arm64) | 2.3.x (buildId 59052989568257053) | iPad Pro M5, iPadOS 27 | Developer service | Experimental software-memory mode completes all 6,540 initializers, main, GOG initialization, archives, scripts and shader caches, creates the game window, and visibly renders the opening cinematic with a Space-to-continue prompt. | Menu content and gameplay unverified. Early presentation samples are about 5 FPS, then settle near 1 FPS in the cinematic, with long pauses. Manual Space presses reach the adapter queue but have not visibly continued the game; routing 4 GiB pools to software passes the earlier Foundation allocation failure and reaches further loading. Loader and call-wrapper unwind support clears the GOG rich-presence abort on the iPad: the call reports its service error and returns, and loading continues. The merged-main run logs a main-menu presence state; visual menu and gameplay validation remain pending. Tests use a 3600-second watchdog timeout and a two-CPU query cap. See [VM investigation](docs/CYBERPUNK_VM.md) and [software-memory experiment](docs/SOFTWARE_MEMORY.md). | [`cyberpunk-2077`](profiles/cyberpunk-2077) |
| MegaBonk (Steam, Windows x86-64) | 1.0.69 | iPad Pro M5, iPadOS 27 | Developer service | Visible main menu, imported Steam progress, user-confirmed playable run. Native Steam Cloud pulled three saves, uploaded both saves changed by that run, and passed independent byte-for-byte verification. Final clean-exit Cloud sync passes through an original physical Wine fixture. Saved Developer service mode startup passes after correcting the old Local signing choice. | Physical unplugged regular-library confirmation pending. User reported erratic camera mouse movement; confinement/recentering fix passes UIKit fixtures and physical Wine pointer-lock, exact recentering and release checks; manual camera feel validation pending. A run froze after about 8 minutes when FEX code buffers filled the 256 MiB code pool; the profile now uses 496 MiB (the Developer service caps the arena at 512 MiB) with 128 MiB buffers, long-session confirmation pending. Menus stepping down by themselves stopped with the game's VSync setting on (user-confirmed); no input reached Wine. Natural scrolling user-confirmed. Performance unmeasured. Simulator GPU lacks required D3D capabilities. | [Windows notes](docs/WINDOWS.md) |



## Steam client experiment (2026-10-14)

Windows Steam build 1788652215 renders its sign-in screen with readable labels
on iPad Pro M5 / iPadOS 27.0.1 using Developer service and the opt-in software
memory mode. Portable Wine Tahoma files and missing-family replacements were
required; the copied Mac font registry was unusable for DirectWrite. The QR
area remained loading in that run. After adding native-trust-filtered certificate
enumeration and DER export, the physical WinHTTP probe passed verified HTTPS;
Steam itself then downloaded and installed its 112,630 KB client update to
1791918634. Its automatic relaunch failed to allocate the second process
address-space window; a fresh updated-client launch subsequently connected and visibly reached
the sign-in screen with a populated QR code. The user subsequently authenticated successfully; Steam received LogOnResponse
OK and downloaded library metadata, but the visible account-loading screen
has not yet progressed to the library. A game download through Steam and
launching that download are **not verified**. No performance
claim follows from the sign-in screen. See [investigation](docs/SOFTWARE_MEMORY.md).

## Two-app Wine diagnostic (2026-10-14)

On iPad Pro M5 / iPadOS 27.0.1 using Developer service, the owned
`remote_handover_probe` passed a Windows child launch across two Tolkara apps,
64 MiB checksum computation, inherited-pipe result and exit-status verification.
Both runtimes detached before entry; the receiver used one finite UIKit
background allowance. This is not Steam startup, download, game launch or
sustained background execution. See [handover evidence](docs/MULTIPROCESS.md).

## GPUs without BC textures

macOS games use BC ("DXT") compressed textures, which only some iOS GPUs
sample. On an iPhone 15 Plus (A16), World of Warcraft Classic started, compiled
its shaders and then was stopped by Metal at its first BC3 texture. Since
2026-10-10, Tolkara stores BC textures uncompressed on such GPUs and decodes
them on the CPU, at 2 to 8 times the texture memory (see
[docs/IPHONE.md](docs/IPHONE.md#gpus-without-bc-textures-a16-and-older-iphones)).
With it, on 2026-10-10 the same iPhone logged in, entered the world and exited
cleanly; a longer session is still to be tried.

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


Steam iPad follow-up (2026-10-14, 12:54): implementing AppKit relative window
ordering made the authenticated Steam desktop visibly appear on the physical
iPad. Adapter simulator regressions pass. Store content remained black at
observation; Library interaction, game download and game launch remain
unverified. This result does not establish sustained two-app execution or game
performance.

Steam iPad follow-up (2026-10-14, 15:39): Library game names and artwork are
visibly rendered, but selecting Vampire Survivors and typing in search did not
respond. Device Hub successfully operates Tolkara's native Diagnostics menu.
Input routing or guest responsiveness remains unresolved; no game download or
launch is claimed. The unresponsive test instance was stopped, preserving its
log, while a separate CoreDevice file-service failure is investigated.

2026-10-14 physical Steam input follow-up: opt-in `--frontmost-guest-input` let Device Hub close Friends, open Library, select Vampire Survivors, open Downloads and navigate back. Downloads showed an empty queue and 0 bps. Vampire Survivors details remained at a loading indicator for several minutes; no download or game launch verified. CoreDevice app-container log copy still timed out; allowlisted live input console remained available.


2026-10-15 physical multiprocess follow-up (iPad Pro M5, Developer service):
Steam launches Vampire Survivors, but the game has not rendered successfully.
An owned two-process fixture reproduced a failure when the child called a
Wine builtin export address obtained in the parent. With the experimental
`WINEBUILTINCODEALIAS=1` metadata resolver, the same fixture returned the correct
child process ID and completed with exit 0. This establishes the narrow runtime
case only; successful game startup and performance remain unverified.
A separate active-stack teardown guard keeps Tolkara/Steam alive after the
game access violation by retaining the exiting slot's reservation and code pool
until host restart. Full safe reclamation after all threads stop remains work.
See [MULTIPROCESS](docs/MULTIPROCESS.md) for reproduction details.

The next physical Steam run with the builtin-address resolver passed the
previous foreign-kernel32 failure, loaded Vampire Survivors' Unity runtime,
and created a MoltenVK Vulkan instance. Unity then displayed “Failed to
initialize graphics”; game rendering is still unverified. A follow-up fix
propagates the per-process WINE_D3D_CONFIG into the child's Windows environment
so Wine DXGI can select Vulkan instead of unavailable OpenGL.

The graphics-environment propagation was verified on the iPad: Wine selected
Vulkan and DXVK initialized D3D_FEATURE_LEVEL_11_0. The game then exhausted its
4 GiB virtual range (3992 MiB of views; largest gap 92 MiB) and exited after a
roughly 512 MiB reservation failed. An 8 GiB game range with a nonoverlapping
browser range is under test. A rendered game menu is not yet verified.

2026-10-15 physical milestone: Vampire Survivors (Steam AppID 1794680,
BuildID 25016043), downloaded through Steam, now reaches its interactive main
menu through Steam in the single Tolkara app. Device Hub startup taps advanced
the warning and title screen. Required the experimental builtin code-address
resolver, child graphics-environment propagation, rebuilt Vulkan-capable
winemac helper, and Unity `-systemallocator -job-worker-count 2`. The allocator
option is debug-only. Display remains cropped; gameplay, performance and
long-run stability are not verified. No original game binary was modified.
The 8 GiB game/48 GiB browser experiment failed; this run restores the original
4 GiB game/52 GiB browser layout. See docs/MULTIPROCESS.md for evidence and
local reproduction bundle.

### Normal launch verified on the physical iPad

Opened Tolkara from its dock icon and selected the existing Steam (Windows)
library row, with no launch arguments or Mac launch script. Local Developer
service prepared 1020 MiB in 308.227 seconds. Steam connected, started Vampire
Survivors, and the game displayed its title and interactive main menu. A startup
tap advanced to the menu. This run fills the iPad display with letterboxing;
all main-menu buttons are visible, unlike the earlier windowed capture.
Evidence: /private/tmp/codex-steam-icon-after.log and Device Hub observations.
App is left running. Gameplay/performance remain untested.

User flow: open Tolkara, tap Steam (Windows), keep Tolkara foreground during
preparation, then Vampire Survivors starts automatically through Steam. Existing
iPad Developer-service setup is still required; no Mac script is needed. For a
fresh session, close Tolkara in the app switcher and reopen it.

2026-10-15 user gameplay follow-up: Vampire Survivors remains at Loading after
starting a stage. Runtime logs show stack-overflow exceptions and subsequent
access violations; underlying cause unconfirmed. Menu compatibility is proven,
playability is not. Steam profile auto-start was removed; game-specific launch
options now apply only when the user selects Vampire Survivors.

2026-10-15 Steam download follow-up: with opt-in Wine builtin retention under
WINEJITPOOLNOREUSE=1, Meccha Chameleon (4704690) finished its base installation
and Workshop update on the physical iPad. Steam's content log reported Fully
Installed and scheduler result No Error at 19:11:04. The original recording
shows a separate black background behind the Store dropdown. Adapter window
transparency handling now passes simulator tests and builds for iPad; physical
verification remains pending. Vampire Survivors stage-loading stack overflow
is still unresolved; menu entry is not gameplay validation.


2026-10-15 Steam/Vampire Survivors follow-up: normal catalog launch works, but
Steam menu blackout persists after the background/opacity adapter change.
Meccha Chameleon base and Workshop downloads completed with No Error. Vampire
Survivors stage loading reproduced an execute-fault recursion followed by stack
overflow. Used prepared code pages were returned after helper exit and reused
by the game despite permanent loss of execute permission on some pages. The
runtime now retires used pools until app exit; focused lifecycle tests pass.
Physical gameplay validation of this change is pending; see docs/MULTIPROCESS.md.

2026-10-16 follow-up: the physical retest with retired process pools no longer
showed the execute-fault recursion or stack overflow, but stage loading exhausted
the game's 200 MiB executable pool. A 300 MiB game allocation is installed but
has not reached a stage retest: current normal Steam launches stall during
startup. Low arena placement and Wine wait diagnostics are under investigation.
Vampire Survivors is not yet validated as playable.


### 2026-10-16 recovery status

An assistant cache-reset operation unexpectedly cleared Tolkara's app data container. Steam runtime/configuration recovery from local snapshots is partial and unverified. Previously recorded installed games are no longer present on the device; device-only saves have not been recovered. Vampire Survivors gameplay remains unverified. See docs/MULTIPROCESS.md for incident and recovery details.

2026-10-16 recovery and physical stage retest: local copies of Megabonk, Heroes III, Process Probe, both WoW profiles and Cyberpunk were copied back; six entry executables matched source SHA-256. This does not verify all assets, app launches or recovery of device-only saves. Fresh authenticated normal Steam launch completed a Vampire Survivors download. v1.16.111 entered Mad Forest and ran for 12 seconds to normal Game Over (stationary Gennaro, 10 enemies defeated). No stack-overflow, code-pool exhaustion or unhandled-exception entries in that runtime log; game live code views reached 182 MiB within its 300 MiB slice. Movement, sustained play and performance await user verification. Steam popup blackout and roughly five-minute preparation remain.

2026-10-16 user verification: user reports Vampire Survivors gameplay works great. On quitting, game exits with code 0 but Tolkara displays a white viewport instead of restoring Steam. A fresh local SaveData was verified and backed up; post-game Steam Cloud upload is unconfirmed. Return-to-Steam behavior remains open.

October 17 Steam/VS save verification: fresh save reloaded with 2155 coins; Steam cloud log confirms SaveData upload OK at 00:05:27. White viewport on game exit remains unresolved; Wine final-thread pipe cleanup now covers both normal and immediate exit paths, awaiting physical verification.

October 17 00:17: Wine exit pipe cleanup verified physically: game process disappears from server and Steam runs exit sync, uploading SaveData successfully immediately after quit. White viewport persists as a separate window lifecycle limitation. Game save reload verified with 2155 coins.

October 17 01:48: normal Vampire Survivors Quit now returns to Steam Library. Runtime confirms exit0 and game window70 retired for process3; Terraria Library page opened afterward, proving browsing remains responsive. Save reloaded with2155coins. Verified with original4GiB game range,950MiB code pool,4slots and native MoltenVK. Second-game launch in the same session is still unresolved. Evidence: /private/tmp/window-owner-normal-quit.log.

October 17, later second-launch investigation: the game briefly reached its
menu on relaunch, then native allocation failures froze the visible Steam
window. This is not a successful relaunch/playability result. Diagnostics
identified rapid host allocation growth while Steam was idle and repeated
process-info calls from the native Bluetooth HAL plugin. The opt-in
`TOLKARA_SESSION_AUDIO_ONLY=1` adapter avoids desktop HAL initialization and
uses the AVAudioSession output identity consistently with RemoteIO. In a
physical startup-only comparison, native heap usage settled near51MB and
198k blocks over16 ten-second samples, replacing growth of150–225k blocks
per sample. Per-call autorelease lifetime and session-device identity tests
pass in the simulator. Full game/audio and same-session relaunch validation
with this candidate are pending; startup-only stability does not prove them.

October 17 ~21:41 physical candidate follow-up: with session-only audio enabled,
Vampire Survivors reached its main menu, quit normally to Steam (Cloud Up to
date), and reopened in the same Tolkara process. Steam browsing was checked
by opening Terraria's Library page between launches. The second VS instance
opened Options and returned to its main menu; both launches produced nonzero
audio render buffers without callback errors. Save shows2155coins. User stage
play and audible output confirmation are pending. This six-slot configuration
supports the tested second launch; retained code pools do not establish
unlimited successive launches.

October17 ~21:43: user entered a stage in the second instance. Device Hub
observations show the timer advancing from00:08 to00:46 and level1 tolevel2,
with active rendering. No gameplay input was supplied by the agent. Current
log /private/tmp/reclaim-session-second-stage.log contains no stack-overflow
or native allocation exception. Subjective movement/performance/sound report
and longer-run stability remain pending.

2026-10-25 MegaBonk on the one generic build of main: a Steam-only build had
dropped MegaBonk's profile, so Wine found none of its libraries and exited at
start; with the profile built in, all 17 load. The 2026-10-16 restore had also
put back an old prefix with Wine's own d3d11.dll and the 2 October FEX DLLs,
so Unity reported "Failed to initialize graphics"; restoring DXVK's d3d11 and
d3d10core and the current FEX DLLs fixed it, and the user confirms the game
loads. The restore had not brought back Documents/SteamCloud/megabonk either;
with its config.json back, the first sync downloaded and verified all three
genuine Cloud saves, backing up the blank local ones. The login in the
Keychain survived the container reset.
The same evening the configuration moved into the MegaBonk profile's
steamCloud block (required), so a reset can no longer lose it. On the iPad
the installed build of main logged "Steam Cloud configuration from the
built-in profile" and synchronized all three files, uploading the latest
change. During play the minute-by-minute sync uploaded changes; twice the game
was writing a save mid-upload, and the sync stopped that pass (error 44)
without touching the file, uploading it on a later pass.

2026-11-16 Steam on the one build of main (iPad Pro M5, Developer service):
the profile committed on 25 October was an untested candidate that gave
Steam's browser 40 GiB; the browser exited with code 3 at every start
("Failed creating offscreen shared JS context"). With its 52 GiB range back
(0x71-0x7e) Steam starts, keeps its saved sign-in and shows the Store. Started
with `-applaunch` as a one-launch override, Steam ran its install script and
Vampire Survivors reached its first screen under the rules any program in
`steamapps\common` now gets. Not done today: input to a game, quitting to
Steam and a second game in one session (no way to touch the iPad from the
session that tested this).

What a start can still meet, all seen today:
- A launch whose free low-address gap is too small (1275 MiB once in five
  launches; 1615 are needed) used to prepare for nine minutes and then hang
  with the code pool at 0x7e00000000. It now stops at once and asks for
  Tolkara to be closed and opened again.
- When Steam installs its own update it starts itself again; the second
  steam.exe has no range and Tolkara ends. The update is in place and the
  next start works.
- Steam's own small dialogs ("Steam Service Error", "Steamwebhelper is not
  responding") come up as an empty grey window.
- Helper programs share one 4 GiB range, so an install script's children
  (cmd.exe, the Visual C++ installer) are refused while SteamService.exe
  runs. Vampire Survivors starts regardless; Meccha Chameleon, which needs
  that installer, was not started by Steam. A 1 GiB range per helper is too
  small for Wine (no room for its 32-bit window; SteamService exits 1).
- Process slots and code pool shares are used once: 1400 MiB allow two game
  starts in one session.

Downloading Steam on the device: the launcher code, the packer for the
Windows runtime and a 182 MB archive built with it exist; on the Mac the
download code unpacked that archive and fetched Valve's 246 MB of packages,
all checksums matching. The profile has no download block yet because the
archive is not published, so the iPad does not offer it, and a fresh
install has not been started on a device.

### 2026-11-16, later: Steam downloaded on the iPad

- `--download-profile=steam-windows --download-root=SteamTrial` beside the
  installed Steam: the Windows runtime from the GitHub release and Steam's
  packages from Valve arrived and were unpacked in about two minutes.
- Started with the profile's paths pointed at the trial (`--guest-environment=`
  for `WINEPREFIX`, `TOLKARA_CHDIR`, `WINEDLLDIR`, `WINEDATADIR`): Steam's own
  updater took the packages placed in `package/` (it fetched 2 MB more),
  installed itself and restarted, which ends the session; the next start
  reached the sign-in screen. Signing in was not tried.
- Runtime archive 1 was incomplete: without `volatile.reg` FEX stops at
  start ("Couldn't detect CPU features"), and without
  `Software\Wine\Fonts\Replacements` the sign-in screen has no labels.
  Archive 2 carries both; they were verified by placing the two files in the
  trial prefix by hand, not yet by downloading archive 2.
- The low-memory layout was too small in 5 of 8 starts this evening; such a
  start stops within seconds. A failed start now logs what occupies the
  2 GiB under the shared region.
- 2026-11-17: archive 2 (release `windows-runtime-2`, published with
  `tools/publish_windows_runtime.sh`) was downloaded on the iPad into
  `SteamTrial2`. With nothing placed by hand, the first start updated Steam
  and ended at its restart, and the next start showed the complete sign-in
  screen with labels and the QR code. Signing in was not tried.
- That second start needed three tries: two had a bad low-memory layout. The
  new log shows the space split near its middle (0x14a000000 and
  0x15e000000 in the two cases) by a group of 4 MiB malloc regions (tag 2)
  with 7 to 34 MiB mappings between them; what places them there is open.
