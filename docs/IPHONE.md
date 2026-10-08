# iPhone (experimental)

The same project builds for iPhone and iPad. On an iPhone the app runs in
landscape only. Testing so far: an iPhone 16 Pro Max with iOS 27, with
Developer service. Local signing and External JIT have not been tried on an
iPhone. See [COMPATIBILITY.md](../COMPATIBILITY.md) for what runs.

## Build and install

Follow [BUILDING.md](BUILDING.md); where it says iPad, read iPhone. Signing,
the required capabilities and the one-time enrollment are the same. With
`DEVICE` set to the iPhone in `local.env`:

```bash
NATIVE_GUEST_SHIMS=GENERIC tools/install.sh
tools/enroll.sh
```

or set `GUEST_EXE` for a build made for one application, as on the iPad. Keep
Tolkara in the foreground while memory is prepared at each launch. After
enrollment the iPhone launches games without the Mac, also after a reboot.

## Copy applications

Use the application's profile install script, as on the iPad. Tolkara's
Documents folder also appears in the Finder (your iPhone > Files) and in the
Files app under On My iPhone.

WoW Forever needs the settings of the beta's own installation: take `portal`,
`textLocale` and `audioLocale` from `_classic_beta_/WTF/Config.wtf` after you
have logged in on the Mac (the beta uses `portal "test"`), not from Classic Era.
It also needs the public system root certificates that a build on your own Mac
includes by default (`TOLKARA_SYSTEM_ROOTS=YES`; the published unsigned `.ipa`
has none). Login was refused (`BLZ51900003`) until both were right.

## Input

The [on-screen controls](TOUCH_INPUT.md), a keyboard button and a touch
trackpad, are shown by default on the iPhone. Turn them off or on with
**On-Screen Controls** under the hand button in the library's toolbar.

A Bluetooth keyboard works as on the iPad. A mouse works through
**Settings > Accessibility > Touch > AssistiveTouch**; in WoW Forever its left
click did not press in-game buttons, while a middle (wheel) click did. A game
controller has not been made to work at the WoW login screen.

## Limits

The launcher's screens were designed for the iPad and are not yet adapted to
a phone. Other iPhone models and iOS versions are untested; the iOS 17
deployment target is not a claim that they work.
