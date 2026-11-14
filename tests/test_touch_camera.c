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
static void update(AKTouchCamera *camera, Trace *trace, unsigned fingers, double x, double y, double time) {
    AKTouchCameraUpdate(camera, fingers, x, y, time, emit, trace);
}
static void expect(const Event *event, AKTrackpadAction action, unsigned button) {
    assert(event->action == action && event->button == button);
}
static bool near(double a, double b) { return fabs(a - b) < 1e-9; }

int main(void) {
    AKTouchCamera camera = {0};
    Trace trace = {0};
    const double gain = AKTrackpadRightDragGain;

    // The pointer goes to the finger as it lands; lifting it without sliding
    // (a wobble inside the slop included) right-clicks there.
    update(&camera, &trace, 1, 300, 200, 1);
    assert(trace.count == 1);
    expect(&trace.events[0], AKTrackpadPoint, 0);
    assert(trace.events[0].x == 300 && trace.events[0].y == 200);
    update(&camera, &trace, 1, 302, 201, 1.05);
    assert(trace.count == 1);
    update(&camera, &trace, 0, 0, 0, 1.1);
    assert(trace.count == 3);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[2], AKTrackpadUp, 1);

    // A slide presses the right button with the first movement past the slop.
    // That first step, which iOS reports late and all at once, is eased in:
    // limited to the start step, then doubling, then whole.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 2);
    update(&camera, &trace, 1, 312, 200, 2.1);      // iOS's first report: 12 points at once
    assert(trace.count == 3);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[2], AKTrackpadMove, 1);
    assert(near(trace.events[2].x, AKTouchStartStep * gain) && trace.events[2].y == 0);
    update(&camera, &trace, 1, 322, 200, 2.11);     // 10 points: limited to twice the step before
    assert(near(trace.events[3].x, 2 * AKTouchStartStep * gain));
    update(&camera, &trace, 1, 325, 204, 2.12);     // 5 points: under the limit, whole
    assert(near(trace.events[4].x, 3 * gain) && near(trace.events[4].y, 4 * gain));
    update(&camera, &trace, 1, 325, 254, 2.3);      // after the start: whole at any size
    assert(trace.events[5].x == 0 && near(trace.events[5].y, 50 * gain));
    update(&camera, &trace, 1, 325, 254, 2.4);      // a repeated sample does not move
    update(&camera, &trace, 0, 0, 0, 2.5);
    assert(trace.count == 7);
    expect(&trace.events[6], AKTrackpadUp, 1);

    // A slow slide loses nothing: small steps pass whole from the first.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 3);
    update(&camera, &trace, 1, 301, 200, 3.01);     // inside the slop: not yet a slide
    update(&camera, &trace, 1, 302, 200, 3.02);
    update(&camera, &trace, 1, 303, 200, 3.03);
    assert(trace.count == 1);
    update(&camera, &trace, 1, 304, 200, 3.04);
    update(&camera, &trace, 1, 305.5, 200, 3.05);
    assert(trace.count == 4);
    expect(&trace.events[1], AKTrackpadDown, 1);
    assert(near(trace.events[2].x, gain) && near(trace.events[3].x, 1.5 * gain));
    update(&camera, &trace, 0, 0, 0, 3.1);
    expect(&trace.events[4], AKTrackpadUp, 1);

    // Two fingers that slide scroll, with no button: a late second finger
    // before any movement never right-clicks.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 4);
    update(&camera, &trace, 2, 320, 200, 4.05);
    update(&camera, &trace, 2, 320, 260, 4.1);
    update(&camera, &trace, 1, 320, 260, 4.2);
    update(&camera, &trace, 0, 0, 0, 4.3);
    assert(trace.count == 2);
    expect(&trace.events[0], AKTrackpadPoint, 0);
    expect(&trace.events[1], AKTrackpadScroll, 0);
    assert(trace.events[1].x == 0 && trace.events[1].y == 5);

    // A two-finger tap left-clicks between the fingers, a wobble included; a
    // three-finger tap does nothing.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 5);
    update(&camera, &trace, 2, 320, 210, 5.03);
    update(&camera, &trace, 2, 323, 212, 5.06);
    update(&camera, &trace, 1, 320, 210, 5.1);
    update(&camera, &trace, 0, 0, 0, 5.12);
    update(&camera, &trace, 3, 300, 200, 5.5);
    update(&camera, &trace, 0, 0, 0, 5.6);
    assert(trace.count == 4);
    expect(&trace.events[1], AKTrackpadPoint, 0);
    assert(trace.events[1].x == 320 && trace.events[1].y == 210);
    expect(&trace.events[2], AKTrackpadDown, 0);
    expect(&trace.events[3], AKTrackpadUp, 0);

    // A second finger during a camera drag ends it once; the rest of the
    // gesture is ignored until every finger lifts.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 6);
    update(&camera, &trace, 1, 340, 200, 6.1);
    update(&camera, &trace, 2, 340, 200, 6.2);
    update(&camera, &trace, 2, 340, 300, 6.3);
    update(&camera, &trace, 0, 0, 0, 6.4);
    assert(trace.count == 4);
    expect(&trace.events[1], AKTrackpadDown, 1);
    expect(&trace.events[3], AKTrackpadUp, 1);
    assert(!camera.pressed && !camera.fingers);

    // Cancellation releases once; the touch is then inert, and lifting it
    // neither clicks nor releases again. A new touch works normally.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 7);
    update(&camera, &trace, 1, 360, 200, 7.1);
    AKTouchCameraCancel(&camera, emit, &trace);
    update(&camera, &trace, 1, 400, 200, 7.2);
    update(&camera, &trace, 0, 0, 0, 7.3);
    assert(trace.count == 4);
    expect(&trace.events[3], AKTrackpadUp, 1);
    update(&camera, &trace, 1, 10, 10, 7.5);
    update(&camera, &trace, 0, 0, 0, 7.6);
    assert(trace.count == 7);
    expect(&trace.events[5], AKTrackpadDown, 1);

    // Invalid samples cancel without a button or motion.
    trace.count = 0;
    update(&camera, &trace, 1, 300, 200, 8);
    update(&camera, &trace, 1, NAN, 200, 8.1);
    update(&camera, &trace, 1, 1e9, 200, 8.2);
    update(&camera, &trace, 4, 300, 200, 8.3);
    update(&camera, &trace, 0, 0, 0, 8.4);
    assert(trace.count == 1);
    expect(&trace.events[0], AKTrackpadPoint, 0);

    puts("touch camera: pointer at the touch, tap right-clicks, slide holds the right button from the first movement with an eased start, two-finger scroll and tap, cancellation and invalid traces: PASS");
    return 0;
}
