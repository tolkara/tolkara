#include "TouchTrackpad.h"
#include <math.h>
#include <string.h>

enum { AKTrackpadSlop = 8 };
static const double AKTrackpadTapTime = 0.35, AKTrackpadHoldTime = 0.45;
// A second touch this soon after a one-finger tap, and this close to it,
// holds the right button from the moment it lands.
static const double AKTrackpadDoubleTapGap = 0.3, AKTrackpadDoubleTapReach = 70;

double AKTrackpadGain(double speed) {
    if (!isfinite(speed) || speed <= 0) return 0.8;
    if (speed < 150) return 0.8 + 0.2 * speed / 150;
    return 1 + 1.5 * fmin(1, (speed - 150) / 1050);
}

double AKTouchStartLimit(AKTouchStart *start, double distance, double time) {
    if (!(distance > 0) || !isfinite(time)) return 0;
    double limit = distance;
    if (!start->moving) {
        start->moving = true;
        start->firstMove = time;
        limit = AKTouchStartStep;
    } else if (time - start->firstMove < AKTouchStartTime) {
        limit = fmax(AKTouchStartStep, 2 * start->previous);
    }
    return start->previous = fmin(distance, limit);
}

void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context) {
    if (pad->dragging) emit(context, AKTrackpadUp, 0, 0, pad->button);
    pad->dragging = false;
    pad->blocked = true;
    pad->scrollX = pad->scrollY = 0;
}

void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context) {
    if (!isfinite(time) || pad->blocked || pad->lifting || pad->dragging ||
        pad->fingers < 1 || pad->fingers > 2 || pad->reach > AKTrackpadSlop ||
        time - pad->started < AKTrackpadHoldTime) return;
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
        else if (pad->fingers && !pad->blocked && pad->reach <= AKTrackpadSlop &&
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
        // A tap of several fingers is judged from where they all were down.
        if (fingers > pad->peak && pad->reach <= AKTrackpadSlop) { pad->originX = x; pad->originY = y; pad->reach = 0; }
    }
    pad->fingers = fingers;
    if (fingers > pad->peak) pad->peak = fingers;
    if (pad->doubleTap && !pad->dragging && !pad->blocked) {
        // Double tap and hold: the right button goes down as the second touch
        // lands, so a camera turns with the very first movement, and stays
        // down until it lifts (a quick second tap is a right click).
        pad->dragging = true;
        pad->button = 1;
        emit(context, AKTrackpadDown, 0, 0, pad->button);
    }
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
    pad->reach = fmax(pad->reach, hypot(x - pad->originX, y - pad->originY));
    if (!distance) return;
    if (fingers == 1 || pad->dragging) {
        double passed = AKTouchStartLimit(&pad->start, distance, time), scale = passed / distance;
        // A held right button turns a game's camera: linear, so it turns
        // evenly with the finger. The pointer's gain follows a smoothed speed.
        double sample = passed / fmax(interval, 1.0 / 240);
        pad->speed += (sample - pad->speed) * (1 - exp(-fmax(interval, 1.0 / 240) / 0.05));
        double gain = pad->dragging && pad->button == 1 ? AKTrackpadRightDragGain : AKTrackpadGain(pad->speed);
        emit(context, AKTrackpadMove, dx * scale * gain, dy * scale * gain, pad->button);
    } else if (fingers == 2 && pad->reach > AKTrackpadSlop) {
        // Keep sub-line motion: the Quartz adapter exposes integer wheel ticks.
        pad->scrollX += dx / 12;
        pad->scrollY += dy / 12;
        double linesX = trunc(pad->scrollX), linesY = trunc(pad->scrollY);
        pad->scrollX -= linesX; pad->scrollY -= linesY;
        if (linesX || linesY) emit(context, AKTrackpadScroll, linesX, linesY, 0);
    }
}
