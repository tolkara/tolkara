#import <UIKit/UIKit.h>
#include <stdint.h>
#import "AKSupport.h"
#import <Metal/Metal.h>
bool CGCursorIsVisible(void) { return !AKCursorIsHidden(); }
CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { AKMouseSetCaptured(!connected); return kCGErrorSuccess; }
CGError CGWarpMouseCursorPosition(CGPoint point) {
    if(!AKMouseIsCaptured())return kCGErrorNotImplemented;
    [NSNotificationCenter.defaultCenter postNotificationName:@"AKMouseAnchorChanged" object:nil userInfo:@{@"x":@(point.x),@"y":@(point.y)}];
    return kCGErrorSuccess;
}
typedef uint32_t CGDirectDisplayID;
// The guest's display: the game area when the on-screen controls take side columns.
static CGRect displayBounds(void) {
    double width, height;
    return AKScreenGameSize(&width, &height) ? CGRectMake(0, 0, width, height) : UIScreen.mainScreen.bounds;
}
typedef CFDictionaryRef CGDisplayModeRef;
typedef void (*DisplayCallback)(CGDirectDisplayID, uint32_t, void *);
static NSDictionary *mode(void) { UIScreen *s=UIScreen.mainScreen; CGSize b=displayBounds().size; return @{@"width":@(b.width),@"height":@(b.height),@"pixelWidth":@(b.width*s.nativeScale),@"pixelHeight":@(b.height*s.nativeScale),@"refresh":@(s.maximumFramesPerSecond)}; }
CGDirectDisplayID CGMainDisplayID(void) { return 1; }
CGError CGGetActiveDisplayList(uint32_t capacity,CGDirectDisplayID *displays,uint32_t *count) {
    if (!count || (capacity && !displays)) return kCGErrorIllegalArgument;
    *count=displays ? (capacity ? 1 : 0) : 1; if(displays && capacity) displays[0]=1; return kCGErrorSuccess;
}
// Every display there is is online, and there is one.
CGError CGGetOnlineDisplayList(uint32_t capacity,CGDirectDisplayID *displays,uint32_t *count) { return CGGetActiveDisplayList(capacity,displays,count); }
CGRect CGDisplayBounds(CGDirectDisplayID d) { return d==1 ? displayBounds() : CGRectZero; }
// In millimetres, at the 132 points per inch of an iPad's screen.
CGSize CGDisplayScreenSize(CGDirectDisplayID d) {
    if(d!=1) return CGSizeZero;
    CGSize points=displayBounds().size;
    return CGSizeMake(points.width*25.4/132.0,points.height*25.4/132.0);
}
double CGDisplayRotation(CGDirectDisplayID d) { (void)d; return 0; }
uint32_t CGDisplayUnitNumber(CGDirectDisplayID d) { (void)d; return 0; }
CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID d) { (void)d; return 0; }
uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID d) { return d==1 ? 1 : 0; }
CGDirectDisplayID CGOpenGLDisplayMaskToDisplayID(uint32_t mask) { return (mask&1) ? 1 : 0; }
mach_port_t CGDisplayIOServicePort(CGDirectDisplayID d) { (void)d; return MACH_PORT_NULL; }
id<MTLDevice> CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID d) { return d==1 ? MTLCreateSystemDefaultDevice() : nil; }
// Full-screen programs capture the displays and put their window above the
// shield; an iPad app has its screen to itself already.
CGError CGCaptureAllDisplays(void) { return kCGErrorSuccess; }
CGError CGReleaseAllDisplays(void) { return kCGErrorSuccess; }
int32_t CGShieldingWindowLevel(void) { return 2147483628; }
void CGRestorePermanentDisplayConfiguration(void) {}
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID d) { return d==1 ? CFBridgingRetain(mode()) : NULL; }
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID d,CFDictionaryRef options) { (void)options; return d==1 ? CFBridgingRetain(@[mode()]) : NULL; }
CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef m) { if(m) CFRetain(m); return m; }
// The screen's mode is the only one; asking for it again succeeds.
CGError CGDisplaySetDisplayMode(CGDirectDisplayID d,CGDisplayModeRef m,CFDictionaryRef options) {
    (void)options;
    if(d!=1 || !m) return kCGErrorIllegalArgument;
    return [(__bridge NSDictionary *)m isEqual:mode()] ? kCGErrorSuccess : kCGErrorIllegalArgument;
}
uint32_t CGDisplayVendorNumber(CGDirectDisplayID d) { return d==1 ? 0x610 : 0; }
uint32_t CGDisplayModelNumber(CGDirectDisplayID d) { (void)d; return 0; }
uint32_t CGDisplaySerialNumber(CGDirectDisplayID d) { (void)d; return 0; }
// UIKit owns the integrated display. Translate mode-change notifications to the
// single display exposed by the bridge, retaining callback registrations.
static NSMutableDictionary<NSString *,id> *observers;
static NSString *callbackKey(DisplayCallback callback,void *context) { return [NSString stringWithFormat:@"%p:%p",callback,context]; }
CGError CGDisplayRegisterReconfigurationCallback(DisplayCallback callback,void *context) {
    if(!callback) return kCGErrorIllegalArgument;
    size_t processSlot=AKCallbackProcess((uintptr_t)callback);
    @synchronized(UIScreen.class) {
        if(!observers) observers=[NSMutableDictionary new]; NSString *key=callbackKey(callback,context);
        if(!observers[key]) observers[key]=[NSNotificationCenter.defaultCenter addObserverForName:UIScreenModeDidChangeNotification object:UIScreen.mainScreen queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; if (AKEnterProcessCallback(processSlot)) { callback(1,1<<4,context); AKLeaveProcessCallback(processSlot); } }];
    }
    return kCGErrorSuccess;
}
CGError CGDisplayRemoveReconfigurationCallback(DisplayCallback callback,void *context) {
    @synchronized(UIScreen.class) { NSString *key=callbackKey(callback,context); id observer=observers[key]; if(observer) [NSNotificationCenter.defaultCenter removeObserver:observer]; [observers removeObjectForKey:key]; }
    return kCGErrorSuccess;
}
