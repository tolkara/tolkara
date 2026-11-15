#pragma once
#include "TouchTrackpad.h"

// Camera mode: touch the game directly, as for a game played with the mouse's
// right button. The pointer goes to a finger as it lands, so the game sees
// what is under it before any click. One finger that slides turns the camera:
// the right button goes down with the first movement iOS reports and is held
// until the finger lifts. It goes down at the anchor (the middle of the game's
// view) when one is set, not under the finger: a slide that happens to start
// on something of the game's interface (a quest list at the screen's edge)
// then turns the camera all the same and clicks nothing. One finger lifted
// without sliding right-clicks where it landed (attack, talk, loot). With
// `left` set (the on-screen Shift is held) one finger uses the left button
// where it is: a slide drags with it, the pointer under the finger (to move a
// spell or an item), and a tap left-clicks. Two fingers slide to scroll (zoom a
// camera) or tap for a left click between them. Pressing at the first movement
// rather than at touch-down keeps a two-finger gesture whose second finger
// lands a moment late from right-clicking first.
//
// iOS itself reports no movement for a finger that only taps, so there is
// almost no threshold here: AKTouchCameraSlop only covers a device that
// reports less than that. Motion is never held back and sent later in one
// piece; the start of a slide is eased in instead (AKTouchStart).
//
// Coordinates are UIKit points (y down) in the game's view. Besides the
// trackpad's actions, AKTrackpadPoint moves the pointer to (x, y).
typedef struct {
    unsigned fingers, peak;
    double x, y, originX, originY, reach, scrollX, scrollY;
    // pressed: the right button is held (a camera drag). held: the left
    // button is, in a drag that began with `left` set.
    bool pressed, blocked, lifting, held;
    AKTouchStart start;
    // Where a camera drag presses the right button; the caller sets it before
    // each update. Without one it presses where the pointer is (the finger).
    bool anchored;
    double anchorX, anchorY;
    // Set by the caller before each update: one finger uses the left button.
    bool left;
} AKTouchCamera;

// One finger nearer than this to where it landed has not slid yet.
#define AKTouchCameraSlop 3.0
// Two fingers nearer than this to where they landed tap; farther, they scroll.
#define AKTouchCameraTapSlop 8.0
void AKTouchCameraUpdate(AKTouchCamera *camera, unsigned fingers, double x, double y, double time,
                         AKTrackpadEmit emit, void *context);
// Release a held button and ignore the rest of the gesture until every finger lifts.
void AKTouchCameraCancel(AKTouchCamera *camera, AKTrackpadEmit emit, void *context);
