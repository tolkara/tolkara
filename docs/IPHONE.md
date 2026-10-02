# Experimental iPhone support

Tolkara can be built for both iPhone and iPad from the same project. The
physical iPhone result is limited to an iPhone 16 Pro Max running iOS 27.0
with Developer service. On 2026-10-02 the user confirmed login and about two
hours of gameplay in World of Warcraft Forever 1.60.1 (build 70170) without
problems, reporting 60 FPS at 50% render scale and graphics quality 2. A
Bluetooth keyboard and AssistiveTouch were used for that initial session.
The user subsequently confirmed the new iOS keyboard and touchscreen trackpad
working in Forever on the same iPhone. Classic Era 1.15.9 (build 70003) reached
its cinematic and login screen.
See [COMPATIBILITY.md](../COMPATIBILITY.md) for the recorded results.

## Build and install with your own settings

Use a checkout containing the iPhone changes. Install Xcode, XcodeGen and
Python 3, then follow the prerequisites, Developer Mode and signing steps in
[BUILDING.md](BUILDING.md). The device used here is the connected iPhone.
The existing signing/capability requirements also apply on iPhone.

From the repository root, create `local.env` from `local.env.example` once
and fill in your own `DEVELOPMENT_TEAM`, a unique `TOLKARA_BUNDLE_ID`, and
`DEVICE`. Keep this file private; it is ignored by Git. For a generic build
using the execution mode tested on iPhone, set `TOLKARA_MODE=developer-service`
there, leave `GUEST_EXE` unset, and run:

```bash
NATIVE_GUEST_SHIMS=GENERIC tools/install.sh
tools/enroll.sh
```

The first command generates the project, builds and signs Tolkara and its
extension, then installs the app. The second performs the one-time enrollment
over the trusted USB connection. Unlock the phone and approve its enrollment
and tunnel prompts as described in the building guide. Keep Tolkara in the
foreground during memory preparation.

To use Xcode directly after configuring `local.env`:

```bash
tools/generate.sh
open Tolkara.xcodeproj
```

Select the **Tolkara** scheme and your iPhone as the destination. Set your
team for both **Tolkara** and **LocalAuthorizationTunnel** if Xcode reports a
signing error. Keep **Debug executable** disabled in the scheme. The
extension's scheme is not the app's normal launch entry point. Regeneration
replaces manual project settings; store persistent personal values in
`local.env`, not in tracked files.

Developer service uses the device's own service to prepare executable memory
before guest entry. After enrollment, the user confirmed a cold launch after
reboot with the iPhone disconnected from the Mac. Local signing and External
JIT were not tested on this iPhone.

## Copy applications and configure Classic Era

Open Tolkara once. With the phone connected, Finder > your iPhone > Files
should list **Tolkara**; the same Documents folder is exposed in Files > On
My iPhone > Tolkara. Creating an unrelated folder with that name does not
register the app for file sharing. Update the installed app if it lacks the
file-sharing keys; installing over the same bundle ID preserves its data.

Use an application's profile installer when available. For Classic Era, copy
your own Mac installation, including the shared `Data` directory:

```bash
python3 profiles/wow-classic-era/install.py --source '/Applications/World of Warcraft'
```

The script reads your device and bundle ID from `local.env`; adjust `--source`
for your installation. It copies the game unchanged and only allows the three
region/language settings through from the Mac config. It does not copy account
preferences, saved credentials or addons.

