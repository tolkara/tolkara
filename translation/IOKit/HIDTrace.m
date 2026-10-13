// IOKit HID call tracing: what a guest's gamepad code does with IOHIDManager,
// IOHIDDevice and IOHIDQueue. On macOS, SDL's gamepad driver (which World of
// Warcraft embeds) enumerates joysticks through these calls; seeing them in
// the log tells whether that driver runs at all, and what the iPad's own
// IOKit answers it. Every wrapper forwards to the system function; only the
// trace itself is ours.
//
// --trace-iohid (launch argument) or Documents/trace-iohid (marker file)
// turns the trace on. Each distinct call is logged a few times at most.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import "AKSupport.h"
#include <dlfcn.h>
#include <stdatomic.h>

#define IOKIT_PATH "/System/Library/Frameworks/IOKit.framework/IOKit"

typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDDevice *IOHIDDeviceRef;
typedef struct __IOHIDElement *IOHIDElementRef;
typedef struct __IOHIDValue *IOHIDValueRef;
typedef struct __IOHIDQueue *IOHIDQueueRef;
typedef uint32_t IOHIDElementCookie;
typedef uint32_t IOHIDElementType;
typedef uint32_t IOHIDReportType;
typedef uint32_t IOHIDRequestType;
typedef uint32_t IOHIDAccessType;

static BOOL tracing;
static void configure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        tracing = [arguments containsObject:@"--trace-iohid"] ||
            [[NSFileManager defaultManager] fileExistsAtPath:
                [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/trace-iohid"]];
        if (tracing) AKLog(@"IOKit HID: tracing gamepad enumeration calls (--trace-iohid)");
    });
}
static void *realFunction(const char *name, void *wrapper) {
    void *function = dlsym(RTLD_NEXT, name);
    if (!function || function == wrapper) {
        void *handle = dlopen(IOKIT_PATH, RTLD_LAZY | RTLD_NOLOAD);
        function = handle ? dlsym(handle, name) : NULL;
        if (handle) dlclose(handle);
    }
    if (function == wrapper) function = NULL;
    if (!function && tracing) AKLog(@"IOKit HID: the system has no %s to forward to", name);
    return function;
}
// Each distinct call line at most three times, then silent.
static void traceCallKey(NSString *key, NSString *detail) {
    if (!tracing) return;
    static NSMutableDictionary<NSString *, NSNumber *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableDictionary new]; });
    @synchronized (seen) {
        NSUInteger count = seen[key].unsignedIntegerValue;
        if (count >= 3) return;
        seen[key] = @(count + 1);
    }
    AKLog(@"IOKit HID %@", detail);
}
static void traceCall(const char *symbol, NSString *detail) { traceCallKey(@(symbol), detail); }

