#import "AKSupport.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

void AKLogC(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("[ak] ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

void AKLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[ak] %s\n", s.UTF8String);
    // Opt-in launcher-owned descriptor: mirror only adapter input diagnostics,
    // never arbitrary guest text, while retaining the normal private log.
    const char *console=getenv("TOLKARA_INPUT_CONSOLE_FD");
    if (console && ([fmt hasPrefix:@"input dispatch"] || [fmt hasPrefix:@"mouse event"] ||
        [fmt hasPrefix:@"UIKit event"] || [fmt hasPrefix:@"host hit-test"] ||
        [fmt hasPrefix:@"window input heartbeat"] || [fmt hasPrefix:@"window ordered"]))
        dprintf(atoi(console),"[ak] %s\n",s.UTF8String);
}

void AKStubHit(const char *symbol, void *caller) {
    Dl_info info = {0};
    dladdr(caller, &info);
    AKLogC("STUB %s() called from %p %s+%#lx", symbol, caller, info.dli_fname ? strrchr(info.dli_fname, '/') + 1 : "?",
           info.dli_fbase ? (unsigned long)((char *)caller - (char *)info.dli_fbase) : 0UL);
}

@implementation AKStubObject
static void forward(id self, NSInvocation *inv) {
    static NSMutableSet *seen; static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *key = [NSString stringWithFormat:@"%c[%@ %@]", object_isClass(self) ? '+' : '-',
                     NSStringFromClass(object_getClass(self)), NSStringFromSelector(inv.selector)];
    @synchronized (seen) { if (![seen containsObject:key]) { [seen addObject:key]; AKLog(@"UNIMPLEMENTED %@", key); } }
    id zero = nil; [inv setReturnValue:&zero];
}
// Unknown selector: pretend it is `id f(id, SEL)`. Extra arguments are ignored by
// the callee on arm64; struct/float returns are NOT zeroed (discovery aid only).
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; }
+ (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [super methodSignatureForSelector:s] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; }
- (void)forwardInvocation:(NSInvocation *)i { forward(self, i); }
+ (void)forwardInvocation:(NSInvocation *)i { forward(self, i); }
@end

@implementation AKQuartzEvent { NSMutableDictionary<NSNumber *, NSNumber *> *_fields; }
- (instancetype)init { if ((self = [super init])) _fields = [NSMutableDictionary new]; return self; }
// A field reads as either kind, as Quartz converts between them; unset is zero.
- (int64_t)integerValueField:(uint32_t)field { @synchronized (self) { return _fields[@(field)].longLongValue; } }
- (double)doubleValueField:(uint32_t)field { @synchronized (self) { return _fields[@(field)].doubleValue; } }
- (void)setIntegerValueField:(uint32_t)field value:(int64_t)value { @synchronized (self) { _fields[@(field)] = @(value); } }
- (void)setDoubleValueField:(uint32_t)field value:(double)value { @synchronized (self) { _fields[@(field)] = @(value); } }
@end

#include <stdatomic.h>
static atomic_uint cursorHideCount;
bool AKCursorIsHidden(void) { return atomic_load(&cursorHideCount)>0; }
void AKCursorHide(void) { atomic_fetch_add(&cursorHideCount,1); }
void AKCursorUnhide(void) { unsigned count=atomic_load(&cursorHideCount); while(count && !atomic_compare_exchange_weak(&cursorHideCount,&count,count-1)) {} }
static atomic_bool mouseCaptured, mouseConfined;
bool AKMouseIsCaptured(void) { return atomic_load(&mouseCaptured) || atomic_load(&mouseConfined); }
void AKMouseSetCaptured(bool captured) {
    if(atomic_exchange(&mouseCaptured,captured)!=captured)
        [NSNotificationCenter.defaultCenter postNotificationName:@"AKMouseCaptureDidChange" object:nil];
}

