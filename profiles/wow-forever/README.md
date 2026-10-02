# World of Warcraft Forever (Classic beta)

The macOS arm64 Classic beta client (1.60.1) from `_classic_beta_`. See
[COMPATIBILITY.md](../../COMPATIBILITY.md) for what works.

On an iPhone 16 Pro Max / iOS 27.0, build 70170 was tested with Developer
service on 2026-10-02: the user reported successful login and about two hours
of gameplay without problems at 60 FPS, 50% render scale and graphics quality
2. That session used a Bluetooth keyboard and AssistiveTouch. See the
[iPhone guide](../../docs/IPHONE.md) for the beta portal,
public certificate resource and mouse/controller setup. Experimental
[iOS keyboard and trackpad controls](../../docs/TOUCH_INPUT.md) are now
implemented in this branch; the user subsequently confirmed them working
correctly in Forever on the same iPhone (2026-10-02).

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/World of Warcraft/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft"
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

Open Tolkara, choose an execution mode if it asks, tap World of Warcraft Forever
in the library (it appears once the files are copied), and log in inside the
game as usual.

**Execution mode.** The execution modes are described in the
[README](../../README.md#three-ways-to-run-code); choose one. With Local signing,
the client logs in and plays on an iPad Pro M5 (2026-09-27), with no debugger,
helper or tunnel: the unpacked code matched the signed page container byte for
byte and all 13,280 initializers ran into the original `main`. Developer
service login and gameplay are also confirmed on the iPhone described above;
Developer service has not been validated on this iPad.
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
