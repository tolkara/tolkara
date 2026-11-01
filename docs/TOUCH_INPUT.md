# On-screen controls

Optional on-screen controls over a game, for a device without a keyboard or
mouse, modelled on the Windows App's (Microsoft Remote Desktop) mouse pointer
mode. They are shown by default on iPhone and hidden on iPad;
**On-Screen Controls**, under the hand button in the library's toolbar, turns
them on or off from the next game start. Without them, touches act as before:
a touch is a left click where the finger is.

Three translucent buttons sit at the bottom right of the game: the movement
stick, the trackpad and the keyboard. Only the buttons take touches; the rest
of the screen belongs to the game.

**iPhone Duo.** Unfolded, the inner display keeps a strip at one side for the
status bar (UIKit reports it as an occlusion reserved region, iOS 27.1). There
the buttons stand in a column in that strip, under the status bar, as Apple's
own bars do: keyboard, stick, trackpad, then **1** to **5**; **6** to **0**
stand in a matching column at the opposite edge. A number button holds its key
(a US keyboard's 1 to 0, e.g. a game's action slots) for as long as it is
touched. The buttons shrink, down to 34 points, to fit; with the iOS keyboard
open, those that no longer fit are hidden from the bottom up. Once found, the
strip stays for that screen size: on the device UIKit stops reporting it when
the game hides the status bar. The game still draws under both columns. Other
screens keep the row and have no number buttons. Tolkara logs which layout it
chose, and whether iOS accepted a keyboard request and how tall the keyboard
came up (with a hardware keyboard connected, iOS shows only the row above it).

**Movement stick.** The stick button turns it on (cyan) or off; the choice is
kept, and it is on by default on iPhone. With it on, a touch that lands on the
left half of the game becomes a stick centred where the finger landed, and the
right half is the trackpad. Sliding the finger holds W, A, S or D; a diagonal
holds two of them, lifting releases them all, and past the stick's rim its
centre follows the finger. A touch keeps the half it landed on, so the stick
and the trackpad work at the same time (walking while turning the camera). A
second touch on the left half while the stick is held is ignored. The stick
needs trackpad mode: turning it on turns trackpad mode on, and turning
trackpad mode off turns it off. The keys are those of a US keyboard's W, A, S
and D; what they do is the game's binding (World of Warcraft turns with A and
D, and strafes with them while the right button is held).

**Trackpad.** The hand button turns trackpad mode on (cyan) or off; the choice
is kept. The finger moves the pointer by its motion, like a laptop's trackpad:
where it lands does not matter, and a tap clicks where the pointer is, not
under the finger. Motion is accelerated with the finger's speed: slow motion
moves the pointer a little less than the finger, for aiming, and a quick flick
up to two and a half times as far. Long-press the hand button for a menu with
left, right and middle click.

| In trackpad mode (the right half, with the stick) | Mouse input |
| --- | --- |
| Slide one finger | Moves the pointer by the finger's motion; lifting and placing the finger elsewhere does not move it. |
| Tap / tap twice | Left click / double click |
| Double tap and hold, or double tap and slide | Holds the right button until the finger lifts, e.g. to steer the camera |
| Hold one finger still about half a second | Right click |
| Tap with two fingers | Right click |
| Tap with three fingers | Middle click |
| Slide two fingers | Scroll, vertically or horizontally |
| Hold two fingers about half a second, then slide | Drag with the right button held |

A double tap's second touch must start within 0.3 s of the first tap and near
it; if it lifts again quickly without moving, it is a double click instead. In
the Windows App, a one-finger double tap and hold drags with the left button;
here it holds the right button, which a game's camera needs more often, and
there is no one-finger left drag (the hand button's menu still clicks).

A cancelled touch, a rotation, switching apps or turning trackpad mode off
releases a button the trackpad was holding and every key the stick or a
number button was holding. A keyboard and mouse work at the same time as before.

**Keyboard.** Opens and closes the iOS keyboard; the game keeps its size. A row
above the keyboard has Escape, Tab, left and right arrows, Return and a button
to close it. Select a text field in the game first: Tolkara does not detect
the game's text fields, and it does not read the game's text or selection, so
the keyboard does not open by itself. Typed text reaches the game as key
presses, with macOS key codes for the characters of a US keyboard. The keyboard
is set up as a password field, so iOS offers no predictions or corrections; it
also offers no dictation or third-party keyboards, and may limit other input
methods.

## Tests

`tools/test_emulation.sh` runs the trackpad's and the stick's finger traces
and the text-to-key mapping; `tools/test_translation_sim.sh` checks event
delivery in the simulator, including the stick's keys. `tools/test_touch_controls_ui.sh`
opens our own test screen (never a game) in the simulator; `--self-test`
checks the keyboard's placement, typing and returning focus, then drives the
stick and the trackpad's tap, double tap and hold, two-finger tap and scroll
with synthetic points, and `--show-keyboard` opens the keyboard to look at.
With `SIMULATOR` naming an iPhone Duo simulator (iOS 27.2 runtime), it also
checks the side-strip columns with all thirteen buttons.
