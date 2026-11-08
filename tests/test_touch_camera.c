// Camera mode (TouchCamera.c): one finger turns the camera with the right
// button or right-clicks where it tapped; two fingers scroll or left-click.
#include "TouchCamera.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

typedef struct { AKTrackpadAction action; double x, y; unsigned button; } Event;
typedef struct { Event events[64]; unsigned count; } Trace;

static void emit(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    Trace *trace = context;
    assert(trace->count < 64);
    trace->events[trace->count++] = (Event){action, x, y, button};
}
static void update(AKTouchCamera *camera, Trace *trace, unsigned fingers, double x, double y) {
    AKTouchCameraUpdate(camera, fingers, x, y, emit, trace);
}
static void expect(const Event *event, AKTrackpadAction action, unsigned button) {
    assert(event->action == action && event->button == button);
}

int main(void) {
    AKTouchCamera camera = {0};
    Trace trace = {0};

    // A tap right-clicks where the finger landed: the pointer goes there first.
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 1, 302, 201);
    assert(trace.count == 0);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 3);
    expect(&trace.events[0], AKTrackpadPoint, 0);
    assert(trace.events[0].x == 300 && trace.events[0].y == 200);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[2], AKTrackpadUp, 1);

    // A slide presses the right button at its first movement past the slop
    // and sends all of the motion so far, then follows the finger linearly,
    // and releases on lift with no click.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 1, 303, 200);
    assert(trace.count == 0);
    update(&camera, &trace, 1, 306, 200);
    assert(trace.count == 3);
    expect(&trace.events[0], AKTrackpadPoint, 0);
    assert(trace.events[0].x == 300 && trace.events[0].y == 200);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[2], AKTrackpadMove, 1);
    assert(trace.events[2].x == 6 * AKTrackpadRightDragGain && trace.events[2].y == 0);
    update(&camera, &trace, 1, 306, 250);
    expect(&trace.events[3], AKTrackpadMove, 1);
    assert(trace.events[3].x == 0 && trace.events[3].y == 50 * AKTrackpadRightDragGain);
    update(&camera, &trace, 1, 306, 250);   // a repeated sample does not move
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 5);
    expect(&trace.events[4], AKTrackpadUp, 1);

    // Two fingers that slide scroll, with no button: a late second finger
    // before any movement never right-clicks.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 2, 320, 200);
    update(&camera, &trace, 2, 320, 260);
    update(&camera, &trace, 1, 320, 260);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 1);
    expect(&trace.events[0], AKTrackpadScroll, 0);
    assert(trace.events[0].x == 0 && trace.events[0].y == 5);

    // A two-finger tap left-clicks between the fingers; a three-finger tap does nothing.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 2, 320, 210);
    update(&camera, &trace, 1, 320, 210);
    update(&camera, &trace, 0, 0, 0);
    update(&camera, &trace, 3, 300, 200);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 3);
    expect(&trace.events[0], AKTrackpadPoint, 0);
    assert(trace.events[0].x == 320 && trace.events[0].y == 210);
    expect(&trace.events[1], AKTrackpadDown, 0);
    expect(&trace.events[2], AKTrackpadUp, 0);

    // A second finger during a camera drag ends it once; the rest of the
    // gesture is ignored until every finger lifts.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 1, 340, 200);
    update(&camera, &trace, 2, 340, 200);
    update(&camera, &trace, 2, 340, 300);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 4);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[3], AKTrackpadUp, 1);
    assert(!camera.pressed && !camera.fingers);

    // Cancellation releases once; the touch is then inert, and lifting it
    // neither clicks nor releases again. A new touch works normally.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 1, 360, 200);
    AKTouchCameraCancel(&camera, emit, &trace);
    update(&camera, &trace, 1, 400, 200);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 4);
    expect(&trace.events[3], AKTrackpadUp, 1);
    update(&camera, &trace, 1, 10, 10);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 7);
    expect(&trace.events[5], AKTrackpadDown, 1);

    // Invalid samples cancel without emitting motion.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200);
    update(&camera, &trace, 1, NAN, 200);
    update(&camera, &trace, 1, 1e9, 200);
    update(&camera, &trace, 4, 300, 200);
    update(&camera, &trace, 0, 0, 0);
    assert(trace.count == 0);

    puts("touch camera: tap right-clicks at the touch, slide holds the right button from the first movement, two-finger scroll and tap, cancellation and invalid traces: PASS");
    return 0;
}
