# iPhone (experimental)

The same project builds for iPhone and iPad. On an iPhone the app runs in
landscape only. Testing so far: an iPhone 16 Pro Max and an iPhone 15 Plus
(A16) with iOS 27, with Developer service. Local signing and External JIT have not been tried on an
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

The [on-screen controls](TOUCH_INPUT.md), a movement stick on the left half
(W, A, S and D), a touch trackpad on the right half and a keyboard button, are
shown by default on the iPhone. Turn them off or on with
**On-Screen Controls** under the hand button in the library's toolbar.

A Bluetooth keyboard works as on the iPad. A mouse works through
**Settings > Accessibility > Touch > AssistiveTouch**; in WoW Forever its left
click did not press in-game buttons, while a middle (wheel) click did. A game
controller has not been made to work at the WoW login screen.

## GPUs without BC textures (A16 and older iPhones)

Every Mac GPU samples the BC ("DXT") compressed texture formats, so macOS games
create BC textures without asking. On iOS that depends on the GPU: Metal
reports it per device (`supportsBCTextureCompression`). The iPhone 16 Pro Max
(A18 Pro) and the M-series iPads have it; the iPhone 15 Plus (A16) and older
A-series GPUs do not, and there Metal aborted World of Warcraft Classic as soon
as it created its first BC3 texture.

On such a device the Metal adapter now creates each BC texture in an
uncompressed format instead (RGBA8, sRGB kept; R8 or RG8 for BC4/BC5; RGBA16
float for BC6H) and decodes the game's uploads on the CPU: `replaceRegion:`,
blit copies from a buffer (decoded when the command buffer is committed),
copies between such textures, texture views and heap textures. The game still
sees the BC format it asked for, and the device reports BC support to it as a
Mac would. The log says once `Metal BC fallback on` and, at the first such
texture, `Metal BC fallback engaged`. Devices with BC support are unchanged:
nothing is installed there. Details and the routes that are not covered are at
the top of `translation/Metal/BCTextures.m`.

The cost is memory and loading time. Uncompressed textures take more GPU
memory than the BC data: 8 times for BC1 and BC6H, 4 times for BC2, BC3 and
BC7, twice for BC4 and BC5. Games use BC1 and BC3 for most textures, so plan
on 4 to 8 times the texture memory of the same settings on a Mac or a newer
device, and on an iPhone with 6 GB or less lower the game's texture
resolution first. Each upload is decoded once, on the thread that makes it.

`TOLKARA_BC_FALLBACK` sets it (a profile's `environment`, or the development
launch argument `--guest-environment=TOLKARA_BC_FALLBACK=on`): `auto`, the
default, engages only without BC support; `on` forces it on a device with BC,
to test it there; `off` never engages. The fallback passes the Mac tests
(decoders checked against the Mac GPU, every upload route with the fallback
forced on). On 2026-10-10 an iPhone 15 Plus (A16) ran World of Warcraft Classic
with it through login and into the world, then exited cleanly; a longer session,
frame rate and memory use are still to be checked.

## Limits

The launcher's screens were designed for the iPad and are not yet adapted to
a phone. Other iPhone models and iOS versions are untested; the iOS 17
deployment target is not a claim that they work.