// The system function behind the wrapper of the same name.
#define HIDREAL(name) \
    static __typeof__(name) *real; static dispatch_once_t once; \
    dispatch_once(&once, ^{ real = (__typeof__(name) *)realFunction(#name, (void *)name); })

#pragma mark - Event system client (IOHIDEventSystemClient, the HID service behind GameController)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreateSimpleClient(CFAllocatorRef allocator) {
    HIDREAL(IOHIDEventSystemClientCreateSimpleClient);
    configure();
    IOHIDEventSystemClientRef client = real ? real(allocator) : NULL;
    traceCall("IOHIDEventSystemClientCreateSimpleClient",
              [NSString stringWithFormat:@"IOHIDEventSystemClientCreateSimpleClient -> %p", (void *)client]);
    return client;
}
CFTypeRef IOHIDEventSystemClientCopyProperty(IOHIDEventSystemClientRef client, CFStringRef key) {
    HIDREAL(IOHIDEventSystemClientCopyProperty);
    configure();
    CFTypeRef value = real ? real(client, key) : NULL;
    NSString *property = key ? (__bridge NSString *)key : @"(null)";
    traceCallKey([@"IOHIDEventSystemClientCopyProperty " stringByAppendingString:property],
                 [NSString stringWithFormat:@"IOHIDEventSystemClientCopyProperty %p %@ -> %@", (void *)client, property,
                     value ? NSStringFromClass([(__bridge id)value class]) : @"(none)"]);
    return value;
}
void IOHIDEventSystemClientSetProperty(IOHIDEventSystemClientRef client, CFStringRef key, CFTypeRef property) {
    HIDREAL(IOHIDEventSystemClientSetProperty);
    configure();
    NSString *name = key ? (__bridge NSString *)key : @"(null)";
    traceCallKey([@"IOHIDEventSystemClientSetProperty " stringByAppendingString:name],
                 [NSString stringWithFormat:@"IOHIDEventSystemClientSetProperty %p %@ (%@)", (void *)client, name,
                     property ? NSStringFromClass([(__bridge id)property class]) : @"(null)"]);
    if (real) real(client, key, property);
}

#pragma mark - Manager

IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef allocator, IOOptionBits options) {
    HIDREAL(IOHIDManagerCreate);
    configure();
    IOHIDManagerRef manager = real ? real(allocator, options) : NULL;
    traceCall("IOHIDManagerCreate", [NSString stringWithFormat:@"IOHIDManagerCreate options=0x%x -> %p", (unsigned)options, (void *)manager]);
    return manager;
}
void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef multiple) {
    HIDREAL(IOHIDManagerSetDeviceMatchingMultiple);
    configure();
    NSArray *entries = (__bridge NSArray *)multiple;
    NSMutableArray *summaries = [NSMutableArray new];
    for (id entry in entries)
        if ([entry isKindOfClass:NSDictionary.class])
            [summaries addObject:[NSString stringWithFormat:@"{%@}", [[entry allKeys] componentsJoinedByString:@","]]];
    traceCall("IOHIDManagerSetDeviceMatchingMultiple",
              [NSString stringWithFormat:@"IOHIDManagerSetDeviceMatchingMultiple %lu matching entries: %@",
                  (unsigned long)entries.count, [summaries componentsJoinedByString:@" "]]);
    if (real) real(manager, multiple);
}
void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef manager, void *callback, void *context) {
    HIDREAL(IOHIDManagerRegisterDeviceMatchingCallback);
    configure();
    traceCall("IOHIDManagerRegisterDeviceMatchingCallback", @"IOHIDManagerRegisterDeviceMatchingCallback (device added callback set)");
    if (real) real(manager, callback, context);
}
void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef manager, void *callback, void *context) {
    HIDREAL(IOHIDManagerRegisterDeviceRemovalCallback);
    configure();
    if (real) real(manager, callback, context);
}
void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    HIDREAL(IOHIDManagerScheduleWithRunLoop);
    configure();
    traceCall("IOHIDManagerScheduleWithRunLoop", @"IOHIDManagerScheduleWithRunLoop");
    if (real) real(manager, runLoop, runLoopMode);
}
void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    HIDREAL(IOHIDManagerUnscheduleFromRunLoop);
    configure();
    if (real) real(manager, runLoop, runLoopMode);
}
IOReturn IOHIDManagerOpen(IOHIDManagerRef manager, IOOptionBits options) {
    HIDREAL(IOHIDManagerOpen);
    configure();
    IOReturn result = real ? real(manager, options) : kIOReturnUnsupported;
    traceCall("IOHIDManagerOpen", [NSString stringWithFormat:@"IOHIDManagerOpen options=0x%x -> 0x%x", (unsigned)options, result]);
    return result;
}
IOReturn IOHIDManagerClose(IOHIDManagerRef manager, IOOptionBits options) {
    HIDREAL(IOHIDManagerClose);
    configure();
    return real ? real(manager, options) : kIOReturnUnsupported;
}
CFSetRef IOHIDManagerCopyDevices(IOHIDManagerRef manager) {
    HIDREAL(IOHIDManagerCopyDevices);
    configure();
    CFSetRef devices = real ? real(manager) : NULL;
    traceCall("IOHIDManagerCopyDevices", [NSString stringWithFormat:@"IOHIDManagerCopyDevices -> %lu device(s)",
        devices ? (unsigned long)CFSetGetCount(devices) : 0UL]);
    return devices;
}

#pragma mark - Device

