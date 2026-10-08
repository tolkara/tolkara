// The AppKit adapter's views and windows as a guest's own subclasses use them,
// run in the simulator (tools/test_translation_sim.sh): no scene is connected,
// so windows are never put on screen here.
#import "AppKit.h"
#import "TouchControls.h"
#include <assert.h>

// Draws by updating its layer, as Wine's Mac driver does.
@interface LayerView : NSView
@property int updates;
@end
@implementation LayerView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.updates++; self.layer.position = CGPointMake(5, 6); }
// One pixel a point, whatever the screen's scale.
- (BOOL)layer:(CALayer *)layer shouldInheritContentsScale:(CGFloat)scale fromWindow:(NSWindow *)window { return NO; }
@end

// Shows itself with orderFront:, as Wine's window class does.
@interface OrderingWindow : NSWindow
@property int depth, deepest;
@end
@implementation OrderingWindow
- (void)makeKeyAndOrderFront:(id)sender {
    self.deepest = MAX(self.deepest, ++self.depth);
    if (self.depth == 1) { [self orderFront:sender]; [self makeKeyWindow]; [self setIsVisible:YES]; }
    self.depth--;
}
@end

// Original keyboard fixture exercises UIKit-to-AppKit translation without
// synthesizing input for an imported application.
@interface FixtureKey : NSObject
@property UIKeyboardHIDUsage keyCode;
@property UIKeyModifierFlags modifierFlags;
@property(copy) NSString *characters, *charactersIgnoringModifiers;
@end
@implementation FixtureKey
@end
@interface FixturePress : NSObject
@property FixtureKey *key;
@property NSTimeInterval timestamp;
@end
@implementation FixturePress
@end
@interface NSObject (FixtureHostInput)
- (void)postKeys:(NSSet *)presses down:(BOOL)down;
- (void)postRelativeMouseX:(CGFloat)dx y:(CGFloat)dy;
- (void)anchorChanged:(NSNotification *)notification;
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
@end
@interface FixtureKeyResponder : NSResponder
@property unsigned downs, ups;
@property unsigned short lastCode;
@end
@implementation FixtureKeyResponder
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { self.downs++;self.lastCode=event.keyCode; }
- (void)keyUp:(NSEvent *)event { self.ups++;self.lastCode=event.keyCode; }
@end

