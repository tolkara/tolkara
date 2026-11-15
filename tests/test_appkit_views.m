// The AppKit adapter's views and windows as a guest's own subclasses use them,
// run in the simulator (tools/test_translation_sim.sh): no scene is connected,
// so windows are never put on screen here.
#import "AppKit.h"
#import "TouchControls.h"
#import "Drawing.h"
#include <assert.h>
extern void AKGuestProcessDidExit(size_t slot);
extern void AKSetWindowProcess(NSWindow *window,size_t slot);

// Exercise the ordering model without requiring a UIKit scene.
@interface NSWindow (OrderingTest)
- (void)ak_order:(NSInteger)mode relativeTo:(NSInteger)number;
@end

// Draws by updating its layer, as Wine's Mac driver does.
@interface LayerView : NSView
@property int updates;
@property int notifications;
- (void)fixtureNotification:(NSNotification *)note;
@end
@implementation LayerView
- (void)fixtureNotification:(NSNotification *)note { (void)note; self.notifications++; }
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
- (void)quickKeyDown:(UIButton *)button;
- (void)quickKeyUp:(UIButton *)button;
+ (CGRect)gameFrameIn:(CGRect)bounds strip:(CGRect)strip;
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
    // A transparent desktop popup must not acquire an opaque black UIKit
    // backing. Exercise both properties against the actual host surfaces.
    NSWindow *popup=[[NSWindow alloc] initWithContentRect:CGRectMake(0,0,80,100) styleMask:0 backing:0 defer:NO];
    UIView *popupHost=[UIView new];
    UIWindow *popupUI=[UIWindow new];
    [popup setValue:popupHost forKey:@"host"];
    [popup setValue:popupUI forKey:@"uiWindow"];
    popup.backgroundColor=NSColor.clearColor;
    popup.opaque=NO;
    assert(!popupHost.opaque && !popupUI.opaque);
    assert(CGColorGetAlpha(popupHost.backgroundColor.CGColor)==0);
    assert(CGColorGetAlpha(popupUI.backgroundColor.CGColor)==0);
    popup.backgroundColor=NSColor.whiteColor;
    popup.opaque=YES;
    assert(popupHost.opaque && popupUI.opaque);
    assert(CGColorGetAlpha(popupHost.backgroundColor.CGColor)==1);

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
    // Only the four buttons (Jump, stick, trackpad, keyboard) take touches;
    // the gaps between them are the game's.
    controls.frame = CGRectMake(0, 0, 200, 44); [controls layoutIfNeeded];
    for (CGFloat x = 20; x < 200; x += 52) assert([controls pointInside:CGPointMake(x, 20) withEvent:nil]);
    for (CGFloat x = 48; x < 200; x += 52) assert(![controls pointInside:CGPointMake(x, 20) withEvent:nil]);
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
    // Like a mouse's, touch motion stays inside Wine's confinement rect.
    window.mouseConfinementRect = CGRectMake(10, 20, 100, 50);
    [host touchMoveBy:CGPointMake(-500, 0)];
    move = next_input();
    assert(move.deltaX == -500 && move.locationInWindow.x == 10 && move.locationInWindow.y >= 21 && move.locationInWindow.y <= 70);
    window.mouseConfinementRect = CGRectZero;
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
    // A touch drag with the right button held reaches the game as a mouse's
    // would, step by step as it happens: as drags before the game captures
    // the pointer and as captured motion after. Nothing is held back.
    [host touchButton:1 pressed:YES];
    assert(next_input().type == NSEventTypeRightMouseDown);
    [host touchMoveBy:CGPointMake(12, -4)];
    move = next_input();
    assert(move.type == NSEventTypeRightMouseDragged && move.deltaX == 12 && move.deltaY == -4);
    [host touchMoveBy:CGPointMake(6, 0)];
    move = next_input();
    assert(move.type == NSEventTypeRightMouseDragged && move.deltaX == 6 && move.deltaY == 0);
    AKMouseSetCaptured(true);
    assert(![NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:NO]);
    [host touchMoveBy:CGPointMake(3, 0)];
    move = next_input();
    assert(move.type == NSEventTypeRightMouseDragged && move.deltaX == 3);
    [host touchButton:1 pressed:NO];
    assert(next_input().type == NSEventTypeRightMouseUp);
    AKMouseSetCaptured(false);
    // With the Duo's strip the game gets the space between the two columns.
    Class hostClass = NSClassFromString(@"AKHostView");
    assert(CGRectEqualToRect([hostClass gameFrameIn:CGRectMake(0, 0, 951, 669) strip:CGRectMake(867, 132, 84, 537)], CGRectMake(84, 0, 783, 669)));
    assert(CGRectEqualToRect([hostClass gameFrameIn:CGRectMake(0, 0, 951, 669) strip:CGRectMake(0, 132, 84, 537)], CGRectMake(84, 0, 783, 669)));
    assert(CGRectEqualToRect([hostClass gameFrameIn:CGRectMake(0, 0, 951, 669) strip:CGRectNull], CGRectMake(0, 0, 951, 669)));
    // The movement stick needs trackpad mode, and turning that off ends it.
    controls.trackpadEnabled = NO;
    controls.stickEnabled = YES;
    assert(controls.trackpadEnabled && hostView.multipleTouchEnabled);
    // The stick holds W, A, S and D down as the host's key events, with
    // diagonals as two keys and every key released when the finger lifts.
    [hostView addSubview:controls];
    [controls stickPhase:UITouchPhaseBegan at:CGPointMake(50, 50)];
    [controls stickPhase:UITouchPhaseMoved at:CGPointMake(50, 10)];
    NSEvent *stickKey = next_input();
    assert(stickKey.type == NSEventTypeKeyDown && stickKey.keyCode == 13 && [stickKey.characters isEqual:@"w"] && stickKey.window == window);
    [controls stickPhase:UITouchPhaseMoved at:CGPointMake(20, 20)];
    stickKey = next_input();
    assert(stickKey.type == NSEventTypeKeyDown && stickKey.keyCode == 0 && [stickKey.charactersIgnoringModifiers isEqual:@"a"]);
    [controls stickPhase:UITouchPhaseMoved at:CGPointMake(20, 80)];
    NSEvent *upW = next_input(), *downS = next_input();
    assert(upW.type == NSEventTypeKeyUp && upW.keyCode == 13 && downS.type == NSEventTypeKeyDown && downS.keyCode == 1);
    UIView *stickBase = [controls valueForKey:@"_stickBase"];
    assert(stickBase.superview == hostView && !stickBase.hidden && !stickBase.userInteractionEnabled);
    // Cancelling (a rotation, switching apps) releases the held keys and the drawn stick.
    [controls cancelTouches];
    NSEvent *upA = next_input(), *upS = next_input();
    assert(upA.type == NSEventTypeKeyUp && upS.type == NSEventTypeKeyUp && upA.keyCode + upS.keyCode == 1);
    assert(stickBase.hidden);
    [controls stickPhase:UITouchPhaseBegan at:CGPointMake(50, 50)];
    [controls stickPhase:UITouchPhaseMoved at:CGPointMake(90, 50)];
    assert(next_input().keyCode == 2);
    [controls stickPhase:UITouchPhaseEnded at:CGPointMake(90, 50)];
    stickKey = next_input();
    assert(stickKey.type == NSEventTypeKeyUp && stickKey.keyCode == 2 && stickBase.hidden);
    // The right half's tap is a left click where the pointer is, not where the finger is.
    [host touchMoveBy:CGPointMake(-10000, 10000)];
    assert(next_input().type == NSEventTypeMouseMoved);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    [controls padFingers:1 at:CGPointMake(180, 90) time:now];
    [controls padFingers:0 at:CGPointZero time:now + 0.05];
    // A tap's release follows its press after a click's length, not at once.
    NSEvent *tapDown = next_input();
    assert(![NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:NO]);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    NSEvent *tapUp = next_input();
    assert(tapDown.type == NSEventTypeLeftMouseDown && tapUp.type == NSEventTypeLeftMouseUp);
    assert(CGPointEqualToPoint(tapDown.locationInWindow, CGPointMake(0, 1)) && CGPointEqualToPoint(tapUp.locationInWindow, CGPointMake(0, 1)));
    // The side strip: a column in it and one mirroring it at the other edge.
    // On the right Escape, Tab, keys 1 to 5 and Jump; on the left keyboard,
    // stick, trackpad, Shift and keys 6 to 0. Shrunk, then hidden from the bottom
    // when they do not fit; a key button holds its key while touched.
    // (UIControl actions need a UIApplication, so the handlers are called directly.)
    assert(!controls.vertical && CGRectIsNull(controls.sideStrip));
    NSArray<UIButton *> *quick = [controls valueForKey:@"_quickButtons"];
    UIButton *jump = [controls valueForKey:@"_jumpButton"], *escape = [controls valueForKey:@"_escapeButton"], *tab = [controls valueForKey:@"_tabButton"];
    UIButton *keyboardButton = [controls valueForKey:@"_keyboardButton"];
    assert(quick.count == 10 && quick[0].hidden && quick[9].hidden && escape.hidden && tab.hidden && !jump.hidden);
    [controls removeFromSuperview];   // free of the host's row constraints
    controls.translatesAutoresizingMaskIntoConstraints = YES;
    controls.frame = CGRectMake(0, 0, 400, 300);
    controls.sideStrip = CGRectMake(356, 0, 44, 300);
    [controls layoutIfNeeded];
    assert(controls.vertical);
    // 300 points: eight buttons a column shrink to 34 on a 40-point pitch, and seven fit.
    assert(CGRectEqualToRect(escape.frame, CGRectMake(361, 0, 34, 34)) && tab.frame.origin.y == 40);
    assert(quick[0].frame.origin.y == 80 && quick[1].frame.origin.y == 120 && quick[4].frame.origin.y == 240 && CGRectGetMidX(quick[4].frame) == 378);
    assert(jump.hidden && jump.frame.origin.y == 280 && CGRectGetMidX(jump.frame) == 378);
    assert(CGRectGetMidX(keyboardButton.frame) == 22 && keyboardButton.frame.origin.y == 0);
    UIButton *shift = [controls valueForKey:@"_shiftButton"];
    assert(!shift.hidden && CGRectGetMidX(shift.frame) == 22 && shift.frame.origin.y == 120);
    assert(CGRectGetMidX(quick[5].frame) == 22 && quick[5].frame.origin.y == 160 && !quick[7].hidden && quick[8].hidden);
    // Shift is held while touched: the key's press and release, once each,
    // with the modifier on what is sent meanwhile.
    [(id)controls quickKeyDown:shift];
    [(id)controls quickKeyDown:shift];
    NSEvent *shiftKey = next_input();
    assert(shiftKey.type == NSEventTypeFlagsChanged && shiftKey.keyCode == 56 && (shiftKey.modifierFlags & NSEventModifierFlagShift));
    [(id)controls quickKeyDown:quick[5]];
    shiftKey = next_input();
    assert(shiftKey.type == NSEventTypeKeyDown && (shiftKey.modifierFlags & NSEventModifierFlagShift));
    [(id)controls quickKeyUp:quick[5]];
    (void)next_input();
    [(id)controls quickKeyUp:shift];
    shiftKey = next_input();
    assert(shiftKey.type == NSEventTypeFlagsChanged && !(shiftKey.modifierFlags & NSEventModifierFlagShift));
    assert([controls pointInside:CGPointMake(378, 130) withEvent:nil] && ![controls pointInside:CGPointMake(378, 157) withEvent:nil]);
    assert(![controls pointInside:CGPointMake(378, 290) withEvent:nil] && ![controls pointInside:CGPointMake(200, 150) withEvent:nil]);
    assert([controls pointInside:CGPointMake(22, 20) withEvent:nil]);
    [(id)controls quickKeyDown:quick[1]];
    [(id)controls quickKeyDown:quick[1]];
    NSEvent *quickKey = next_input();
    assert(quickKey.type == NSEventTypeKeyDown && quickKey.keyCode == 19 && [quickKey.characters isEqual:@"2"]);
    [(id)controls quickKeyUp:quick[1]];
    quickKey = next_input();
    assert(quickKey.type == NSEventTypeKeyUp && quickKey.keyCode == 19);
    // Escape and Tab (target), held while touched.
    for (UIButton *button in @[escape, tab]) {
        [(id)controls quickKeyDown:button];
        quickKey = next_input();
        assert(quickKey.type == NSEventTypeKeyDown && quickKey.keyCode == (button == escape ? 53 : 48));
        assert([quickKey.characters isEqual:button == escape ? @"\x1b" : @"\t"]);
        [(id)controls quickKeyUp:button];
        assert(next_input().type == NSEventTypeKeyUp);
    }
    // The toggles are not key buttons.
    [(id)controls quickKeyDown:keyboardButton];
    assert(![NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:NO]);
    // Room for all at full size (nine on the left): Jump at the bottom of the right column, holding Space.
    controls.frame = CGRectMake(0, 0, 400, 480); [controls layoutIfNeeded];
    assert(!jump.hidden && CGRectEqualToRect(jump.frame, CGRectMake(356, 364, 44, 44)) && !quick[9].hidden);
    [(id)controls quickKeyDown:jump];
    quickKey = next_input();
    assert(quickKey.type == NSEventTypeKeyDown && quickKey.keyCode == 49 && [quickKey.characters isEqual:@" "]);
    [(id)controls quickKeyUp:jump];
    assert(next_input().type == NSEventTypeKeyUp);
    [(id)controls quickKeyDown:quick[9]];
    quickKey = next_input();
    assert(quickKey.keyCode == 29 && [quickKey.charactersIgnoringModifiers isEqual:@"0"]);
    [(id)controls quickKeyUp:quick[9]];
    assert(next_input().type == NSEventTypeKeyUp);
    // With the strip on the left the columns keep their sides.
    controls.sideStrip = CGRectMake(0, 0, 44, 480); [controls layoutIfNeeded];
    assert(CGRectGetMidX(jump.frame) == 378 && CGRectGetMidX(keyboardButton.frame) == 22);
    [(id)controls quickKeyDown:quick[0]];
    assert(next_input().keyCode == 18);
    // Leaving the column releases a held key exactly once.
    controls.sideStrip = CGRectNull; [controls layoutIfNeeded];
    quickKey = next_input();
    assert(quickKey.type == NSEventTypeKeyUp && quickKey.keyCode == 18 && quick[0].hidden && quick[5].hidden && escape.hidden);
    assert(!jump.hidden && CGRectEqualToRect(jump.frame, CGRectMake(0, 0, 44, 44)));
    [(id)controls quickKeyUp:quick[0]];
    assert(![NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:NO]);
    controls.trackpadEnabled = NO;
    assert(!controls.stickEnabled && !hostView.multipleTouchEnabled);

    // Windows are numbered once each; with none on screen, none is found.
    assert(window.windowNumber > 0 && other.windowNumber != window.windowNumber && panel.windowNumber != other.windowNumber);
    assert([NSWindow windowNumbersWithOptions:0].count == 0 && [NSWindow windowNumberAtPoint:CGPointMake(1, 1) belowWindowWithWindowNumber:0] == 0);
    [window ak_order:1 relativeTo:0];
    [other ak_order:1 relativeTo:window.windowNumber];
    [panel ak_order:-1 relativeTo:other.windowNumber];
    assert(([NSApp.windows isEqualToArray:@[window,panel,other]]));
    [window ak_order:1 relativeTo:other.windowNumber];
    assert(([NSApp.windows isEqualToArray:@[panel,other,window]]));
    [window ak_order:-1 relativeTo:0];
    assert(([NSApp.windows isEqualToArray:@[window,panel,other]]));
    [window ak_order:1 relativeTo:window.windowNumber];
    assert(([NSApp.windows isEqualToArray:@[window,panel,other]]));
    assert(NSApp.keyWindow==nil && NSApp.mainWindow==nil);
    [window close]; [panel close]; [other close];
    assert(NSApp.windows.count==0);
    // Retiring a game removes only its windows, leaving Steam's ordering intact.
    NSWindow *steam=[[NSWindow alloc] initWithContentRect:CGRectZero styleMask:0 backing:0 defer:NO];
    NSWindow *game=[[NSWindow alloc] initWithContentRect:CGRectZero styleMask:0 backing:0 defer:NO];
    AKSetWindowProcess(steam,1); AKSetWindowProcess(game,3);
    [steam ak_order:1 relativeTo:0]; [game ak_order:1 relativeTo:0];
    LayerView *retiredView=[[LayerView alloc] initWithFrame:CGRectZero];
    game.contentView=retiredView;
    LayerView *retiredChild=[LayerView new], *survivingObserver=[LayerView new];
    [retiredView addSubview:retiredChild];
    for (LayerView *view in @[retiredView,retiredChild,survivingObserver])
        [NSNotificationCenter.defaultCenter addObserver:view selector:@selector(fixtureNotification:) name:@"fixture-screen-change" object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:@"fixture-screen-change" object:nil];
    assert(retiredView.notifications==1 && retiredChild.notifications==1 && survivingObserver.notifications==1);
    retiredView.needsDisplay=YES; // work queued before retirement
    FixtureKeyResponder *retiredResponder=[FixtureKeyResponder new];
    assert([game makeFirstResponder:retiredResponder]);
    NSEvent *lateKey=[NSEvent new]; lateKey.type=NSEventTypeKeyDown; lateKey.window=game;
    [app sendEvent:lateKey]; assert(retiredResponder.downs==1);
    extern bool AKProcessRetirementComplete(size_t);
    AKConfigureProcessCallbacks(4,NULL);
    assert(!AKProcessRetirementComplete(3));
    assert(AKEnterProcessCallback(3));
    AKGuestProcessDidExit(3);
    assert(!AKProcessRetirementComplete(3));
    AKLeaveProcessCallback(3);
    assert(AKProcessRetirementComplete(3));
    [NSNotificationCenter.defaultCenter postNotificationName:@"fixture-screen-change" object:nil];
    assert(retiredView.notifications==1 && retiredChild.notifications==1 && survivingObserver.notifications==2);
    [NSNotificationCenter.defaultCenter removeObserver:survivingObserver];
    [app sendEvent:lateKey]; [game sendEvent:lateKey];
    assert(retiredResponder.downs==1);
    CGRect retiredFrame=retiredView.frame;
    [game ak_hostBoundsChanged:CGRectMake(0,0,321,123)];
    assert(CGRectEqualToRect(retiredView.frame,retiredFrame));
    [retiredView displayIfNeeded];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    assert(retiredView.updates==0);
    // The surviving process still receives events.
    assert([steam makeFirstResponder:retiredResponder]); lateKey.window=steam;
    [app sendEvent:lateKey]; assert(retiredResponder.downs==2);
    assert(([NSApp.windows isEqualToArray:@[steam]]));
    [game orderFront:nil];
    assert(([NSApp.windows isEqualToArray:@[steam]]));
    AKGuestProcessDidExit(3); // duplicate exit is harmless
    assert(NSApp.windows.count==1);
    [steam close];
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
