# On-screen controls

Optional on-screen controls over a game, for a device without a keyboard or
mouse, modelled on the Windows App's (Microsoft Remote Desktop) mouse pointer
mode. They are shown by default on iPhone and hidden on iPad;
**On-Screen Controls**, under the hand button in the library's toolbar, turns
them on or off from the next game start. Without them, touches act as before:
a touch is a left click where the finger is; the pointer moves there before
the button goes down, so a game that highlights what is under the pointer (a
login button) takes the tap.

The buttons stand in columns at the left and right edges of the screen, and
the game draws between them. On the right, from the top: Escape, Tab (e.g. to
select a target), **1** to **5** and Jump; on the left: the keyboard, stick,
trackpad and Shift buttons and **6** to **0**. Jump holds Space, and each key
button its key (a US keyboard's), for as long as it is touched. Only the
buttons take touches. The columns keep a black background; the game sees a
display as large as the space between them (`NSScreen`, `CGDisplayBounds`), as
a Mac whose screen ends where the columns begin.

Which layout a screen gets is decided from its size and safe area alone
(`AKTouchLayoutFor` in `translation/AppKit/TouchControls.m`), not from the
kind of device:

| Screen | Layout | The game loses, at each edge |
| --- | --- | --- |
| Nine buttons fit the height at full size: an iPad, upright or on its side | One column a side | 56 points |
| Shorter: an iPhone on its side | Two columns a side | 56 points beyond the side inset (the Dynamic Island's), or 112 where the inset is narrower than a column |
| iPhone Duo, unfolded | One column in the status-bar strip and one mirroring it | The column's width, 56 points |
| The columns would leave the game under 400 points of width: an iPhone upright, a narrow iPad window | A row of four buttons over the game | Nothing |

Buttons are 44 points across on a 52-point pitch, and a column is 56 points
wide. Where the height is short they shrink together, down to 34 points on a
40-point pitch; buttons that still do not fit are hidden from the bottom up.
The columns end 8 points above the bottom inset (the home indicator's).
Except on the Duo, both sides share one grid of rows, standing in the middle
of the height: the rows are level on both sides, and the right side, one
button shorter, stands at the bottom, so Jump is beside key **0**.

**iPad.** One column a side: nine buttons on the left, eight on the right. A
13-inch iPad on its side (1376 by 1032 points) gives the game 1264 by 1032.
The controls stay off on iPad until **On-Screen Controls** turns them on.

**iPhone.** On its side an iPhone is too short for nine full-size buttons in
one column (402 points on an iPhone 17 Pro), so each side has two. The inner
column, next to the game, has the buttons a thumb uses in play: the trackpad
and Shift buttons and **6** to **0** on the left, **1** to **5** and Jump on
the right. It stands just past the side inset, where the Dynamic Island or a
rounded corner would hide part of the game. The outer column stands in that inset and has only each side's
first two buttons, in the top two rows, above the island: the keyboard and
stick buttons on the left, Escape and Tab on the right. On a screen with side
insets the rows start 20 points from the top, clear of the rounded corners.
An iPhone 17 Pro (874 by 402 points, 62-point side insets) gives the game 638
by 402, and all buttons are full size. The launcher runs on iPhone only on
its side (`UISupportedInterfaceOrientations_iPhone` in `project.yml` lists
the two landscape orientations), so the upright row is not reached there.

**iPhone Duo.** Unfolded, the inner display keeps a strip at one side for the
status bar (UIKit reports it as an occlusion reserved region, iOS 27.1). The
buttons stand in a column in that strip and in one mirroring it at the other
edge. Each column is only as wide as the buttons need (56 points, against the
screen's edge; the strip itself is 84), so the game keeps the rest. Both
start below the status bar as Apple's own bars do, each with its own pitch.
Once found, the strip stays for that screen size: on the device UIKit stops
reporting it when the game hides the status bar.

**The row.** Jump, the movement stick, the trackpad and the keyboard, at the
bottom right over the game, which keeps the whole screen. It has no number,
Escape, Tab or Shift buttons, and it moves up with the iOS keyboard.

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
| Slide one finger with Shift held | Drags with the left button, the pointer under the finger, until it lifts: moves a spell or an item |
| Tap one finger with Shift held | Left click where it touched |
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
shows what is being carried on it. The camera turns three
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
pointer lurch. With **Pointer Acceleration** off (below) the pointer instead
moves one and a half times the finger's motion at any speed. While the right button is held (double tap and slide, or two
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
| Double tap and slide with Shift held | Holds the left button instead, from where the pointer is: drags a spell or an item |
| Hold one finger still about half a second | Right click |
| Tap with two fingers | Right click |
| Tap with three fingers | Middle click |
| Slide two fingers | Scroll, vertically or horizontally |
| Hold two fingers about half a second, then slide | Drag with the right button held |

A double tap's second touch must start within 0.3 s of the first tap and near
it. The right button goes down as that touch lands, so the camera turns with
the first movement; lifting it again quickly is therefore a right click, not a
double click. In
the Windows App, a one-finger double tap and hold drags with the left button;
here it holds the right button, which a game's camera needs more often. The
Shift button (in the column layouts) holds Shift while touched, for the mouse
as for keys, and while it is held the same double tap and hold uses the left
button: Shift and drag, which moves a spell on a locked bar. Which button is
decided as the second touch lands; letting Shift go during the drag keeps it.

A cancelled touch, a rotation, switching apps or turning trackpad mode off
releases a button the trackpad was holding and every key the stick, Jump or a
number button was holding. A keyboard and mouse work at the same time as before.

**Keyboard.** Opens and closes the iOS keyboard. The game keeps its size and
place, and in the column layouts so does every button: those the keyboard
would cover are hidden while it is open (the keyboard button, in the top row,
never is) and come back when it closes. A row
above the keyboard has Escape, Tab, left and right arrows, Paste, Return and a
button to close it. Paste is iOS's own paste button: it types the clipboard's
text as if from this keyboard, for a long password from a password manager.
Because it is the system's control, which only the user can press, iOS asks no
permission and Tolkara reads the clipboard only at that tap. Line breaks, tabs
and other control characters are left out, so Paste never presses Return or
Tab, and it types at most 1,024 characters; nothing pasted is kept or logged. Select a text field in the game first: Tolkara does not detect
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
It also checks the layout of the simulator it runs in (`SIMULATOR`: an iPhone
gets two columns a side, an iPad one, an iPhone Duo simulator of the iOS 27.2
runtime the strip's column and its mirror): every button on the screen, clear
of the others and of the insets, the game between the columns and told that
size, and neither the game nor a button moved by opening and closing the
keyboard. `tools/test_translation_sim.sh` checks the layout decision itself
for iPad, iPhone, Duo and small sizes. An iPad simulator counts the Mac's
keyboard as a hardware keyboard, so there only the row above the keyboard
opens.

## Pointer acceleration

iPadOS accelerates its pointer and has no setting to stop that. A game that
captures the mouse (for its camera, or to aim) never sees it: Tolkara locks
the iPadOS pointer and passes the mouse's own motion on. The free pointer, in
menus or a strategy game, is the iPadOS pointer and is accelerated.

**Pointer Acceleration**, under the hand button in the library's toolbar,
turns that off from the next game start (it is on by default):

- With a mouse attached, the iPadOS pointer stays locked for the whole game
  and the game's pointer moves by the mouse's own motion at a constant speed.
  **Mouse Pointer Speed** in the same menu scales it, from 0.5× to 2×; motion a
  game has captured is passed on unscaled, as before. Tolkara draws the game's
  pointer itself, since iPadOS shows none while its pointer is locked.
- The touch trackpad's pointer moves by a constant one and a half times the
  finger's motion.

Limits: iPadOS only locks its pointer for a game that fills the screen and is
in front. In a Stage Manager or Split View window the lock is refused and the
iPadOS pointer, with its acceleration, moves the game's pointer as before.
While locked, the pointer cannot leave the game for the Dock or another
window; use touch or the keyboard. Only devices iPadOS reports as a mouse
(`GCMouse`) are read this way.