static void run_main_queue(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false); }
static NSEvent *next_input(void) {
    NSEvent *event = [NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
    assert(event);
    return event;
}

int main(void) { @autoreleasepool {
    // Marking for display coalesces into one updateLayer on the main queue;
    // a view that does not want updateLayer gets none.
    LayerView *view = [[LayerView alloc] initWithFrame:CGRectMake(0, 0, 100, 50)];
    view.wantsLayer = YES;
    [view setNeedsDisplayInRect:CGRectMake(0, 0, 1, 1)]; view.needsDisplay = YES; view.needsDisplay = YES;
    assert(view.needsDisplay && view.updates == 0);
    run_main_queue();
    assert(!view.needsDisplay && view.updates == 1);
    view.needsDisplay = YES; view.needsDisplay = NO; run_main_queue();
    assert(view.updates == 1);
    [view display]; assert(view.updates == 2);
    NSView *still = [[NSView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    still.needsDisplay = YES; run_main_queue(); assert(!still.needsDisplay && !still.wantsUpdateLayer);

    // Frame and content coincide; panels are windows.
    CGRect rect = CGRectMake(1, 2, 3, 4);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:CGRectMake(0, 0, 100, 50) styleMask:0 backing:2 defer:NO];
    assert(CGRectEqualToRect([window frameRectForContentRect:rect], rect) && CGRectEqualToRect([window contentRectForFrameRect:rect], rect));
    assert(CGRectEqualToRect([NSWindow frameRectForContentRect:rect styleMask:15], rect) && CGRectEqualToRect([NSPanel contentRectForFrameRect:rect styleMask:15], rect));
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:rect styleMask:0 backing:2 defer:NO];
    panel.floatingPanel = YES; assert([panel isKindOfClass:NSWindow.class] && panel.isFloatingPanel);
    NSRect screenRect=CGRectMake(11,22,30,40);
    assert(CGRectEqualToRect([panel convertRectFromScreen:screenRect],CGRectMake(10,20,30,40)));
    assert(CGRectEqualToRect([panel convertRectToScreen:[panel convertRectFromScreen:screenRect]],screenRect));

    // Tracking areas are kept once each, for their owner.
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:rect options:0x20 owner:view userInfo:@{@"k": @1}];
    assert(area.owner == view && area.options == 0x20 && CGRectEqualToRect(area.rect, rect) && [area.userInfo[@"k"] isEqual:@1]);
    [view addTrackingArea:area]; [view addTrackingArea:area]; [view addTrackingArea:nil];
    assert(view.trackingAreas.count == 1);
    [view removeTrackingArea:area]; assert(view.trackingAreas.count == 0);

    // A view's layer is placed by its origin, as AppKit's are: Wine's Mac driver sets the position.
    NSView *plain = [[NSView alloc] initWithFrame:CGRectMake(10, 20, 30, 40)];
    plain.wantsLayer = YES;
    assert(CGPointEqualToPoint(plain.layer.anchorPoint, CGPointZero));
    assert(CGPointEqualToPoint(plain.layer.position, CGPointMake(10, 20)) && CGRectEqualToRect(plain.layer.frame, CGRectMake(10, 20, 30, 40)));
    assert(CGRectEqualToRect(view.layer.frame, CGRectMake(5, 6, 100, 50)));

    // Wine inserts its Metal view below existing content, then keeps it sized
    // to that content through AppKit's width/height autoresizing mask.
    NSView *parent=[[NSView alloc] initWithFrame:CGRectMake(0,0,100,50)];
    NSView *front=[[NSView alloc] initWithFrame:parent.bounds];
    NSView *back=[[NSView alloc] initWithFrame:parent.bounds];
    [parent addSubview:front];
    [parent addSubview:back positioned:-1 relativeTo:nil];
    assert(parent.subviews[0]==back && parent.subviews[1]==front);
    assert(back.superview==parent && back.layer.superlayer==parent.layer);
    assert(parent.layer.sublayers[0]==back.layer);
    back.autoresizingMask=(1u<<1)|(1u<<4);
    parent.frame=CGRectMake(0,0,200,100);
    assert(CGSizeEqualToSize(back.frame.size,CGSizeMake(200,100)));
    assert(CGSizeEqualToSize(front.frame.size,CGSizeMake(100,50)));
    back.hidden=YES;assert(back.isHidden && back.layer.hidden);
    back.hidden=NO;assert(!back.layer.hidden);
    [parent addSubview:back positioned:1 relativeTo:front];
    assert(parent.subviews.lastObject==back && parent.layer.sublayers.lastObject==back.layer);
    parent.autoresizesSubviews=NO;parent.frame=CGRectMake(0,0,300,150);
    assert(CGSizeEqualToSize(back.frame.size,CGSizeMake(200,100)));
    [back addSubview:parent];assert(parent.superview==nil);

    // The window's scale reaches a content view's layer unless the view keeps its own.
    window.contentView = view; view.layer.contentsScale = 1;
    [window ak_hostBoundsChanged:CGRectMake(0, 0, 200, 100)];
    assert(view.layer.contentsScale == 1 && CGSizeEqualToSize(view.frame.size, CGSizeMake(200, 100)));
    NSWindow *other = [[NSWindow alloc] initWithContentRect:CGRectMake(0, 0, 100, 50) styleMask:0 backing:2 defer:NO];
    other.contentView = plain; plain.layer.contentsScale = 1;
    [other ak_hostBoundsChanged:CGRectMake(0, 0, 200, 100)];
    assert(other.backingScaleFactor > 1 && plain.layer.contentsScale == other.backingScaleFactor);

    // Showing a window never calls back into a subclass's makeKeyAndOrderFront:.
    OrderingWindow *ordering = [[OrderingWindow alloc] initWithContentRect:rect styleMask:0 backing:2 defer:NO];
    [ordering makeKeyAndOrderFront:nil];
    assert(ordering.deepest == 1);
    // An event's Quartz location is in global display coordinates, top-left
    // origin, which is where Wine's Mac driver takes clicks from.
    NSEvent *click = [NSEvent new];
    click.type = NSEventTypeLeftMouseDown; click.window = window; click.locationInWindow = CGPointMake(10, 20);
    click.clickCount = 2; click.buttonNumber = 1; click.timestamp = 1.5; click.modifierFlags = NSEventModifierFlagShift;
    AKQuartzEvent *quartz = (__bridge AKQuartzEvent *)click.CGEvent;
    CGFloat height = NSScreen.screens.firstObject.frame.size.height;
    assert(quartz && (__bridge AKQuartzEvent *)click.CGEvent == quartz && quartz.type == 1);
    assert(quartz.location.x == 10 && quartz.location.y == height - 20 && quartz.timestamp == 1500000000);
    assert([quartz integerValueField:1] == 2 && [quartz integerValueField:3] == 1 && quartz.flags == NSEventModifierFlagShift);
    NSEvent *scroll = [NSEvent new]; scroll.type = NSEventTypeScrollWheel; scroll.deltaY = 2.6;
    AKQuartzEvent *wheel = (__bridge AKQuartzEvent *)scroll.CGEvent;
    assert(wheel.type == 22 && [wheel integerValueField:11] == 3 && [wheel integerValueField:88] == 0);

    FixtureKey *space=[FixtureKey new];space.keyCode=UIKeyboardHIDUsageKeyboardSpacebar;
    space.characters=space.charactersIgnoringModifiers=@" ";
    FixturePress *press=[FixturePress new];press.key=space;
    press.timestamp=NSProcessInfo.processInfo.systemUptime;
    // On-screen controls are optional: with no stored choice an iPad shows
    // none and keeps single-touch input; iPhone shows them.
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:AKTouchControlsDefaultsKey];
    BOOL phone=UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPhone;
    UIView *plainHost=[NSClassFromString(@"AKHostView") new];
    assert(AKTouchControls.enabled==phone && !![plainHost valueForKey:@"_touchControls"]==phone);
    if(!phone) assert(!plainHost.multipleTouchEnabled);
    [defaults setBool:NO forKey:AKTouchControlsDefaultsKey];
    plainHost=[NSClassFromString(@"AKHostView") new];
    assert(![plainHost valueForKey:@"_touchControls"] && !plainHost.multipleTouchEnabled);
    [defaults setBool:YES forKey:AKTouchControlsDefaultsKey];
    id host=[NSClassFromString(@"AKHostView") new];
    [host setValue:window forKey:@"nsWindow"];
    FixtureKeyResponder *responder=[FixtureKeyResponder new];
    assert([window makeFirstResponder:responder]);
    NSApplication *app=[NSApplication sharedApplication];
    [host postKeys:[NSSet setWithObject:press] down:YES];
    [host postKeys:[NSSet setWithObject:press] down:NO];
    for(unsigned i=0;i<2;i++) {
        NSEvent *key=[app nextEventMatchingMask:(1ULL<<NSEventTypeKeyDown)|(1ULL<<NSEventTypeKeyUp)
                                    untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
        assert(key && key.type==(i?NSEventTypeKeyUp:NSEventTypeKeyDown) && key.keyCode==49);
        assert([key.characters isEqualToString:@" "] && key.timestamp==press.timestamp && key.window==window);
        [app sendEvent:key];
    }
    assert(responder.downs==1 && responder.ups==1 && responder.lastCode==49);

    // Our input fixture: a captured pointer stays at the clip boundary while
    // its raw deltas survive, and recentering updates both position APIs.
    [host setFrame:CGRectMake(0,0,200,100)];
    window.mouseConfinementRect=CGRectMake(10,20,100,50);
    assert(AKMouseIsCaptured() && [NSWindow instancesRespondToSelector:@selector(setMouseConfinementRect:)]);
    AKMouseSetCaptured(false);assert(AKMouseIsCaptured()); // Reassociation cannot release confinement.
    window.ak_mouseLocation=CGPointMake(50,40);
    [host postRelativeMouseX:5 y:-3];
    NSEvent *move=[app nextEventMatchingMask:1ULL<<NSEventTypeMouseMoved untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
    assert(move && CGPointEqualToPoint(move.locationInWindow,CGPointMake(55,37)) && move.deltaX==5 && move.deltaY==3);
    [host postRelativeMouseX:200 y:-100];
    move=[app nextEventMatchingMask:1ULL<<NSEventTypeMouseMoved untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
    assert(move && CGPointEqualToPoint(move.locationInWindow,CGPointMake(109,21)) && move.deltaX==200 && move.deltaY==100);
    [host anchorChanged:[NSNotification notificationWithName:@"AKMouseAnchorChanged" object:nil userInfo:@{@"x":@50,@"y":@(height-40)}]];
    assert(CGPointEqualToPoint(window.mouseLocationOutsideOfEventStream,CGPointMake(50,40)) && CGPointEqualToPoint(NSEvent.mouseLocation,CGPointMake(50,40)));
    [host postRelativeMouseX:-4 y:2];
    move=[app nextEventMatchingMask:1ULL<<NSEventTypeMouseMoved untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
    assert(move && CGPointEqualToPoint(move.locationInWindow,CGPointMake(46,42)) && move.deltaX==-4 && move.deltaY==-2);
    window.mouseConfinementRect=CGRectZero;assert(!AKMouseIsCaptured());
    // Software keys take the same event queue as hardware keys, preserve
    // Unicode and never depend on reading the guest's text/selection.
    AKTouchControls *controls = [host valueForKey:@"_touchControls"];
    assert(controls && controls.hasText && controls.isSecureTextEntry);
    // Only the two buttons take touches; the gap between them is the game's.
    controls.frame = CGRectMake(0, 0, 96, 44); [controls layoutIfNeeded];
    assert([controls pointInside:CGPointMake(20, 20) withEvent:nil] && [controls pointInside:CGPointMake(70, 20) withEvent:nil]);
    assert(![controls pointInside:CGPointMake(48, 20) withEvent:nil]);
    [controls insertText:@"@ñ🙂"];
    NSArray<NSString *> *typed = @[@"@", @"ñ", @"🙂"];
    for (unsigned i = 0; i < 3; i++) for (unsigned up = 0; up < 2; up++) {
        NSEvent *event = next_input();
        assert(event.type == (up ? NSEventTypeKeyUp : NSEventTypeKeyDown));
        assert(event.window == window && [event.characters isEqual:typed[i]]);
        assert(event.keyCode == (i ? 0xFF : 19));
    }
    [controls deleteBackward];
    assert(next_input().keyCode == 51 && next_input().type == NSEventTypeKeyUp);
    [controls insertText:@"\n"];
    assert(next_input().keyCode == 36 && next_input().type == NSEventTypeKeyUp);

    UIView *hostView = host;
    hostView.frame = CGRectMake(0, 0, 200, 100);
    controls.trackpadEnabled = YES;
    [host touchMoveBy:CGPointMake(10, -5)];
    move = next_input();
    assert(move.type == NSEventTypeMouseMoved && move.locationInWindow.x == 110 && move.locationInWindow.y == 55);
    assert(move.deltaX == 10 && move.deltaY == -5);
    [host touchMoveBy:CGPointMake(10000, -10000)];
    move = next_input();
    assert(move.locationInWindow.x == 199 && move.locationInWindow.y == 100);
    // Camera deltas continue at an edge with no GCMouse attached.
    AKMouseSetCaptured(true);
    [host touchMoveBy:CGPointMake(40, 20)];
    move = next_input();
    assert(move.deltaX == 40 && move.deltaY == 20 && move.locationInWindow.x == 199);
    AKMouseSetCaptured(false);
    [host touchScrollBy:CGPointMake(-2, 3)];
    NSEvent *wheelInput = next_input();
    AKQuartzEvent *wheelInputCG = (__bridge AKQuartzEvent *)wheelInput.CGEvent;
    assert(wheelInput.type == NSEventTypeScrollWheel && wheelInput.scrollingDeltaY == 3);
    assert([wheelInputCG integerValueField:11] == 3 && [wheelInputCG integerValueField:12] == -2);
    for (unsigned button = 0; button < 3; button++) {
        [host touchButton:button pressed:YES];
        [host touchButton:button pressed:NO];
        NSEvent *down = next_input(), *up = next_input();
        assert(down.type == (button == 2 ? NSEventTypeOtherMouseDown : button == 1 ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown));
        assert(up.type == down.type + 1 && down.buttonNumber == button && up.buttonNumber == button);
        assert([(__bridge AKQuartzEvent *)down.CGEvent integerValueField:3] == button);
    }
    [host touchButton:0 pressed:YES]; [host touchButton:0 pressed:NO];
    assert(next_input().clickCount == 1); (void)next_input();
    [host touchButton:0 pressed:YES]; [host touchButton:0 pressed:NO];
    assert(next_input().clickCount == 2); (void)next_input();
    controls.trackpadEnabled = NO;
    assert(!hostView.multipleTouchEnabled);

    // Windows are numbered once each; with none on screen, none is found.
    assert(window.windowNumber > 0 && other.windowNumber != window.windowNumber && panel.windowNumber != other.windowNumber);
    assert([NSWindow windowNumbersWithOptions:0].count == 0 && [NSWindow windowNumberAtPoint:CGPointMake(1, 1) belowWindowWithWindowNumber:0] == 0);
    // Modifier keys: a key's press and release set and clear it, left and right
    // apart (device bits); the flag stays while either side is held.
    const NSEventModifierFlags LeftOption = 0x20, RightOption = 0x40, LeftCommand = 0x08, LeftShift = 0x02;
    NSEventModifierFlags held = AKModifiersAfterKey(0, 0xE2, YES);
    assert(held == (NSEventModifierFlagOption | LeftOption));
    held = AKModifiersAfterKey(held, 0xE6, YES);
    assert(held == (NSEventModifierFlagOption | LeftOption | RightOption));
    held = AKModifiersAfterKey(held, 0xE2, NO);
    assert(held == (NSEventModifierFlagOption | RightOption));
    held = AKModifiersAfterKey(held, 0xE6, NO);
    assert(held == 0);
    // Whatever the release event reports, the key's own release clears it.
    held = AKModifiersAfterKey(AKModifiersAfterKey(0, 0xE2, YES), 0xE2, NO);
    assert(held == 0 && AKModifiersAfterKey(0, 0x04, YES) == 0);
    // Other events reconcile with UIKit: what it no longer reports is released;
    // what it reports with no key held is the left key; Caps Lock is its own.
    held = AKModifiersAfterKey(AKModifiersAfterKey(0, 0xE2, YES), 0xE3, YES);
    assert(AKModifiersReconciled(held, NSEventModifierFlagCommand) == (NSEventModifierFlagCommand | LeftCommand));
    assert(AKModifiersReconciled(0, NSEventModifierFlagShift | NSEventModifierFlagCapsLock) ==
           (NSEventModifierFlagShift | LeftShift | NSEventModifierFlagCapsLock));
    assert(AKModifiersReconciled(held, 0) == 0);
    assert(AKModifiersReconciled(AKModifiersAfterKey(0, 0xE6, YES), NSEventModifierFlagOption) == (NSEventModifierFlagOption | RightOption));
    puts("display pass, frame rects, panels, tracking areas, layer placement, contents scale, window ordering, Quartz events, window numbers and modifier keys: PASS");
} }
