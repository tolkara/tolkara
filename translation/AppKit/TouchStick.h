#pragma once
#include <stdbool.h>

// A floating movement stick from direct finger input: its centre is where the
// finger lands and follows the finger past the rim. Coordinates are UIKit
// points (y down). It reports direction keys only; it never generates input
// on its own or inspects a guest.
enum { AKStickUp = 1, AKStickLeft = 2, AKStickDown = 4, AKStickRight = 8 };
typedef void (*AKStickEmit)(void *context, unsigned direction, bool pressed);
typedef struct {
    bool active;
    double originX, originY, x, y;
    unsigned directions;
} AKStick;

#define AKStickDeadZone 12.0
#define AKStickRadius 56.0

void AKStickBegin(AKStick *stick, double x, double y);
void AKStickMove(AKStick *stick, double x, double y, AKStickEmit emit, void *context);
// Lifting or cancelling releases every direction still pressed.
void AKStickEnd(AKStick *stick, AKStickEmit emit, void *context);
// The directions pressed for an offset from the centre: one or, on a diagonal, two.
unsigned AKStickDirections(double dx, double dy);
