# On-screen controls

Optional on-screen controls over a game, for a device without a keyboard or
mouse, modelled on the Windows App's (Microsoft Remote Desktop) mouse pointer
mode. They are shown by default on iPhone and hidden on iPad;
**On-Screen Controls**, under the hand button in the library's toolbar, turns
them on or off from the next game start. Without them, touches act as before:
a touch is a left click where the finger is.

Four translucent buttons sit at the bottom right of the game: Jump, the
movement stick, the trackpad and the keyboard. Jump holds Space for as long as
it is touched. Only the buttons take touches; the rest
of the screen belongs to the game.

**iPhone Duo.** Unfolded, the inner display keeps a strip at one side for the
status bar (UIKit reports it as an occlusion reserved region, iOS 27.1). The
buttons stand in a column in that strip and in one mirroring it at the other
edge. Each column is only as wide as the buttons need (56 points, against the
screen's edge; the strip itself is 84), so the game keeps the rest. Both
start below the status bar as Apple's own bars do: on the right Escape, Tab (e.g. to select a target), **1** to **5** and Jump at the bottom; on
the left the keyboard, stick, trackpad and Shift buttons and **6** to **0**. Key
buttons hold their key (a US keyboard's) for as long as they are touched. The
buttons shrink, down to 34 points, to fit; with the iOS keyboard open, those
that no longer fit are hidden from the bottom up. Once found, the strip stays
for that screen size: on the device UIKit stops reporting it when the game
hides the status bar. The game draws only between the two columns, which keep
a black background, and sees a display that size (`NSScreen`,
`CGDisplayBounds`), as a Mac whose screen ends where the columns begin; with
the iOS keyboard open it keeps that size. Other screens keep the row over the
game, without number, Escape and Tab buttons.

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

**Camera mode.** A game whose profile sets `TOLKARA_TOUCH_MODE=camera` (both
World of Warcraft profiles) starts in camera mode, made for games played with
the mouse's right button. Touches on the game act where they land, with no
pointer to steer:

| Gesture | Effect |
| --- | --- |
| Slide one finger | Holds the right button and turns the camera with the finger, until it lifts |
| Tap one finger | Right click where it touched (attack, talk, loot) |
| Hold one finger still 0.4 s (a tick), then slide | Drags with the left button, the pointer under the finger, until it lifts: moves a spell or an item |
| Slide two fingers | Scroll (zoom the camera) |
| Tap two fingers | Left click between them |

The pointer goes to the finger as it lands, so the game knows what is under
it before any click, and the right button goes down with the first movement
iOS reports. It is not pressed at the touch itself: a two-finger gesture whose
second finger lands a moment later would otherwise right-click whatever was
under the first. It goes down in the middle of the game's view, not under the
finger: a slide that starts on a part of the game's interface (a quest list
where the thumb rests) turns the camera all the same and clicks nothing. No
pointer is drawn in camera mode, except during a left drag, when the game
shows what is being carried on it. A finger held still and lifted without
sliding does nothing, so a resting thumb clicks nothing. The camera turns three
times the finger's motion, as with the trackpad's right drag. For menus and
bags, the hand button (a camera icon in camera mode)
switches to cursor mode, the trackpad below (a cyan pointer icon), and back;
the choice is kept. The stick works in both. Other games have no camera mode:
for them the hand button turns the trackpad on and off, as below.

**How motion starts.** iOS reports nothing while a finger that has just
landed moves a short way, and then reports its position all at once: that is
how the system tells a tap from a drag, and an app cannot turn it off. Tolkara
therefore adds almost no threshold of its own (3 points in camera mode, none
for the pointer) and does not pass that first jump on: a gesture's first step
is limited to 2 points and each following step to twice the one before, for
0.08 s. A slide starts gently instead of standing still and then jerking; a
slow slide loses nothing. Motion is never collected to be sent later: each
step reaches the game as it happens, as a mouse's would, also in the frame or
so before a game captures the pointer for its camera. A tap's click lasts at
least 0.06 s, long enough for a game that reads the buttons once a frame.
Tolkara logs each of a session's first gestures (when iOS first reported
movement, the size of the first steps, how far it went) and each right-button
drag (its steps, total, largest step, the game's pointer warps and how long
the capture took), in points and milliseconds, never what is on screen.

**Trackpad.** The hand button turns trackpad mode on (cyan) or off; the choice
is kept. The finger moves the pointer by its motion, like a laptop's trackpad:
where it lands does not matter, and a tap clicks where the pointer is, not
under the finger. Motion is accelerated with the finger's speed: slow motion
moves the pointer a little less than the finger, for aiming, and a quick flick
up to two and a half times as far; the speed is averaged over about a
twentieth of a second, so touch samples that arrive unevenly do not make the
pointer lurch. While the right button is held (double tap and slide, or two
fingers held then slid), which turns a game's camera, motion is instead three
times the finger's at any speed, so the camera turns evenly. A game that does not capture the pointer for its
camera (World of Warcraft) reads each event's motion, which is therefore sent
whole even when the pointer has reached the window's edge, as a Mac's mouse
does; the camera does not stop there.
Long-press the hand button for a menu with left, right and middle click.

| In trackpad mode (the right half, with the stick) | Mouse input |
| --- | --- |
| Slide one finger | Moves the pointer by the finger's motion; lifting and placing the finger elsewhere does not move it. |
| Tap | Left click |
| Double tap and hold, or double tap and slide | Holds the right button from the second touch until the finger lifts, e.g. to steer the camera |
| Hold one finger still 0.4 s (a tick), then slide | Drags with the left button from where the pointer is, until the finger lifts |
| Tap with two fingers | Right click |
| Tap with three fingers | Middle click |
| Slide two fingers | Scroll, vertically or horizontally |
| Hold two fingers 0.4 s, then slide | Drag with the right button held |

A double tap's second touch must start within 0.3 s of the first tap and near
it. The right button goes down as that touch lands, so the camera turns with
the first movement; lifting it again quickly is therefore a right click, not a
double click. In
the Windows App, a one-finger double tap and hold drags with the left button;
here it holds the right button, which a game's camera needs more often; the
left drag is hold, then slide. A finger held and lifted without sliding does
nothing. The Shift button (in the column layout) holds Shift while touched,
for the mouse as for keys: with a drag it moves a spell on a locked bar.

A cancelled touch, a rotation, switching apps or turning trackpad mode off
releases a button the trackpad was holding and every key the stick, Jump or a
number button was holding. A keyboard and mouse work at the same time as before.

**Keyboard.** Opens and closes the iOS keyboard; the game keeps its size. A row
above the keyboard has Escape, Tab, left and right arrows, Return and a button
to close it. Select a text field in the game first: Tolkara does not detect
the game's text fields, and it does not read the game's text or selection, so
the keyboard does not open by itself. While iOS reports a hardware keyboard (a
Bluetooth keyboard, or the Mac's keyboard while Device Hub mirrors the device),
it shows only the row above its keyboard; type on that keyboard instead.
Tolkara logs when a hardware keyboard connects or disconnects, whether iOS
accepted a keyboard request and how tall the keyboard came up. Typed text reaches the game as key
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
checks the two side-strip columns and that the game gets the space between them.
