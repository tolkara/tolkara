// Common support for all shim dylibs (libAKSupport.dylib).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Root for shim and generated stub classes: unknown selectors are logged once
// and return zero instead of raising, so the log shows what the guest really uses.
@interface AKStubObject : NSObject
@end
void AKLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#include <CoreGraphics/CGGeometry.h>
// A Quartz event: what the AppKit adapter's -[NSEvent CGEvent] hands out and
// the Core Graphics adapter's CGEvent functions read and change. The location
// is in global display coordinates (top-left origin, points), the timestamp
// in nanoseconds; fields are kept by their CGEventField number.
@interface AKQuartzEvent : NSObject
@property uint32_t type;
@property CGPoint location;
@property uint64_t timestamp, flags;
- (int64_t)integerValueField:(uint32_t)field;
- (double)doubleValueField:(uint32_t)field;
- (void)setIntegerValueField:(uint32_t)field value:(int64_t)value;
- (void)setDoubleValueField:(uint32_t)field value:(double)value;
@end
#endif
// Called by generated C stubs on first use.
void AKStubHit(const char *symbol, void *caller);
void AKLogC(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Shared cursor visibility for AppKit and Core Graphics adapters.
#include <stdbool.h>
bool AKCursorIsHidden(void);
void AKCursorHide(void);
void AKCursorUnhide(void);
bool AKMouseIsCaptured(void);
void AKMouseSetCaptured(bool captured);
void AKMouseSetConfined(bool confined);
// The display a guest sees, in points: the area its windows get, which is the
// screen minus the on-screen controls' side columns. Unset, it is the screen.
bool AKScreenGameSize(double *width, double *height);
void AKScreenSetGameSize(double width, double height);

// Native callbacks can outlive the guest pthread that registered them. The
// runtime supplies ownership; adapters gate entry and count callbacks already
// executing. Retirement is permanent for a process slot in this host session.
void AKConfigureProcessCallbacks(size_t count, size_t (*owner)(uintptr_t));
size_t AKCallbackProcess(uintptr_t address);
bool AKEnterProcessCallback(size_t slot);
void AKLeaveProcessCallback(size_t slot);
void AKRetireProcessCallbacks(size_t slot);
bool AKProcessCallbacksDrained(size_t slot);

#ifdef __OBJC__
// mode: 0 async, 1 sync, 2 after. Retired blocks remain retained so their
// captured guest objects cannot run destructors after private memory retires.
void AKDispatchProcessBlock(size_t slot, unsigned mode, dispatch_queue_t queue,
                            dispatch_time_t when, dispatch_block_t block);
#endif
