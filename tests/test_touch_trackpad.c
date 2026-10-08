// Synthetic finger traces only; no imported application or UI automation.
#include "TouchTrackpad.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef struct { AKTrackpadAction action; double x, y; unsigned button; } Event;
typedef struct { Event events[256]; unsigned count; } Trace;
static void emit(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    Trace *trace = context;
    assert(trace->count < 256);
    trace->events[trace->count++] = (Event){action, x, y, button};
}
static void update(AKTrackpad *pad, Trace *trace, unsigned fingers, double x, double y, double time) {
    AKTrackpadUpdate(pad, fingers, x, y, time, emit, trace);
}
int main(void) {
    AKTrackpad pad = {0}; Trace trace = {0};
    // Moving a finger moves the pointer without a button held or an end click.
    update(&pad, &trace, 1, 100, 100, 1);
    assert(!trace.count);
    update(&pad, &trace, 1, 120, 80, 1.1);
    update(&pad, &trace, 0, 0, 0, 1.2);
    assert(trace.count == 1 && trace.events[0].action == AKTrackpadMove);
    assert(trace.events[0].x == 20 && trace.events[0].y == -20);
    // Lifting and placing somewhere else does not teleport the cursor.
    trace.count = 0;
    update(&pad, &trace, 1, 500, 400, 2);
    update(&pad, &trace, 0, 0, 0, 2.1);
    assert(trace.count == 2 && trace.events[0].action == AKTrackpadDown && trace.events[0].button == 0);
    assert(trace.events[1].action == AKTrackpadUp);
    // One-, two- and three-finger taps are left, right and middle clicks.
    for (unsigned fingers = 2; fingers <= 3; fingers++) {
        trace.count = 0;
        update(&pad, &trace, 1, 20, 20, 3);
        update(&pad, &trace, fingers, 150, 150, 3.03);
        update(&pad, &trace, 1, 20, 20, 3.1);
        update(&pad, &trace, 1, 22, 22, 3.12);
        update(&pad, &trace, 0, 0, 0, 3.2);
        assert(trace.count == 2 && trace.events[0].action == AKTrackpadDown && trace.events[0].button == fingers - 1);
        assert(trace.events[1].action == AKTrackpadUp && trace.events[1].button == fingers - 1);
    }
    // Scroll accumulates small movements into wheel lines, not clicks/motion.
    trace.count = 0;
    update(&pad, &trace, 2, 200, 200, 4);
    for (unsigned i = 1; i <= 24; i++) update(&pad, &trace, 2, 200, 200 + i, 4 + i / 100.0);
    assert(trace.count == 1 && trace.events[0].action == AKTrackpadScroll && trace.events[0].y == 1);
    update(&pad, &trace, 1, 600, 500, 4.25);
    update(&pad, &trace, 1, 700, 500, 4.26);
    update(&pad, &trace, 0, 0, 0, 4.3);
    assert(trace.count == 1);
    // Horizontal/negative wheel motion survives, and no fraction leaks to a new gesture.
    trace.count = 0;
    update(&pad, &trace, 2, 200, 200, 5);
    update(&pad, &trace, 2, 176, 188, 5.1);
    assert(trace.count == 1 && trace.events[0].x == -2 && trace.events[0].y == -1);
    update(&pad, &trace, 0, 0, 0, 5.2);
    // Hold then move drags; a second finger must cancel an existing left drag.
    trace.count = 0;
    update(&pad, &trace, 1, 0, 0, 6);
    AKTrackpadHold(&pad, 6.46, emit, &trace);
    AKTrackpadHold(&pad, 6.5, emit, &trace);
    update(&pad, &trace, 1, 50, 0, 6.6);
    update(&pad, &trace, 2, 200, 200, 6.7);
    update(&pad, &trace, 0, 0, 0, 6.8);
    assert(trace.count == 3 && trace.events[0].action == AKTrackpadDown);
    assert(trace.events[1].action == AKTrackpadMove && trace.events[2].action == AKTrackpadUp);
    // Two-finger hold supports a right drag (e.g. camera); interruption releases it once.
    trace.count = 0;
    update(&pad, &trace, 2, 10, 10, 7);
    AKTrackpadHold(&pad, 7.46, emit, &trace);
    update(&pad, &trace, 2, 15, 30, 7.5);
    AKTrackpadCancel(&pad, emit, &trace);
    AKTrackpadCancel(&pad, emit, &trace);
    update(&pad, &trace, 2, 100, 200, 7.6);
    update(&pad, &trace, 0, 0, 0, 7.7);
    assert(trace.count == 3 && trace.events[0].button == 1 && trace.events[2].button == 1);
    assert(trace.events[2].action == AKTrackpadUp && !pad.dragging);
    // A move cannot become a hold later. Long idle touches do not end in a click.
    trace.count = 0;
    update(&pad, &trace, 1, 0, 0, 8);
    update(&pad, &trace, 1, 50, 0, 8.1);
    AKTrackpadHold(&pad, 9, emit, &trace);
    update(&pad, &trace, 0, 0, 0, 9.1);
    assert(trace.count == 1 && trace.events[0].action == AKTrackpadMove);
    // Unexpected counts, invalid coordinates/time and cancellation must not click.
    for (unsigned kind = 0; kind < 4; kind++) {
        trace.count = 0;
        update(&pad, &trace, 1, 0, 0, 10);
        if (kind == 0) update(&pad, &trace, 4, 0, 0, 10.1);
        if (kind == 1) update(&pad, &trace, 1, NAN, 0, 10.1);
        if (kind == 2) update(&pad, &trace, 1, 0, 0, 9);
        if (kind == 3) AKTrackpadCancel(&pad, emit, &trace);
        update(&pad, &trace, 0, 0, 0, 10.2);
        assert(!trace.count);
    }
    puts("touch trackpad: relative motion, three buttons, scroll, drag, cancellation and invalid traces: PASS");
}
