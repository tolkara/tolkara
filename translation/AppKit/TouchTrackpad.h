#pragma once
#include <stdbool.h>

// Direct finger input only. Coordinates/deltas are UIKit points (y down).
// The state machine does not inspect a guest or generate input on its own.
typedef enum { AKTrackpadMove, AKTrackpadScroll, AKTrackpadDown, AKTrackpadUp } AKTrackpadAction;
typedef void (*AKTrackpadEmit)(void *context, AKTrackpadAction action, double x, double y, unsigned button);
typedef struct {
    unsigned fingers, peak;
    double x, y, originX, originY, started, last, travelled, scrollX, scrollY;
    bool blocked, lifting, dragging;
    unsigned button;
    // The one-finger tap just before this gesture, and whether this touch
    // followed it closely enough to be a double tap and hold.
    bool tapped, doubleTap;
    double tapEnded, tapX, tapY;
} AKTrackpad;

// Pointer gain for a finger speed in points per second: below 1 when slow,
// for aiming, rising to 2.5 for a quick flick across the screen.
double AKTrackpadGain(double speed);
// Constant gain, without acceleration, while the right button is held (double
// tap and slide, or two fingers held then slid): a game's camera turns by it.
#define AKTrackpadRightDragGain 3.0
void AKTrackpadUpdate(AKTrackpad *pad, unsigned fingers, double x, double y, double time,
                     AKTrackpadEmit emit, void *context);
// About half a second after a still touch: one finger right-clicks, or after
// a double tap holds the right button; two fingers start a right-button drag.
void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context);
// Suppress the remainder of a cancelled gesture until every finger is lifted.
void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context);
