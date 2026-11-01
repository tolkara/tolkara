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
    double gain = AKTrackpadGain(hypot(20, 20) / 0.1);
    assert(gain > 1 && gain < 1.5);
    assert(fabs(trace.events[0].x - 20 * gain) < 1e-9 && fabs(trace.events[0].y + 20 * gain) < 1e-9);
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
    // Holding one still finger is a right click (as in the Windows App); the
    // rest of that touch neither moves nor clicks. Two fingers held right-drag.
    trace.count = 0;
    update(&pad, &trace, 1, 0, 0, 6);
    AKTrackpadHold(&pad, 6.3, emit, &trace);
    assert(!trace.count);
    AKTrackpadHold(&pad, 6.46, emit, &trace);
    AKTrackpadHold(&pad, 6.5, emit, &trace);
    update(&pad, &trace, 1, 50, 0, 6.6);
    update(&pad, &trace, 0, 0, 0, 6.8);
    assert(trace.count == 2 && trace.events[0].action == AKTrackpadDown && trace.events[0].button == 1);
    assert(trace.events[1].action == AKTrackpadUp && trace.events[1].button == 1);
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
    assert(trace.events[1].action == AKTrackpadMove && trace.events[2].action == AKTrackpadUp && !pad.dragging);
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
    // Pointer gain: slower than the finger when aiming, faster for a flick,
    // never decreasing with speed and capped.
    assert(AKTrackpadGain(0) == 0.8 && AKTrackpadGain(150) == 1 && AKTrackpadGain(NAN) == 0.8);
    for (double speed = 0; speed < 3000; speed += 10) assert(AKTrackpadGain(speed + 10) >= AKTrackpadGain(speed));
    assert(AKTrackpadGain(1200) == 2.5 && AKTrackpadGain(100000) == 2.5);
    // Repeated still samples (another touch's events) do not shorten the
    // interval the next motion's speed is measured over.
    trace.count = 0;
    update(&pad, &trace, 1, 0, 0, 15);
    for (unsigned i = 1; i <= 9; i++) update(&pad, &trace, 1, 0, 0, 15 + i / 100.0);
    update(&pad, &trace, 1, 10, 0, 15.1);
    update(&pad, &trace, 0, 0, 0, 15.2);
    assert(trace.count == 1 && fabs(trace.events[0].x - 10 * AKTrackpadGain(100)) < 1e-9);
    // Double tap and hold: a tap and an immediate second touch that slides
    // presses the right button (e.g. to steer a camera) once it moves past
    // the tap slop, and holds it until the finger lifts.
    trace.count = 0;
    update(&pad, &trace, 1, 300, 200, 20);
    update(&pad, &trace, 0, 0, 0, 20.1);
    update(&pad, &trace, 1, 310, 205, 20.3);
    update(&pad, &trace, 1, 312, 205, 20.35);
    assert(trace.count == 2);
    update(&pad, &trace, 1, 360, 205, 20.5);
    AKTrackpadHold(&pad, 21, emit, &trace);
    update(&pad, &trace, 1, 400, 205, 21.5);
    update(&pad, &trace, 0, 0, 0, 21.6);
    assert(trace.count == 6);
    assert(trace.events[0].action == AKTrackpadDown && trace.events[0].button == 0 && trace.events[1].action == AKTrackpadUp);
    assert(trace.events[2].action == AKTrackpadDown && trace.events[2].button == 1);
    assert(trace.events[3].action == AKTrackpadMove && trace.events[3].button == 1 && trace.events[4].action == AKTrackpadMove);
    // The held right button (camera) moves linearly: the same gain at any speed.
    assert(trace.events[3].x == 48 * AKTrackpadRightDragGain && trace.events[4].x == 40 * AKTrackpadRightDragGain);
    assert(trace.events[5].action == AKTrackpadUp && trace.events[5].button == 1);
    // Held still instead, the right button goes down at the hold and is
    // released on lift, with no click at the end.
    trace.count = 0;
    update(&pad, &trace, 1, 300, 200, 25);
    update(&pad, &trace, 0, 0, 0, 25.1);
    update(&pad, &trace, 1, 300, 200, 25.2);
    AKTrackpadHold(&pad, 25.66, emit, &trace);
    AKTrackpadHold(&pad, 25.7, emit, &trace);
    update(&pad, &trace, 0, 0, 0, 26);
    assert(trace.count == 4 && trace.events[2].action == AKTrackpadDown && trace.events[2].button == 1);
    assert(trace.events[3].action == AKTrackpadUp && trace.events[3].button == 1);
    // A quick second tap is a double click (the host counts the clicks), and
    // a third tap right after it is a single click again, not a hold.
    trace.count = 0;
    update(&pad, &trace, 1, 300, 200, 30);
    update(&pad, &trace, 0, 0, 0, 30.1);
    update(&pad, &trace, 1, 300, 200, 30.2);
    update(&pad, &trace, 0, 0, 0, 30.3);
    update(&pad, &trace, 1, 300, 200, 30.4);
    update(&pad, &trace, 0, 0, 0, 30.5);
    assert(trace.count == 6);
    for (unsigned i = 0; i < 6; i++)
        assert(trace.events[i].action == (i % 2 ? AKTrackpadUp : AKTrackpadDown) && trace.events[i].button == 0);
    // Too late, too far away or after a slide, the next touch only moves.
    for (unsigned kind = 0; kind < 3; kind++) {
        trace.count = 0;
        update(&pad, &trace, 1, 300, 200, 40);
        if (kind == 2) update(&pad, &trace, 1, 330, 200, 40.05);
        update(&pad, &trace, 0, 0, 0, 40.1);
        unsigned before = trace.count;
        update(&pad, &trace, 1, kind == 1 ? 500 : 300, 200, kind == 0 ? 40.5 : 40.2);
        update(&pad, &trace, 1, 350, 220, 40.6);
        update(&pad, &trace, 0, 0, 0, 40.7);
        assert(trace.count == before + 1 && trace.events[before].action == AKTrackpadMove);
    }
    // Only a one-finger tap starts a double tap and hold: after a two-finger
    // tap (a right click) a sliding finger only moves, and a second
    // two-finger tap is another right click.
    trace.count = 0;
    update(&pad, &trace, 2, 300, 200, 50);
    update(&pad, &trace, 0, 0, 0, 50.1);
    update(&pad, &trace, 1, 300, 200, 50.2);
    update(&pad, &trace, 1, 340, 180, 50.5);
    update(&pad, &trace, 0, 0, 0, 50.6);
    update(&pad, &trace, 2, 300, 200, 51);
    update(&pad, &trace, 0, 0, 0, 51.1);
    update(&pad, &trace, 2, 300, 200, 51.2);
    update(&pad, &trace, 0, 0, 0, 51.3);
    assert(trace.count == 7 && trace.events[1].button == 1 && trace.events[2].action == AKTrackpadMove);
    for (unsigned i = 3; i < 7; i++) assert(trace.events[i].button == 1 && trace.events[i].action != AKTrackpadMove);
    // A double-tap hold ends once if a second finger lands or it is cancelled.
    for (unsigned kind = 0; kind < 2; kind++) {
        trace.count = 0;
        update(&pad, &trace, 1, 300, 200, 60);
        update(&pad, &trace, 0, 0, 0, 60.1);
        update(&pad, &trace, 1, 300, 200, 60.2);
        update(&pad, &trace, 1, 340, 200, 60.25);
        if (kind) AKTrackpadCancel(&pad, emit, &trace);
        else update(&pad, &trace, 2, 300, 200, 60.3);
        update(&pad, &trace, 2, 400, 300, 60.4);
        update(&pad, &trace, 0, 0, 0, 60.5);
        assert(trace.count == 5 && trace.events[2].button == 1 && trace.events[3].action == AKTrackpadMove);
        assert(trace.events[4].action == AKTrackpadUp && trace.events[4].button == 1 && !pad.dragging);
    }
    // A second finger joining a double tap before it presses makes an
    // ordinary two-finger gesture: here a tap, so one right click.
    trace.count = 0;
    update(&pad, &trace, 1, 300, 200, 70);
    update(&pad, &trace, 0, 0, 0, 70.1);
    update(&pad, &trace, 1, 300, 200, 70.2);
    update(&pad, &trace, 2, 320, 200, 70.22);
    AKTrackpadHold(&pad, 70.3, emit, &trace);
    update(&pad, &trace, 0, 0, 0, 70.35);
    assert(trace.count == 4 && trace.events[2].action == AKTrackpadDown && trace.events[2].button == 1);
    assert(trace.events[3].action == AKTrackpadUp && !pad.dragging);
    puts("touch trackpad: relative motion with gain, three buttons, long-press right click, double tap and hold for the right button, scroll, right drag, cancellation and invalid traces: PASS");
}
