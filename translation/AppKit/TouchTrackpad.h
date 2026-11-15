#pragma once
#include <stdbool.h>

// Direct finger input only. Coordinates/deltas are UIKit points (y down).
// The state machine does not inspect a guest or generate input on its own.
// AKTrackpadPoint (camera mode only) moves the pointer to (x, y) in the game's view.
typedef enum { AKTrackpadMove, AKTrackpadScroll, AKTrackpadDown, AKTrackpadUp, AKTrackpadPoint } AKTrackpadAction;
typedef void (*AKTrackpadEmit)(void *context, AKTrackpadAction action, double x, double y, unsigned button);
// Soft start. iOS reports nothing while a finger that just landed moves a
// short way, then its position jumps to where the finger is (the system's own
// distinction between a tap and a drag). That first jump is not passed on: a
// gesture's first step is limited to AKTouchStartStep points and each step
// after it to twice the one before, for AKTouchStartTime seconds. Motion then
// starts without a jerk, however late iOS reported it; later steps are whole.
typedef struct { bool moving; double firstMove, previous; } AKTouchStart;
#define AKTouchStartStep 2.0
#define AKTouchStartTime 0.08
// How much of a step of `distance` points at `time` may be passed on.
double AKTouchStartLimit(AKTouchStart *start, double distance, double time);

typedef struct {
    unsigned fingers, peak;
    // reach: the farthest the finger(s) got from where the gesture (or its
    // current finger count) began: what tells a tap or a hold from a slide.
    double x, y, originX, originY, started, last, reach, speed, scrollX, scrollY;
    AKTouchStart start;
    bool blocked, lifting, dragging;
    unsigned button;
    // Set by the caller before each update (the on-screen Shift is held): a
    // double tap and hold then holds the left button, to drag a spell or an
    // item, in place of the right.
    bool leftDrag;
    // Set by the caller (pointer acceleration is switched off): the pointer
    // moves by AKTrackpadLinearGain whatever the finger's speed.
    bool linear;
    // The one-finger tap just before this gesture, and whether this touch
    // followed it closely enough to be a double tap and hold.
    bool tapped, doubleTap;
    double tapEnded, tapX, tapY;
} AKTrackpad;

// Pointer gain for a finger speed in points per second: below 1 when slow,
// for aiming, rising to 2.5 for a quick flick across the screen. The speed is
// smoothed over about a twentieth of a second: touch samples arrive unevenly
// (several at once after a slow frame), and a gain taken from one sample's
// speed made the pointer lurch.
double AKTrackpadGain(double speed);
// Constant gain, without acceleration, while the right button is held (double
// tap and slide, or two fingers held then slid): a game's camera turns by it.
#define AKTrackpadRightDragGain 3.0
// Constant pointer gain with pointer acceleration switched off (AKTrackpad.linear).
#define AKTrackpadLinearGain 1.5
void AKTrackpadUpdate(AKTrackpad *pad, unsigned fingers, double x, double y, double time,
                     AKTrackpadEmit emit, void *context);
// About half a second after a still touch: one finger right-clicks; two
// fingers start a right-button drag. (After a one-finger tap, a second touch
// holds a button at once, in AKTrackpadUpdate: the right one, or the left
// with leftDrag.)
void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context);
// Suppress the remainder of a cancelled gesture until every finger is lifted.
void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context);