Before launching, follow the profile's
[region and language instructions](../profiles/wow-classic-era/README.md#region-and-language-before-the-first-launch).
All three of `portal`, `textLocale` and `audioLocale` must be populated
consistently with your chosen region and installed languages to avoid the
unsupported region selector in the tested client. These values are local
game configuration, not defaults in Tolkara's source. The controller setting
and addon experiment are separate from the successful startup workaround.

For Forever, take these settings from the beta's own
`_classic_beta_/WTF/Config.wtf` after a successful manual login on the Mac.
Do not carry over Classic Era's `portal` value just because the account region
is the same: the working Mac beta build 70170 used `portal "test"`. A different
portal on the iPhone was found while investigating a login rejection. Match the
working beta installation's setting with Tolkara closed, preserving all other
iPhone preferences; no account data or Battle.net session needs to be copied
for this configuration change.

## Public system certificates

Keep the default `TOLKARA_SYSTEM_ROOTS=YES` when building privately on your
own Mac. This packages public system root certificates for the macOS
Security adapter. It does not export personal keychain contents or private
keys, and iOS still checks root trust with its own policies. The published
redistributable build deliberately uses `NO`; copying that choice to a
private build leaves the adapter without this resource. It was missing from
the initial iPhone build; successful Forever login and gameplay were confirmed
after rebuilding with it and using the beta's own portal setting.

## Mouse, controller and keyboard

The initial Forever setup used a **Bluetooth keyboard** and
**Settings > Accessibility > Touch > AssistiveTouch**. Both Classic Era and
Forever required AssistiveTouch for the tested physical mouse setup.

In Forever, left mouse click did not activate the tested controls. Pressing
the mouse wheel (middle click, not scrolling) worked and allowed controller
support to be enabled. The controller then navigated the menus. A Bluetooth
keyboard was needed to enter account details. Forever gameplay is now
confirmed. Classic Era's controller and ConsolePort tests remain inconclusive; see
[COMPATIBILITY.md](../COMPATIBILITY.md#iphone-validation-2026-10-01).

This branch adds [iOS keyboard and touchscreen trackpad controls](TOUCH_INPUT.md),
including two-finger scrolling. Their synthetic and simulator tests pass, and
on 2026-10-02 the user confirmed the new controls working correctly in Forever
on the physical iPhone 16 Pro Max / iOS 27.0. The Bluetooth keyboard and
AssistiveTouch observations above describe the earlier setup. Input on other
devices and applications remains unverified.

## What changed in the project

| Change | Effect |
| --- | --- |
| `TARGETED_DEVICE_FAMILY: "1,2"` | App and helper targets admit iPhone as well as iPad. |
| iPhone landscape orientation keys | Both landscape directions are supported; iPad's four orientations are preserved. |
| Explicit shared `Tolkara` scheme | The main app is selectable in Xcode and launches without an attached debugger. |
| `NATIVE_GUEST_SHIMS: GENERIC` in `AppBase` | Direct Xcode builds include the compatibility libraries. The command-line installer still supports application-specific builds. |
| `UIFileSharingEnabled` in both app plists | File sharing is present in the built apps, replacing the ineffective build-setting-only declaration. |

The runtime architecture and original game executables are unchanged by the
iPhone configuration. A separate loader fix replaces the fixed one-million
legacy rebase limit with an image-sized work budget, including checks before
repeated operations. Synthetic tests cover large streams, cumulative counts,
repeated targets and oversized counts. It let Palworld reach its initializers
and original `main`, but Palworld still stopped afterwards; gameplay is not
supported by that result.

## Validation and remaining limits

Validation on 2026-10-01–02 used Xcode 26.6, the iOS 26.5 SDK and XcodeGen 2.46.0:

- Device arm64 and iPhone simulator builds completed successfully. The
  simulator launched the library/mode UI, not a game.
- The built app and extension declare device families `[1, 2]`. The app has
  the iPhone landscape keys, preserves iPad orientations and exposes file
  sharing. The generic app contains ten compatibility libraries.
- A signed build installed on the physical iPhone. Developer service
  authenticated its tunnel and prepared executable memory. Classic Era ran
  all 12,658 initializers and reached the cinematic and login screen; memory
  preparation took approximately 53–55 seconds in the recorded attempts.
- On 2026-10-02 the user confirmed Forever 1.60.1 (70170) login, world entry
  and about two hours of gameplay without problems: 60 FPS at 50% render
  scale and graphics quality 2. Mouse use with AssistiveTouch, controller
  menu navigation after enabling it with middle click, and a cold launch
  after reboot without a Mac connection are also confirmed.
- The private build includes 158 public system certificate candidates. The
  existing certificate-adapter test passed with ASan/UBSan on the Mac.
- The loader's focused tests passed with ASan/UBSan. `tools/test_emulation.sh`
  still fails at
  `tests.test_sign_guest_local.AdhocTests.test_matches_codesign_byte_for_byte`
  (`differs from codesign -s - for sgl-fixture.dylib`). The same failure was
  reproduced on unchanged base commit `199da9e`; the remaining suite was run
  separately and passed. The full suite is not green. Optional identity-based
  signing tests and Metal compiler integration were not enabled.

Other iPhone models and OS versions and iPad regressions on hardware remain
unverified. The two-hour gameplay report covers one Forever session and its
settings, not every game area or activity. The iOS 17 deployment target
is not a tested-device support claim. The interface still has some iPad
wording; this change is not a complete phone-specific UI redesign.

For contributions, commit source, documentation and synthetic tests only.
Keep generated Xcode projects, `local.env`, build products, raw device logs,
game configurations, application files, signing material and pairing records
out of the PR. Hardware model, OS and game version are sufficient context for
a compatibility report; device names and identifiers are not needed.
