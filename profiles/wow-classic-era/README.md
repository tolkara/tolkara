# World of Warcraft Classic (Classic Era)

Tested with the macOS arm64 Classic Era client 1.15.x on an iPad Pro (M5).
An iPhone 16 Pro Max / iOS 27.0 reached the cinematic and login screen with
1.15.9 (build 70003) using Developer service; gameplay remains unverified. See
[COMPATIBILITY.md](../../COMPATIBILITY.md) for what works.

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/World of Warcraft/_classic_era_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic"
```

Build, install and set up your execution mode as described in
[docs/BUILDING.md](../../docs/BUILDING.md), then copy your installation:

```bash
python3 profiles/wow-classic-era/install.py
```

The script copies the client and the `Data` folder unchanged (tens of
gigabytes, so use a cable) and verifies the executable's hash before and after.
It copies only your region and language settings, not account settings, saved
credentials or add-ons. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh the client without copying `Data` again.

### Region and language before the first launch

The installer only copies `portal`, `textLocale` and `audioLocale` from the
Mac client's `_classic_era_/WTF/Config.wtf`, if present. It does not infer them
from the installation metadata. If the source client has not saved these
settings, the game may open `RegionPicker.nib`. Its window, controls and
bindings are not implemented by the AppKit adapter, and the tested client
returned from startup with an error.

Before copying a fresh installation, open the client normally on the Mac,
choose the intended region and installed text/audio languages, then close it
and check that its `Config.wtf` contains all three settings. The installer
copies only those allowed settings, not the account preferences. Alternatively,
after a failed launch has created `Config.wtf` on the device, update the
existing device file as follows. Close the game and Tolkara first so that
shutdown cannot overwrite the edit. Run these commands from the repository
root with your own `DEVICE` and `TOLKARA_BUNDLE_ID` in `local.env`:

```bash
bash <<'SH'
set -euo pipefail
. tools/localenv.sh
tolkara_load_env
: "${DEVICE:?Set DEVICE in local.env}"
: "${TOLKARA_BUNDLE_ID:?Set TOLKARA_BUNDLE_ID in local.env}"
mkdir -p build/iphone-config
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$TOLKARA_BUNDLE_ID" \
  --source 'Documents/World of Warcraft/_classic_era_/WTF/Config.wtf' \
  --destination build/iphone-config/Config.wtf
cp build/iphone-config/Config.wtf build/iphone-config/Config.wtf.backup
SH
```

Edit `build/iphone-config/Config.wtf` in a text editor. Set one nonempty line
for each key below, replacing the placeholders with your own region and locale
codes. Preserve all other lines and replace existing entries rather than
adding duplicates. Choose languages actually present in your Mac installation;
the active Classic Era row of `.build.info` records its installed languages.

```text
SET portal "<region>"
SET textLocale "<installed text locale>"
SET audioLocale "<installed audio locale>"
```

Setting only `portal` did not resolve the tested failure. Setting all three
consistently allowed the client to reach its cinematic and login screen.
Copy the edited file back and verify it:

```bash
bash <<'SH'
set -euo pipefail
. tools/localenv.sh
tolkara_load_env
: "${DEVICE:?Set DEVICE in local.env}"
: "${TOLKARA_BUNDLE_ID:?Set TOLKARA_BUNDLE_ID in local.env}"
xcrun devicectl device copy to --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$TOLKARA_BUNDLE_ID" \
  --source build/iphone-config/Config.wtf \
  --destination 'Documents/World of Warcraft/_classic_era_/WTF/Config.wtf'
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$TOLKARA_BUNDLE_ID" \
  --source 'Documents/World of Warcraft/_classic_era_/WTF/Config.wtf' \
  --destination build/iphone-config/Config.wtf.readback
cmp build/iphone-config/Config.wtf build/iphone-config/Config.wtf.readback
SH
```

Keep these copies private in the ignored `build/` directory. This is a
configuration workaround, not an implementation of the region selector.

### Launch and input

Open Tolkara, choose an execution mode if it asks, tap World of Warcraft Classic
in the library (it appears once the files are copied), and log in inside the
game as usual.

On iPhone, `SET GamePadEnable "1"` was also tried, but controller operation
has not been established. It is not required for the region workaround.
Installing ConsolePort does not establish that login or other pre-character
screens can be controlled with a gamepad. Do not enable the experimental
`GameController` adapter to fix this: that adapter reports no controllers.

**Execution mode.** The execution modes are described in the
[README](../../README.md#three-ways-to-run-code); choose one. This client has been
played with Developer service, and with Local signing it logs in and plays
(2026-09-27) with no debugger, helper or tunnel. This client unpacks its
own code at launch, so its page container must be built from a capture of its
final code pages, which Tolkara cannot produce yet.

Start with modest graphics settings; quality 8 at 50% render scale held 120 FPS
on the M5. Voice chat does not work.

**Account risk.** Tolkara is not supported by Blizzard. Blizzard has
historically tolerated Wine and Proton players, and Tolkara works the same way,
but nothing guarantees that for your account. With Local signing, Tolkara also
keeps a derived copy of the game's unpacked code on your iPad, signed under your
own developer identity. That modifies nothing Blizzard ships, but whether it is
acceptable is still for Blizzard's licence terms to decide. The risk of a
suspension or ban is yours alone. Consider testing with a free Starter account
first.