#include <os/lock.h>
static os_unfair_lock screenLock = OS_UNFAIR_LOCK_INIT;
static double screenWidth, screenHeight;
bool AKScreenGameSize(double *width, double *height) {
    os_unfair_lock_lock(&screenLock);
    bool known = screenWidth > 0 && screenHeight > 0;
    if (known) { *width = screenWidth; *height = screenHeight; }
    os_unfair_lock_unlock(&screenLock);
    return known;
}
void AKScreenSetGameSize(double width, double height) {
    os_unfair_lock_lock(&screenLock);
    screenWidth = width; screenHeight = height;
    os_unfair_lock_unlock(&screenLock);
}

void AKMouseSetConfined(bool confined) {
    if(atomic_exchange(&mouseConfined,confined)!=confined)
        [NSNotificationCenter.defaultCenter postNotificationName:@"AKMouseCaptureDidChange" object:nil];
}

#include <stdatomic.h>
enum { AK_MAX_PROCESS_CALLBACK_SLOTS = 64 };
#define AK_CALLBACKS_RETIRED (UINT64_C(1) << 63)
static atomic_uint_fast64_t processCallbacks[AK_MAX_PROCESS_CALLBACK_SLOTS];
static size_t callbackProcessCount;
static size_t (*callbackOwner)(uintptr_t);
void AKConfigureProcessCallbacks(size_t count, size_t (*owner)(uintptr_t)) {
    callbackProcessCount = count <= AK_MAX_PROCESS_CALLBACK_SLOTS ? count : 0;
    callbackOwner = owner;
}
size_t AKCallbackProcess(uintptr_t address) {
    return callbackOwner ? callbackOwner(address) : SIZE_MAX;
}
bool AKEnterProcessCallback(size_t slot) {
    if (slot == SIZE_MAX && !callbackOwner) return true; // ordinary single-process adapter
    if (slot >= callbackProcessCount) return false;
    uint_fast64_t state = atomic_load(&processCallbacks[slot]);
    do {
        if (state & AK_CALLBACKS_RETIRED) return false;
    } while (!atomic_compare_exchange_weak(&processCallbacks[slot], &state, state + 1));
    return true;
}
void AKLeaveProcessCallback(size_t slot) {
    if (slot < callbackProcessCount) atomic_fetch_sub(&processCallbacks[slot], 1);
}
void AKRetireProcessCallbacks(size_t slot) {
    if (slot < callbackProcessCount) atomic_fetch_or(&processCallbacks[slot], AK_CALLBACKS_RETIRED);
}
bool AKProcessCallbacksDrained(size_t slot) {
    return slot < callbackProcessCount && atomic_load(&processCallbacks[slot]) == AK_CALLBACKS_RETIRED;
}

@interface AKProcessDispatchWork : NSObject
@property(nonatomic, copy) dispatch_block_t block;
@end
@implementation AKProcessDispatchWork @end

void AKDispatchProcessBlock(size_t slot, unsigned mode, dispatch_queue_t queue,
                            dispatch_time_t when, dispatch_block_t block) {
    if (!AKEnterProcessCallback(slot)) return;
    static NSMutableSet<AKProcessDispatchWork *> *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending=[NSMutableSet new]; });
    AKProcessDispatchWork *work=[AKProcessDispatchWork new];
    work.block=block; // Copy helpers may enter guest code: still leased here.
    @synchronized(pending) { [pending addObject:work]; }
    AKLeaveProcessCallback(slot);
    dispatch_block_t invoke=^{
        if (!AKEnterProcessCallback(slot)) return;
        @try { work.block(); }
        @finally {
            // Dispose helpers also belong to the guest lifetime. A work item
            // skipped after retirement stays retained, including its captures.
            work.block=nil;
            @synchronized(pending) { [pending removeObject:work]; }
            AKLeaveProcessCallback(slot);
        }
    };
    if (mode==1) dispatch_sync(queue,invoke);
    else if (mode==2) dispatch_after(when,queue,invoke);
    else dispatch_async(queue,invoke);
}
