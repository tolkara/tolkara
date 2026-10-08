# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service, Local signing or External JIT), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). Memory preparation at each launch (about 80 s before the 2026-09-27 speed-up; not re-measured since). Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.9 | iPhone 16 Pro Max, iOS 27 | Developer service | Startup, opening cinematic and login screen. | Experimental; login and gameplay not yet tried. A client without a saved region and language opens a region picker the AppKit adapter cannot show (see the profile). About 55 s of memory preparation. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`. | Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`. | Developer service not yet validated on this iPad. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPhone 16 Pro Max, iOS 27 | Developer service | Login, world entry and about two hours of play (2026-10-02) with a Bluetooth keyboard and an AssistiveTouch mouse, at 60 FPS, graphics quality 2 and 50% render scale. The on-screen keyboard and touch trackpad worked in a later session. Launch without a Mac, including after reboot. | Experimental. Needs the beta's own `portal "test"` setting and a build with the system root certificates (the default); see [docs/IPHONE.md](docs/IPHONE.md). With AssistiveTouch, a left click did not press in-game buttons; a middle click did. | [`wow-forever`](profiles/wow-forever) |
| Heroes of Might and Magic III: Horn of the Abyss (GOG, Windows x86, with the HD mod) | HotA 1.8.1, HD mod 5.8 | iPad Pro M5, iPadOS 27 | Developer service | New games on scenario maps: adventure map, towns, battles, AI turns with up to eight players over several days, saving and loading, music and sound, mouse and keyboard. Runs through Tolkara's builds of Wine and FEX, with the HD mod's GDI renderer. | Local signing cannot run it (FEX translates the game's code while it runs). About 33 s of memory preparation per launch. A double click is not recognised (Enter opens a selected town). Light grey margins when the HD mod letterboxes the game. Saving fails if launched with the development option `--case-insensitive-files`. Performance not measured. | [`heroes3-hota`](profiles/heroes3-hota) |
| Cyberpunk 2077 (GOG, macOS arm64) | 2.3.x (buildId 59052989568257053) | iPad Pro M5, iPadOS 27 | Developer service | Experimental software-memory mode completes all 6,540 initializers, main, GOG initialization, archives, scripts and shader caches, creates the game window, and visibly renders the opening cinematic with a Space-to-continue prompt. | Menu content and gameplay unverified. Early presentation samples are about 5 FPS, then settle near 1 FPS in the cinematic, with long pauses. Manual Space presses reach the adapter queue but have not visibly continued the game; routing 4 GiB pools to software passes the earlier Foundation allocation failure and reaches further loading. Loader and call-wrapper unwind support clears the GOG rich-presence abort on the iPad: the call reports its service error and returns, and loading continues. The merged-main run logs a main-menu presence state; visual menu and gameplay validation remain pending. Tests use a 3600-second watchdog timeout and a two-CPU query cap. See [VM investigation](docs/CYBERPUNK_VM.md) and [software-memory experiment](docs/SOFTWARE_MEMORY.md). | [`cyberpunk-2077`](profiles/cyberpunk-2077) |

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
