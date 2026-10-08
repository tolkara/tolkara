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
