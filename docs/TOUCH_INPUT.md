# On-screen controls

Optional keyboard and touch-trackpad buttons over a game, for a device without
a keyboard or mouse. They are shown by default on iPhone and hidden on iPad;
**On-Screen Controls**, under the hand button in the library's toolbar, turns
them on or off from the next game start. Without them, touches act as before:
a touch is a left click where the finger is.

Two translucent buttons sit at the bottom right of the game. Only the buttons
take touches; the rest of the screen belongs to the game.

**Keyboard.** Opens and closes the iOS keyboard; the game keeps its size. A row
above the keyboard has Escape, Tab, left and right arrows, Return and a button
to close it. Select a text field in the game first: Tolkara does not detect
the game's text fields, and it does not read the game's text or selection. Typed
text reaches the game as key presses, with macOS key codes for the characters
of a US keyboard. The keyboard is set up as a password field, so iOS offers no
predictions or corrections; it also offers no dictation or third-party
keyboards, and may limit other input methods.

**Trackpad.** The hand button turns trackpad mode on (cyan) or off; the choice
is kept. Long-press it for a menu with left, right and middle click.

| In trackpad mode | Mouse input |
| --- | --- |
| Slide one finger | Moves the cursor by the finger's motion; lifting and placing the finger elsewhere does not move it. |
| Tap / tap twice | Left click / double click |
| Tap with two fingers | Right click |
| Tap with three fingers | Middle click |
| Slide two fingers | Scroll, vertically or horizontally |
| Hold one finger about half a second, then slide | Drag with the left button held |
| Hold two fingers about half a second, then slide | Drag with the right button held, e.g. to turn the camera |

A cancelled touch, a rotation, switching apps or turning trackpad mode off
releases a button the trackpad was holding. A keyboard and mouse work at the
same time as before.

## Tests

`tools/test_emulation.sh` runs the trackpad's finger traces and the text-to-key
mapping; `tools/test_translation_sim.sh` checks event delivery in the
simulator. `tools/test_touch_controls_ui.sh` opens our own test screen (never a
game) in the simulator; `--self-test` checks the keyboard's placement, typing
and returning focus, and `--show-keyboard` opens the keyboard to look at.
