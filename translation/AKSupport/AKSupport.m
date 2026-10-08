#import "AKSupport.h"
#import <objc/runtime.h>
#include <dlfcn.h>

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

void AKMouseSetConfined(bool confined) {
    if(atomic_exchange(&mouseConfined,confined)!=confined)
        [NSNotificationCenter.defaultCenter postNotificationName:@"AKMouseCaptureDidChange" object:nil];
}
