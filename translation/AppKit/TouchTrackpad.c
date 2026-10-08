#include "TouchTrackpad.h"
#include <math.h>
#include <string.h>

void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context) {
    if (pad->dragging) emit(context, AKTrackpadUp, 0, 0, pad->button);
    pad->dragging = false;
    pad->blocked = true;
    pad->scrollX = pad->scrollY = 0;
}

void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context) {
    if (!isfinite(time) || pad->blocked || pad->lifting || pad->dragging ||
        pad->fingers < 1 || pad->fingers > 2 || pad->travelled > 8 || time - pad->started < 0.45) return;
    pad->dragging = true;
    pad->button = pad->fingers == 2 ? 1 : 0;
    emit(context, AKTrackpadDown, 0, 0, pad->button);
}

void AKTrackpadUpdate(AKTrackpad *pad, unsigned fingers, double x, double y, double time,
                     AKTrackpadEmit emit, void *context) {
    if (!fingers) {
        if (pad->dragging) emit(context, AKTrackpadUp, 0, 0, pad->button);
        else if (pad->fingers && !pad->blocked && pad->travelled <= 8 &&
                 isfinite(time) && time >= pad->started && time - pad->started <= 0.35) {
            unsigned button = pad->peak == 3 ? 2 : pad->peak == 2 ? 1 : 0;
            emit(context, AKTrackpadDown, 0, 0, button);
            emit(context, AKTrackpadUp, 0, 0, button);
        }
        memset(pad, 0, sizeof *pad);
        return;
    }
    if (fingers > 3 || !isfinite(x) || !isfinite(y) || !isfinite(time) ||
        (pad->fingers && time < pad->started)) {
        AKTrackpadCancel(pad, emit, context);
        pad->fingers = fingers;
        return;
    }
    if (!pad->fingers) {
        pad->started = time;
        pad->x = x; pad->y = y;
    }
    if (pad->fingers != fingers) {
        // A changed centroid must not jump the pointer or produce a scroll.
        // Once lifting starts, consume the remaining fingers without moving.
        if (pad->fingers > fingers) pad->lifting = true;
        if (pad->dragging) AKTrackpadCancel(pad, emit, context);
        pad->x = x; pad->y = y;
        pad->scrollX = pad->scrollY = 0;
    }
    pad->fingers = fingers;
    if (fingers > pad->peak) pad->peak = fingers;
    double dx = x - pad->x, dy = y - pad->y;
    pad->x = x; pad->y = y;
    if (pad->blocked || pad->lifting) return;
    double distance = hypot(dx, dy);
    if (!isfinite(distance) || distance > 10000) {
        AKTrackpadCancel(pad, emit, context);
        return;
    }
    pad->travelled += distance;
    if (!distance) return;
    if (fingers == 1 || pad->dragging) emit(context, AKTrackpadMove, dx, dy, pad->button);
    else if (fingers == 2 && pad->travelled > 8) {
        // Keep sub-line motion: the Quartz adapter exposes integer wheel ticks.
        pad->scrollX += dx / 12;
        pad->scrollY += dy / 12;
        double linesX = trunc(pad->scrollX), linesY = trunc(pad->scrollY);
        pad->scrollX -= linesX; pad->scrollY -= linesY;
        if (linesX || linesY) emit(context, AKTrackpadScroll, linesX, linesY, 0);
    }
}