IOHIDDeviceRef IOHIDDeviceCreate(CFAllocatorRef allocator, io_service_t service) {
    HIDREAL(IOHIDDeviceCreate);
    configure();
    IOHIDDeviceRef device = real ? real(allocator, service) : NULL;
    traceCall("IOHIDDeviceCreate", [NSString stringWithFormat:@"IOHIDDeviceCreate service=0x%x -> %p", service, (void *)device]);
    return device;
}
IOReturn IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options) {
    HIDREAL(IOHIDDeviceOpen);
    configure();
    IOReturn result = real ? real(device, options) : kIOReturnUnsupported;
    traceCall("IOHIDDeviceOpen", [NSString stringWithFormat:@"IOHIDDeviceOpen %p -> 0x%x", (void *)device, result]);
    return result;
}
IOReturn IOHIDDeviceClose(IOHIDDeviceRef device, IOOptionBits options) {
    HIDREAL(IOHIDDeviceClose);
    configure();
    return real ? real(device, options) : kIOReturnUnsupported;
}
CFArrayRef IOHIDDeviceCopyMatchingElements(IOHIDDeviceRef device, CFDictionaryRef matching, IOOptionBits options) {
    HIDREAL(IOHIDDeviceCopyMatchingElements);
    configure();
    CFArrayRef elements = real ? real(device, matching, options) : NULL;
    traceCall("IOHIDDeviceCopyMatchingElements", [NSString stringWithFormat:@"IOHIDDeviceCopyMatchingElements %p -> %lu element(s)",
        (void *)device, elements ? (unsigned long)CFArrayGetCount(elements) : 0UL]);
    return elements;
}
CFTypeRef IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    HIDREAL(IOHIDDeviceGetProperty);
    configure();
    CFTypeRef value = real ? real(device, key) : NULL;
    NSString *property = key ? (__bridge NSString *)key : @"(null)";
    traceCallKey([@"IOHIDDeviceGetProperty " stringByAppendingString:property],
                 [NSString stringWithFormat:@"IOHIDDeviceGetProperty %p %@ -> %@", (void *)device, property,
                     value ? NSStringFromClass([(__bridge id)value class]) : @"(none)"]);
    return value;
}
void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report, CFIndex reportLength, void *callback, void *context) {
    HIDREAL(IOHIDDeviceRegisterInputReportCallback);
    configure();
    traceCall("IOHIDDeviceRegisterInputReportCallback",
              [NSString stringWithFormat:@"IOHIDDeviceRegisterInputReportCallback %p length=%ld (input report callback set)",
                  (void *)device, (long)reportLength]);
    if (real) real(device, report, reportLength, callback, context);
}
void IOHIDDeviceRegisterRemovalCallback(IOHIDDeviceRef device, void *callback, void *context) {
    HIDREAL(IOHIDDeviceRegisterRemovalCallback);
    configure();
    if (real) real(device, callback, context);
}
void IOHIDDeviceScheduleWithRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    HIDREAL(IOHIDDeviceScheduleWithRunLoop);
    configure();
    traceCall("IOHIDDeviceScheduleWithRunLoop", [NSString stringWithFormat:@"IOHIDDeviceScheduleWithRunLoop %p", (void *)device]);
    if (real) real(device, runLoop, runLoopMode);
}
void IOHIDDeviceUnscheduleFromRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode) {
    HIDREAL(IOHIDDeviceUnscheduleFromRunLoop);
    configure();
    if (real) real(device, runLoop, runLoopMode);
}
io_service_t IOHIDDeviceGetService(IOHIDDeviceRef device) {
    HIDREAL(IOHIDDeviceGetService);
    configure();
    return real ? real(device) : 0;
}
IOReturn IOHIDDeviceGetValue(IOHIDDeviceRef device, IOHIDElementRef element, IOHIDValueRef *value) {
    HIDREAL(IOHIDDeviceGetValue);
    configure();
    return real ? real(device, element, value) : kIOReturnUnsupported;
}
IOReturn IOHIDDeviceGetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID, uint8_t *report, CFIndex *length) {
    HIDREAL(IOHIDDeviceGetReport);
    configure();
    IOReturn result = real ? real(device, type, reportID, report, length) : kIOReturnUnsupported;
    traceCall("IOHIDDeviceGetReport", [NSString stringWithFormat:@"IOHIDDeviceGetReport type=%u id=%ld -> 0x%x",
        (unsigned)type, (long)reportID, result]);
    return result;
}
IOReturn IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID, const uint8_t *report, CFIndex length) {
    HIDREAL(IOHIDDeviceSetReport);
    configure();
    return real ? real(device, type, reportID, report, length) : kIOReturnUnsupported;
}

