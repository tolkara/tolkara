#include "TouchTrackpad.h"
#include <math.h>
#include <string.h>

enum { AKTrackpadSlop = 8 };
static const double AKTrackpadTapTime = 0.35, AKTrackpadHoldTime = 0.45;
// A second touch this soon after a one-finger tap, and this close to it,
// holds the right button once it moves or is held.
static const double AKTrackpadDoubleTapGap = 0.3, AKTrackpadDoubleTapReach = 70;

double AKTrackpadGain(double speed) {
    if (!isfinite(speed) || speed <= 0) return 0.8;
    if (speed < 150) return 0.8 + 0.2 * speed / 150;
    return 1 + 1.5 * fmin(1, (speed - 150) / 1050);
}

void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context) {
    if (pad->dragging) emit(context, AKTrackpadUp, 0, 0, pad->button);
    pad->dragging = false;
    pad->blocked = true;
    pad->scrollX = pad->scrollY = 0;
}

void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context) {
    if (!isfinite(time) || pad->blocked || pad->lifting || pad->dragging ||
        pad->fingers < 1 || pad->fingers > 2 || pad->travelled > AKTrackpadSlop ||
        time - pad->started < AKTrackpadHoldTime) return;
    if (pad->fingers == 1 && pad->doubleTap) {
        pad->dragging = true;
        pad->button = 1;
        emit(context, AKTrackpadDown, 0, 0, pad->button);
        return;
    }
    if (pad->fingers == 1) {
        // The rest of the touch is consumed: lifting it is not also a left click.
        emit(context, AKTrackpadDown, 0, 0, 1);
        emit(context, AKTrackpadUp, 0, 0, 1);
        pad->blocked = true;
        return;
    }
    pad->dragging = true;
    pad->button = 1;
    emit(context, AKTrackpadDown, 0, 0, pad->button);
}

void AKTrackpadUpdate(AKTrackpad *pad, unsigned fingers, double x, double y, double time,
                     AKTrackpadEmit emit, void *context) {
    if (!fingers) {
        bool tapped = false;
        if (pad->dragging) emit(context, AKTrackpadUp, 0, 0, pad->button);
        else if (pad->fingers && !pad->blocked && pad->travelled <= AKTrackpadSlop &&
                 isfinite(time) && time >= pad->started && time - pad->started <= AKTrackpadTapTime) {
            unsigned button = pad->peak == 3 ? 2 : pad->peak == 2 ? 1 : 0;
            emit(context, AKTrackpadDown, 0, 0, button);
            emit(context, AKTrackpadUp, 0, 0, button);
            tapped = pad->peak == 1 && !pad->doubleTap;
        }
        double tapX = pad->originX, tapY = pad->originY;
        memset(pad, 0, sizeof *pad);
        if (tapped) {
            pad->tapped = true;
            pad->tapEnded = time;
            pad->tapX = tapX; pad->tapY = tapY;
        }
        return;
    }
    if (fingers > 3 || !isfinite(x) || !isfinite(y) || !isfinite(time) ||
        (pad->fingers && time < pad->started)) {
        AKTrackpadCancel(pad, emit, context);
        pad->fingers = fingers;
        return;
    }
    if (!pad->fingers) {
        pad->started = pad->last = time;
        pad->x = pad->originX = x;
        pad->y = pad->originY = y;
        pad->doubleTap = pad->tapped && fingers == 1 && time >= pad->tapEnded &&
                    time - pad->tapEnded <= AKTrackpadDoubleTapGap &&
                    hypot(x - pad->tapX, y - pad->tapY) <= AKTrackpadDoubleTapReach;
        pad->tapped = false;
    }
    if (pad->fingers != fingers) {
        // A changed centroid must not jump the pointer or produce a scroll.
        // Once lifting starts, consume the remaining fingers without moving.
        if (pad->fingers > fingers) pad->lifting = true;
        if (pad->fingers) pad->doubleTap = false;
        if (pad->dragging) AKTrackpadCancel(pad, emit, context);
        pad->x = x; pad->y = y; pad->last = time;
        pad->scrollX = pad->scrollY = 0;
    }
    pad->fingers = fingers;
    if (fingers > pad->peak) pad->peak = fingers;
    // Speed is measured between samples that moved: other touches' events
    // (the stick's) repeat a still trackpad's position.
    double dx = x - pad->x, dy = y - pad->y, interval = time - pad->last;
    pad->x = x; pad->y = y;
    if (dx || dy) pad->last = time;
    if (pad->blocked || pad->lifting) return;
    double distance = hypot(dx, dy);
    if (!isfinite(distance) || distance > 10000) {
        AKTrackpadCancel(pad, emit, context);
        return;
    }
    pad->travelled += distance;
    if (!distance) return;
    if (pad->doubleTap && !pad->dragging) {
        // Double tap and hold: the right button goes down once the second
        // touch moves (or, in AKTrackpadHold, is held) and stays down until
        // it lifts. Lifting a still second tap is a double click instead.
        if (pad->travelled <= AKTrackpadSlop) return;
        pad->dragging = true;
        pad->button = 1;
        emit(context, AKTrackpadDown, 0, 0, pad->button);
    }
    if (fingers == 1 || pad->dragging) {
        double gain = AKTrackpadGain(distance / fmax(interval, 1.0 / 240));
        // A held right button turns a game's camera, which needs more motion.
        if (pad->dragging && pad->button == 1) gain *= AKTrackpadRightDragScale;
        emit(context, AKTrackpadMove, dx * gain, dy * gain, pad->button);
    } else if (fingers == 2 && pad->travelled > AKTrackpadSlop) {
        // Keep sub-line motion: the Quartz adapter exposes integer wheel ticks.
        pad->scrollX += dx / 12;
        pad->scrollY += dy / 12;
        double linesX = trunc(pad->scrollX), linesY = trunc(pad->scrollY);
        pad->scrollX -= linesX; pad->scrollY -= linesY;
        if (linesX || linesY) emit(context, AKTrackpadScroll, linesX, linesY, 0);
    }
}
