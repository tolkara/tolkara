#include "TouchStick.h"
#include <math.h>
#include <string.h>

unsigned AKStickDirections(double dx, double dy) {
    if (!isfinite(dx) || !isfinite(dy) || hypot(dx, dy) < AKStickDeadZone) return 0;
    // Eight 45-degree sectors: straight within 22.5 degrees of an axis,
    // otherwise the two keys of that diagonal.
    double angle = atan2(-dy, dx) * 180 / M_PI;
    unsigned directions = 0;
    if (angle > 22.5 && angle < 157.5) directions |= AKStickUp;
    if (angle < -22.5 && angle > -157.5) directions |= AKStickDown;
    if (fabs(angle) < 67.5) directions |= AKStickRight;
    if (fabs(angle) > 112.5) directions |= AKStickLeft;
    return directions;
}

static void AKStickSet(AKStick *stick, unsigned directions, AKStickEmit emit, void *context) {
    unsigned released = stick->directions & ~directions, pressed = directions & ~stick->directions;
    stick->directions = directions;
    for (unsigned bit = 1; bit <= AKStickRight; bit <<= 1) if (released & bit) emit(context, bit, false);
    for (unsigned bit = 1; bit <= AKStickRight; bit <<= 1) if (pressed & bit) emit(context, bit, true);
}

void AKStickBegin(AKStick *stick, double x, double y) {
    memset(stick, 0, sizeof *stick);
    if (!isfinite(x) || !isfinite(y)) return;
    stick->active = true;
    stick->originX = stick->x = x;
    stick->originY = stick->y = y;
}

void AKStickMove(AKStick *stick, double x, double y, AKStickEmit emit, void *context) {
    if (!stick->active) return;
    if (!isfinite(x) || !isfinite(y)) { AKStickEnd(stick, emit, context); return; }
    double dx = x - stick->originX, dy = y - stick->originY, distance = hypot(dx, dy);
    if (distance > AKStickRadius) {
        // Past the rim the centre is dragged along, so reversing direction
        // takes the same short motion wherever the finger has wandered.
        stick->originX = x - dx / distance * AKStickRadius;
        stick->originY = y - dy / distance * AKStickRadius;
        dx = x - stick->originX; dy = y - stick->originY;
    }
    stick->x = x; stick->y = y;
    AKStickSet(stick, AKStickDirections(dx, dy), emit, context);
}

void AKStickEnd(AKStick *stick, AKStickEmit emit, void *context) {
    AKStickSet(stick, 0, emit, context);
    memset(stick, 0, sizeof *stick);
}
