#include "TouchCamera.h"
#include <math.h>
#include <string.h>

void AKTouchCameraCancel(AKTouchCamera *camera, AKTrackpadEmit emit, void *context) {
    if (camera->pressed) emit(context, AKTrackpadUp, 0, 0, 1);
    camera->pressed = false;
    camera->blocked = true;
    camera->heldX = camera->heldY = camera->scrollX = camera->scrollY = 0;
}

static void press(AKTouchCamera *camera, AKTrackpadEmit emit, void *context) {
    emit(context, AKTrackpadPoint, camera->originX, camera->originY, 0);
    emit(context, AKTrackpadDown, 0, 0, 1);
    camera->pressed = true;
}

void AKTouchCameraUpdate(AKTouchCamera *camera, unsigned fingers, double x, double y,
                         AKTrackpadEmit emit, void *context) {
    if (!fingers) {
        if (camera->pressed) emit(context, AKTrackpadUp, 0, 0, 1);
        else if (camera->fingers && !camera->blocked && camera->travelled <= AKTouchCameraSlop) {
            // A tap: one finger right-clicks where it landed, two left-click
            // between them; three do nothing.
            if (camera->peak == 1) {
                press(camera, emit, context);
                emit(context, AKTrackpadUp, 0, 0, 1);
            } else if (camera->peak == 2) {
                emit(context, AKTrackpadPoint, camera->originX, camera->originY, 0);
                emit(context, AKTrackpadDown, 0, 0, 0);
                emit(context, AKTrackpadUp, 0, 0, 0);
            }
        }
        memset(camera, 0, sizeof *camera);
        return;
    }
    if (fingers > 3 || !isfinite(x) || !isfinite(y)) {
        AKTouchCameraCancel(camera, emit, context);
        camera->fingers = fingers;
        return;
    }
    if (!camera->fingers) {
        camera->x = camera->originX = x;
        camera->y = camera->originY = y;
    }
    if (camera->fingers && camera->fingers != fingers) {
        // A finger joined or left: the centroid jumps, so no motion from it.
        // A held right button is released (its drag ends there); fewer
        // fingers than before means the gesture is ending.
        if (camera->fingers > fingers) camera->lifting = true;
        if (camera->pressed) AKTouchCameraCancel(camera, emit, context);
        camera->x = x; camera->y = y;
        camera->scrollX = camera->scrollY = 0;
        // A two-finger gesture's tap position is between the fingers.
        if (fingers == 2 && camera->travelled <= AKTouchCameraSlop) { camera->originX = x; camera->originY = y; }
    }
    camera->fingers = fingers;
    if (fingers > camera->peak) camera->peak = fingers;
    double dx = x - camera->x, dy = y - camera->y;
    camera->x = x; camera->y = y;
    if (camera->blocked || camera->lifting) return;
    double distance = hypot(dx, dy);
    if (!isfinite(distance) || distance > 10000) { AKTouchCameraCancel(camera, emit, context); return; }
    if (!distance) return;
    camera->travelled += distance;
    if (fingers == 1) {
        if (!camera->pressed) {
            // Motion inside the slop is kept and sent once the button is down.
            camera->heldX += dx; camera->heldY += dy;
            if (camera->travelled <= AKTouchCameraSlop) return;
            press(camera, emit, context);
            dx = camera->heldX; dy = camera->heldY;
            camera->heldX = camera->heldY = 0;
        }
        emit(context, AKTrackpadMove, dx * AKTrackpadRightDragGain, dy * AKTrackpadRightDragGain, 1);
    } else if (fingers == 2 && camera->travelled > AKTouchCameraSlop) {
        // As the trackpad's two-finger scroll: sub-line motion is kept.
        camera->scrollX += dx / 12;
        camera->scrollY += dy / 12;
        double linesX = trunc(camera->scrollX), linesY = trunc(camera->scrollY);
        camera->scrollX -= linesX; camera->scrollY -= linesY;
        if (linesX || linesY) emit(context, AKTrackpadScroll, linesX, linesY, 0);
    }
}