#pragma mark - Queue and values

IOHIDQueueRef IOHIDQueueCreate(CFAllocatorRef allocator, IOHIDDeviceRef device, CFIndex depth, IOOptionBits options) {
    HIDREAL(IOHIDQueueCreate);
    configure();
    IOHIDQueueRef queue = real ? real(allocator, device, depth, options) : NULL;
    traceCall("IOHIDQueueCreate", [NSString stringWithFormat:@"IOHIDQueueCreate %p depth=%ld -> %p", (void *)device, (long)depth, (void *)queue]);
    return queue;
}
void IOHIDQueueStart(IOHIDQueueRef queue) {
    HIDREAL(IOHIDQueueStart);
    configure();
    traceCall("IOHIDQueueStart", @"IOHIDQueueStart");
    if (real) real(queue);
}
void IOHIDQueueStop(IOHIDQueueRef queue) {
    HIDREAL(IOHIDQueueStop);
    configure();
    if (real) real(queue);
}
void IOHIDQueueAddElement(IOHIDQueueRef queue, IOHIDElementRef element) {
    HIDREAL(IOHIDQueueAddElement);
    configure();
    if (real) real(queue, element);
}
Boolean IOHIDQueueContainsElement(IOHIDQueueRef queue, IOHIDElementRef element) {
    HIDREAL(IOHIDQueueContainsElement);
    configure();
    return real ? real(queue, element) : false;
}
IOHIDValueRef IOHIDQueueCopyNextValueWithTimeout(IOHIDQueueRef queue, CFTimeInterval timeout) {
    HIDREAL(IOHIDQueueCopyNextValueWithTimeout);
    configure();
    traceCall("IOHIDQueueCopyNextValueWithTimeout", @"IOHIDQueueCopyNextValueWithTimeout (waiting for an input report)");
    return real ? real(queue, timeout) : NULL;
}
IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value) {
    HIDREAL(IOHIDValueGetElement);
    configure();
    return real ? real(value) : NULL;
}
CFIndex IOHIDValueGetIntegerValue(IOHIDValueRef value) {
    HIDREAL(IOHIDValueGetIntegerValue);
    configure();
    return real ? real(value) : 0;
}
uint32_t IOHIDElementGetUsagePage(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetUsagePage);
    configure();
    return real ? real(element) : 0;
}
uint32_t IOHIDElementGetUsage(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetUsage);
    configure();
    return real ? real(element) : 0;
}
IOHIDElementType IOHIDElementGetType(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetType);
    configure();
    return real ? real(element) : 0;
}
IOHIDElementCookie IOHIDElementGetCookie(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetCookie);
    configure();
    return real ? real(element) : 0;
}
CFIndex IOHIDElementGetLogicalMin(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetLogicalMin);
    configure();
    return real ? real(element) : 0;
}
CFIndex IOHIDElementGetLogicalMax(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetLogicalMax);
    configure();
    return real ? real(element) : 0;
}
CFArrayRef IOHIDElementGetChildren(IOHIDElementRef element) {
    HIDREAL(IOHIDElementGetChildren);
    configure();
    return real ? real(element) : NULL;
}
IOHIDAccessType IOHIDCheckAccess(IOHIDRequestType requestType) {
    HIDREAL(IOHIDCheckAccess);
    configure();
    IOHIDAccessType access = real ? real(requestType) : 0;
    traceCall("IOHIDCheckAccess", [NSString stringWithFormat:@"IOHIDCheckAccess type=%u -> %u", (unsigned)requestType, (unsigned)access]);
    return access;
}
Boolean IOHIDRequestAccess(IOHIDRequestType requestType) {
    HIDREAL(IOHIDRequestAccess);
    configure();
    Boolean granted = real ? real(requestType) : false;
    traceCall("IOHIDRequestAccess", [NSString stringWithFormat:@"IOHIDRequestAccess type=%u -> %s", (unsigned)requestType, granted ? "granted" : "refused"]);
    return granted;
}
void IODispatchCalloutFromMessage(void *unused, mach_msg_header_t *message, void *callbackData) {
    HIDREAL(IODispatchCalloutFromMessage);
    configure();
    if (real) real(unused, message, callbackData);
}
