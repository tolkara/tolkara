#pragma once
#include "TouchTrackpad.h"

// Camera mode: touch the game directly, as for a game played with the mouse's
// right button. One finger that slides turns the camera: the pointer goes to
// where it landed and the right button goes down with its first movement (the
// motion is not lost) and is held until it lifts. One finger lifted without
// sliding right-clicks where it landed (attack, talk, loot). Two fingers slide
// to scroll (zoom a camera) or tap for a left click between them. Pressing at
// the first movement rather than at touch-down keeps a two-finger gesture
// whose second finger lands a moment late from right-clicking first.
//
// Coordinates are UIKit points (y down) in the game's view. Besides the
// trackpad's actions, AKTrackpadPoint moves the pointer to (x, y).
typedef struct {
    unsigned fingers, peak;
    double x, y, originX, originY, travelled, heldX, heldY, scrollX, scrollY;
    bool pressed, blocked, lifting;
} AKTouchCamera;

// Finger motion before the right button goes down (and a tap's tolerance).
#define AKTouchCameraSlop 4.0
void AKTouchCameraUpdate(AKTouchCamera *camera, unsigned fingers, double x, double y,
                         AKTrackpadEmit emit, void *context);
// Release a held button and ignore the rest of the gesture until every finger lifts.
void AKTouchCameraCancel(AKTouchCamera *camera, AKTrackpadEmit emit, void *context);
