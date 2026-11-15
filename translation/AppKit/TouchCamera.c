#include "TouchCamera.h"
#include <math.h>
#include <string.h>

void AKTouchCameraCancel(AKTouchCamera *camera, AKTrackpadEmit emit, void *context) {
    if (camera->pressed) emit(context, AKTrackpadUp, 0, 0, 1);
    if (camera->held) emit(context, AKTrackpadUp, 0, 0, 0);
    camera->pressed = camera->held = camera->armed = false;
    camera->blocked = true;
    camera->scrollX = camera->scrollY = 0;
}

bool AKTouchCameraHold(AKTouchCamera *camera, double time) {
    if (!isfinite(time) || camera->blocked || camera->lifting || camera->pressed || camera->armed ||
        camera->fingers != 1 || camera->peak != 1 || camera->reach > AKTouchCameraSlop ||
        time - camera->started < AKTouchHoldTime) return false;
    return camera->armed = true;
}

void AKTouchCameraUpdate(AKTouchCamera *camera, unsigned fingers, double x, double y, double time,
                         AKTrackpadEmit emit, void *context) {
    if (!fingers) {
        if (camera->pressed) emit(context, AKTrackpadUp, 0, 0, 1);
        else if (camera->held) emit(context, AKTrackpadUp, 0, 0, 0);
        else if (camera->fingers && !camera->blocked && !camera->armed) {
            // A tap: one finger right-clicks where it landed (the pointer is
            // there already), two left-click between them; three do nothing.
            if (camera->peak == 1) {
                emit(context, AKTrackpadDown, 0, 0, 1);
                emit(context, AKTrackpadUp, 0, 0, 1);
            } else if (camera->peak == 2 && camera->reach <= AKTouchCameraTapSlop) {
                emit(context, AKTrackpadPoint, camera->originX, camera->originY, 0);
                emit(context, AKTrackpadDown, 0, 0, 0);
                emit(context, AKTrackpadUp, 0, 0, 0);
            }
        }
        bool anchored = camera->anchored;
        double anchorX = camera->anchorX, anchorY = camera->anchorY;
        memset(camera, 0, sizeof *camera);
        camera->anchored = anchored; camera->anchorX = anchorX; camera->anchorY = anchorY;
        return;
    }
    if (fingers > 3 || !isfinite(x) || !isfinite(y) || !isfinite(time)) {
        AKTouchCameraCancel(camera, emit, context);
        camera->fingers = fingers;
        return;
    }
    if (!camera->fingers) {
        camera->x = camera->originX = x;
        camera->y = camera->originY = y;
        camera->started = time;
        // The game learns what is under the finger while it rests there.
        if (fingers == 1) emit(context, AKTrackpadPoint, x, y, 0);
    }
    if (camera->fingers && camera->fingers != fingers) {
        // A finger joined or left: the centroid jumps, so no motion from it.
        // A held right button is released (its drag ends there); fewer
        // fingers than before means the gesture is ending.
        if (camera->fingers > fingers) camera->lifting = true;
        if (camera->pressed || camera->held) AKTouchCameraCancel(camera, emit, context);
        camera->armed = false;
        camera->x = x; camera->y = y;
        camera->scrollX = camera->scrollY = 0;
        // A two-finger gesture is judged from between the fingers.
        if (fingers > camera->peak) { camera->originX = x; camera->originY = y; camera->reach = 0; }
    }
    camera->fingers = fingers;
    if (fingers > camera->peak) camera->peak = fingers;
    double dx = x - camera->x, dy = y - camera->y;
    camera->x = x; camera->y = y;
    if (camera->blocked || camera->lifting) return;
    double distance = hypot(dx, dy);
    if (!isfinite(distance) || distance > 10000) { AKTouchCameraCancel(camera, emit, context); return; }
    if (!distance) return;
    camera->reach = fmax(camera->reach, hypot(x - camera->originX, y - camera->originY));
    if (fingers == 1 && (camera->armed || camera->held)) {
        // Held, then slid: the left button goes down where the finger rested
        // and the pointer stays under the finger, whole steps and no gain.
        if (!camera->held) {
            emit(context, AKTrackpadPoint, camera->originX, camera->originY, 0);
            emit(context, AKTrackpadDown, 0, 0, 0);
            camera->held = true;
        }
        emit(context, AKTrackpadPoint, x, y, 0);
    } else if (fingers == 1) {
        if (!camera->pressed) {
            if (camera->reach <= AKTouchCameraSlop) return;
            if (camera->anchored) emit(context, AKTrackpadPoint, camera->anchorX, camera->anchorY, 0);
            emit(context, AKTrackpadDown, 0, 0, 1);
            camera->pressed = true;
        }
        double scale = AKTouchStartLimit(&camera->start, distance, time) / distance * AKTrackpadRightDragGain;
        emit(context, AKTrackpadMove, dx * scale, dy * scale, 1);
    } else if (fingers == 2 && camera->reach > AKTouchCameraTapSlop) {
        // As the trackpad's two-finger scroll: sub-line motion is kept.
        camera->scrollX += dx / 12;
        camera->scrollY += dy / 12;
        double linesX = trunc(camera->scrollX), linesY = trunc(camera->scrollY);
        camera->scrollX -= linesX; camera->scrollY -= linesY;
        if (linesX || linesY) emit(context, AKTrackpadScroll, linesX, linesY, 0);
    }
}
