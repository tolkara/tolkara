// Synthetic finger traces only; no imported application or UI automation.
#include "TouchStick.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef struct { unsigned direction; bool pressed; } Event;
typedef struct { Event events[64]; unsigned count, held; } Trace;
static void emit(void *context, unsigned direction, bool pressed) {
    Trace *trace = context;
    assert(trace->count < 64);
    // Never a second press of a held key or a release of one not held.
    assert(pressed ? !(trace->held & direction) : !!(trace->held & direction));
    trace->held = pressed ? trace->held | direction : trace->held & ~direction;
    trace->events[trace->count++] = (Event){direction, pressed};
}
int main(void) {
    // Eight directions, diagonals as two keys; y grows downwards.
    assert(AKStickDirections(0, -40) == AKStickUp && AKStickDirections(0, 40) == AKStickDown);
    assert(AKStickDirections(-40, 0) == AKStickLeft && AKStickDirections(40, 0) == AKStickRight);
    assert(AKStickDirections(30, -30) == (AKStickUp | AKStickRight));
    assert(AKStickDirections(-30, -30) == (AKStickUp | AKStickLeft));
    assert(AKStickDirections(-30, 30) == (AKStickDown | AKStickLeft));
    assert(AKStickDirections(30, 30) == (AKStickDown | AKStickRight));
    // Within 22.5 degrees of an axis is straight; the dead zone and invalid input press nothing.
    assert(AKStickDirections(10, -40) == AKStickUp && AKStickDirections(40, 12) == AKStickRight);
    assert(!AKStickDirections(5, 5) && !AKStickDirections(NAN, 40) && !AKStickDirections(INFINITY, 0));

    AKStick stick; Trace trace = {0};
    // The centre is where the finger lands; landing presses nothing.
    AKStickBegin(&stick, 100, 300);
    AKStickMove(&stick, 102, 299, emit, &trace);
    assert(stick.active && !trace.count);
    // Forward, then forward-right: only D is added; then right only: W is lifted first.
    AKStickMove(&stick, 100, 260, emit, &trace);
    assert(trace.count == 1 && trace.events[0].direction == AKStickUp && trace.events[0].pressed);
    AKStickMove(&stick, 130, 270, emit, &trace);
    assert(trace.count == 2 && trace.events[1].direction == AKStickRight && trace.events[1].pressed);
    AKStickMove(&stick, 140, 300, emit, &trace);
    assert(trace.count == 3 && trace.events[2].direction == AKStickUp && !trace.events[2].pressed);
    assert(trace.held == AKStickRight);
    // Lifting releases everything held.
    AKStickEnd(&stick, emit, &trace);
    assert(!trace.held && !stick.active && trace.count == 4);
    // Past the rim the centre follows, so a short reversal changes direction.
    trace.count = 0;
    AKStickBegin(&stick, 100, 300);
    AKStickMove(&stick, 100, 100, emit, &trace);
    assert(trace.held == AKStickUp && fabs(stick.originY - (100 + AKStickRadius)) < 1e-9 && stick.originX == 100);
    AKStickMove(&stick, 100, 100 + AKStickRadius + 30, emit, &trace);
    assert(trace.held == AKStickDown);
    // Back into the dead zone releases without a lift.
    AKStickMove(&stick, stick.originX + 3, stick.originY, emit, &trace);
    assert(!trace.held);
    AKStickEnd(&stick, emit, &trace);
    // An invalid sample ends the stick; nothing more is pressed until a new touch.
    trace.count = 0;
    AKStickBegin(&stick, 100, 300);
    AKStickMove(&stick, 60, 300, emit, &trace);
    AKStickMove(&stick, NAN, 300, emit, &trace);
    assert(!trace.held && !stick.active);
    AKStickMove(&stick, 60, 300, emit, &trace);
    assert(trace.count == 2 && !trace.held);
    AKStickBegin(&stick, NAN, 0);
    AKStickMove(&stick, 0, 0, emit, &trace);
    AKStickEnd(&stick, emit, &trace);
    assert(trace.count == 2);
    puts("touch stick: eight directions, dead zone, floating centre, release on lift and invalid traces: PASS");
}
