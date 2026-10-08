#pragma once
#include <stdbool.h>

// Direct finger input only. Coordinates/deltas are UIKit points (y down).
// The state machine does not inspect a guest or generate input on its own.
typedef enum { AKTrackpadMove, AKTrackpadScroll, AKTrackpadDown, AKTrackpadUp } AKTrackpadAction;
typedef void (*AKTrackpadEmit)(void *context, AKTrackpadAction action, double x, double y, unsigned button);
typedef struct {
    unsigned fingers, peak;
    double x, y, started, travelled, scrollX, scrollY;
    bool blocked, lifting, dragging;
    unsigned button;
} AKTrackpad;

void AKTrackpadUpdate(AKTrackpad *pad, unsigned fingers, double x, double y, double time,
                     AKTrackpadEmit emit, void *context);
void AKTrackpadHold(AKTrackpad *pad, double time, AKTrackpadEmit emit, void *context);
// Suppress the remainder of a cancelled gesture until every finger is lifted.
void AKTrackpadCancel(AKTrackpad *pad, AKTrackpadEmit emit, void *context);
