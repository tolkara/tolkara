// The Core Graphics adapter's one display, as Wine's Mac driver queries and
// captures it; run in the simulator (tools/test_translation_sim.sh).
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <assert.h>
#import "AKSupport.h"
typedef uint32_t CGDirectDisplayID;
typedef CFDictionaryRef CGDisplayModeRef;
extern CGError CGGetOnlineDisplayList(uint32_t, CGDirectDisplayID *, uint32_t *);
extern CGSize CGDisplayScreenSize(CGDirectDisplayID);
extern uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID);
extern CGDirectDisplayID CGOpenGLDisplayMaskToDisplayID(uint32_t);
extern CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID);
extern id<MTLDevice> CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID);
extern CGError CGCaptureAllDisplays(void), CGReleaseAllDisplays(void);
extern int32_t CGShieldingWindowLevel(void);
extern CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID), CGDisplayModeRetain(CGDisplayModeRef);
extern void CGDisplayModeRelease(CGDisplayModeRef);
extern bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef);
extern CGError CGDisplaySetDisplayMode(CGDirectDisplayID, CGDisplayModeRef, CFDictionaryRef);
typedef void (*FixtureDisplayCallback)(uint32_t,uint32_t,void *);
extern CGError CGDisplayRegisterReconfigurationCallback(FixtureDisplayCallback,void *);
extern CGError CGDisplayRemoveReconfigurationCallback(FixtureDisplayCallback,void *);
static unsigned retiredCalls, liveCalls;
static void retiredCallback(uint32_t display,uint32_t flags,void *context) { (void)display;(void)flags;(void)context; retiredCalls++; }
static void liveCallback(uint32_t display,uint32_t flags,void *context) { (void)display;(void)flags;(void)context; liveCalls++; }
static size_t callbackOwner(uintptr_t address) { return address==(uintptr_t)retiredCallback ? 1 : 2; }
int main(void) { @autoreleasepool {
    CGDirectDisplayID displays[2]={0}; uint32_t count=0;
    assert(CGGetOnlineDisplayList(2,displays,&count)==kCGErrorSuccess && count==1 && displays[0]==1);
    assert(CGGetOnlineDisplayList(0,NULL,&count)==kCGErrorSuccess && count==1);
    assert(CGGetOnlineDisplayList(1,NULL,&count)==kCGErrorIllegalArgument);
    // 132 points an inch, in millimetres.
    CGSize points=UIScreen.mainScreen.bounds.size, size=CGDisplayScreenSize(1);
    assert(fabs(size.width-points.width*25.4/132)<0.01 && fabs(size.height-points.height*25.4/132)<0.01);
    assert(CGSizeEqualToSize(CGDisplayScreenSize(2),CGSizeZero));
    assert(CGDisplayIDToOpenGLDisplayMask(1)==1 && CGOpenGLDisplayMaskToDisplayID(1)==1 && !CGOpenGLDisplayMaskToDisplayID(2) && !CGDisplayIDToOpenGLDisplayMask(2));
    assert(!CGDisplayMirrorsDisplay(1) && CGDirectDisplayCopyCurrentMetalDevice(1) && !CGDirectDisplayCopyCurrentMetalDevice(2));
    assert(CGCaptureAllDisplays()==kCGErrorSuccess && CGReleaseAllDisplays()==kCGErrorSuccess && CGShieldingWindowLevel()>0);
    // The backing scale is a whole number: Display Zoom's "More Space" on an
    // iPad Pro 12.9" has 1590 points across 2732 pixels, and 1590 * 1.718 is
    // not a pixel count a guest can use.
    assert(AKBackingScale(2, 2) == 2 && AKBackingScale(3, 3) == 3 && AKBackingScale(1, 1) == 1);
    assert(AKBackingScale(2, 2048.0 / 1192.0) == 2 && AKBackingScale(3, 2.608) == 3 && AKBackingScale(2, 2.34) == 2);
    assert(AKBackingScale(0, 0) == 1);
    extern size_t CGDisplayPixelsWide(CGDirectDisplayID), CGDisplayPixelsHigh(CGDirectDisplayID);
    double whole = AKBackingScale(UIScreen.mainScreen.scale, UIScreen.mainScreen.nativeScale);
    assert(CGDisplayPixelsWide(1) == (size_t)lround(points.width * whole) && CGDisplayPixelsHigh(1) == (size_t)lround(points.height * whole));
    // The screen's own mode is the only one to set.
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(1); assert(mode && CGDisplayModeIsUsableForDesktopGUI(mode));
    assert(CGDisplayModeRetain(mode)==mode); CGDisplayModeRelease(mode);
    assert(CGDisplaySetDisplayMode(1,mode,NULL)==kCGErrorSuccess);
    NSMutableDictionary *other=[(__bridge NSDictionary *)mode mutableCopy]; other[@"width"]=@800;
    assert(CGDisplaySetDisplayMode(1,(__bridge CGDisplayModeRef)other,NULL)==kCGErrorIllegalArgument);
    assert(CGDisplaySetDisplayMode(2,mode,NULL)==kCGErrorIllegalArgument && CGDisplaySetDisplayMode(1,NULL,NULL)==kCGErrorIllegalArgument);
    CGDisplayModeRelease(mode);
    AKConfigureProcessCallbacks(3,callbackOwner);
    assert(!CGDisplayRegisterReconfigurationCallback(retiredCallback,NULL));
    assert(!CGDisplayRegisterReconfigurationCallback(liveCallback,NULL));
    [NSNotificationCenter.defaultCenter postNotificationName:UIScreenModeDidChangeNotification object:UIScreen.mainScreen];
    assert(retiredCalls==1 && liveCalls==1);
    AKRetireProcessCallbacks(1);
    [NSNotificationCenter.defaultCenter postNotificationName:UIScreenModeDidChangeNotification object:UIScreen.mainScreen];
    assert(retiredCalls==1 && liveCalls==2 && AKProcessCallbacksDrained(1));
    assert(!CGDisplayRemoveReconfigurationCallback(retiredCallback,NULL));
    assert(!CGDisplayRemoveReconfigurationCallback(liveCallback,NULL));
    puts("online displays, physical size, OpenGL masks, capture and display modes: PASS");
} }
