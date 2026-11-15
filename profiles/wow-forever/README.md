# World of Warcraft Forever

The released macOS arm64 client (1.60.1) from `_forever_` (Battle.net product
`wowf`). Until November 2026 this profile ran the Classic beta from
`_classic_beta_`; the results in [COMPATIBILITY.md](../../COMPATIBILITY.md) were
made with that beta.

It also logs in and plays on an iPhone (experimental); see
[docs/IPHONE.md](../../docs/IPHONE.md).

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
```

Build, install and set up your execution mode as described in
[docs/BUILDING.md](../../docs/BUILDING.md), then copy your installation:

```bash
python3 profiles/wow-forever/install.py
```

The script copies the client and the `Data` folder unchanged (tens of
gigabytes, so use a cable) and verifies the executable's hash before and after.
It copies only your region and language settings, not account settings, saved
credentials or add-ons. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh the client without copying `Data` again.

**Start the game once on the Mac first.** The client needs the region and
languages it saves the first time Battle.net starts it (`portal`, `textLocale`
and `audioLocale` in `_forever_/WTF/Config.wtf`). A copy that never started on the
Mac has none, and on the device the game then asks for a region in a window the
AppKit adapter cannot show yet, so it quits within a second. Before you copy:
in Battle.net choose the game and your region, click Play, wait for the
character list, and quit the game. The script stops with these steps when the
settings are missing (unless the device already has them). It sets only these
three keys in the device's own `Config.wtf`, so graphics settings made on the
device stay. To change region or language later, start the game once on the
Mac again and run the script with `--skip-data` (in Tolkara Management:
Library, then **Copy Again**). Tolkara Management checks this on its Game step.

## Without a Mac (experimental)

In the launcher, **+** offers **Download World of Warcraft Forever…** while
the game is not in Tolkara's folder. After the notice about online games you
choose your region and language, and Tolkara fetches the game's application
(about 200 MB) from Blizzard's content servers, which need no account. It
writes the region and languages itself, so nothing has to be started on a
Mac. The game then downloads its data when it first starts and shows its
progress; World of Warcraft's data is tens of gigabytes, so use Wi-Fi and
keep Tolkara open. A download that was stopped continues where it left off.

Tested so far: the fetched application is byte for byte the one Battle.net
installs on a Mac (build 1.60.1.70938, Europe, enUS, 2026-11-15), and a copy
with no data reached the login screen on an iPad Pro M5 after the game
fetched its own. Not yet tried: a start from files the launcher fetched and
wrote itself, logging in from such a copy, and any region or language but
those.

Open Tolkara, choose an execution mode if it asks, tap World of Warcraft Forever
in the library (it appears once the files are copied), and log in inside the
game as usual.

**Execution mode.** The execution modes are described in the
[README](../../README.md#three-ways-to-run-code); choose one. With Local signing,
the client logs in and plays on an iPad Pro M5 (2026-09-27), with no debugger,
helper or tunnel: the unpacked code matched the signed page container byte for
byte and all 13,280 initializers ran into the original `main`. With
Developer service it has been played on an iPhone, not yet on an iPad.
Like the Era client, this client unpacks its own code at launch, so its Local
signing page container must be built from a capture of its final code pages —
producing such a capture in the app is not wired yet (see
[docs/LOCAL_AUTHORIZATION.md](../../docs/LOCAL_AUTHORIZATION.md)).

Start with modest graphics settings.

**Account risk.** Tolkara is not supported by Blizzard. Blizzard has
historically tolerated Wine and Proton players, and Tolkara works the same way,
but nothing guarantees that for your account. With Local signing, Tolkara also
keeps a derived copy of the game's unpacked code on your iPad, signed under your
own developer identity. That modifies nothing Blizzard ships, but whether it is
acceptable is still for Blizzard's licence terms to decide. The risk of a
suspension or ban is yours alone. Consider testing with a free Starter account
first.
