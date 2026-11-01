// Original UIKit/AppKit fixture for manual touch/keyboard testing. No guest.
#import "AppKit.h"
#import "TouchControls.h"
#include <assert.h>

@interface AKInputFixtureView : NSView
@property CATextLayer *heading, *instructions, *result;
@property NSMutableString *text;
@property NSString *lastAction;
@property NSMutableSet<NSNumber *> *keysDown;
@property unsigned leftDowns, leftUps, rightDowns, rightUps, rightDrags, scrolls;
@property NSInteger lastClickCount;
@end
@implementation AKInputFixtureView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [UIColor colorWithRed:0.06 green:0.10 blue:0.16 alpha:1].CGColor;
        _text = [NSMutableString new];
        _lastAction = @"Ready";
        _keysDown = [NSMutableSet new];
        for (NSString *key in @[@"heading", @"instructions", @"result"]) {
            CATextLayer *label = [CATextLayer new];
            label.contentsScale = UIScreen.mainScreen.scale;
            label.foregroundColor = UIColor.whiteColor.CGColor;
            label.wrapped = YES;
            [self.layer addSublayer:label];
            [self setValue:label forKey:key];
        }
        _heading.fontSize = 24; _instructions.fontSize = 15; _result.fontSize = 18;
        _heading.string = @"Tolkara · Touch input fixture";
        _instructions.string = @"Left half: movement stick (W A S D) • Right half: slide to move the pointer\nTap: left click • Two-finger tap or hold: right click • Double tap and hold: right drag\nTwo fingers: scroll • Three-finger tap: middle click. This is an original test screen.";
        [self setFrame:frame];
    }
    return self;
}
- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    CGFloat width = MAX(100, frame.size.width - 96);
    _heading.frame = CGRectMake(48, 32, width, 32);
    _instructions.frame = CGRectMake(48, 76, width, 78);
    _result.frame = CGRectMake(48, 170, width, 100);
    [self refresh];
}
- (void)refresh {
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSNumber *code in @[@13, @0, @1, @2]) if ([self.keysDown containsObject:code]) [keys addObject:@[@"W", @"A", @"S", @"D"][[@[@13, @0, @1, @2] indexOfObject:code]]];
    self.result.string = [NSString stringWithFormat:@"%@\nKeys held: %@\nText: %@", self.lastAction, [keys componentsJoinedByString:@" "], self.text];
    [CATransaction flush];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    [self.keysDown addObject:@(event.keyCode)];
    if (event.keyCode == 51 && self.text.length) {
        [self.text deleteCharactersInRange:[self.text rangeOfComposedCharacterSequenceAtIndex:self.text.length - 1]];
    } else if (event.keyCode == 53) [self.text setString:@""];
    else if (event.characters.length && event.keyCode != 51) [self.text appendString:event.characters];
    self.lastAction = @"Keyboard input received";
    [self refresh];
}
- (void)keyUp:(NSEvent *)event { [self.keysDown removeObject:@(event.keyCode)]; [self refresh]; }
- (void)mouseMoved:(NSEvent *)event {
    self.lastAction = [NSString stringWithFormat:@"Pointer %.0f, %.0f", event.locationInWindow.x, event.locationInWindow.y];
    [self refresh];
}
- (void)mouseDown:(NSEvent *)event {
    self.leftDowns++; self.lastClickCount = event.clickCount;
    self.lastAction = event.clickCount == 2 ? @"Double click" : @"Left click / hold"; [self refresh];
}
- (void)mouseUp:(NSEvent *)event { (void)event; self.leftUps++; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; self.rightDowns++; self.lastAction = @"Right click / hold"; [self refresh]; }
- (void)rightMouseUp:(NSEvent *)event { (void)event; self.rightUps++; }
- (void)otherMouseDown:(NSEvent *)event { (void)event; self.lastAction = @"Middle click"; [self refresh]; }
- (void)mouseDragged:(NSEvent *)event { (void)event; self.lastAction = @"Left drag"; [self refresh]; }
- (void)rightMouseDragged:(NSEvent *)event { (void)event; self.rightDrags++; self.lastAction = @"Right drag"; [self refresh]; }
- (void)scrollWheel:(NSEvent *)event {
    self.scrolls++;
    self.lastAction = [NSString stringWithFormat:@"Scroll %.0f, %.0f", event.deltaX, event.deltaY];
    [self refresh];
}
@end

@interface AKInputFixtureScene : UIResponder <UIWindowSceneDelegate>
@property NSWindow *guest;
@property NSTimer *pump;
@end
@implementation AKInputFixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    [NSApplication sharedApplication];
    // The controls are optional; this fixture exists to show them.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:AKTouchControlsDefaultsKey];
    self.guest = [[NSWindow alloc] initWithContentRect:((UIWindowScene *)scene).screen.bounds styleMask:0 backing:2 defer:NO];
    self.guest.contentView = [[AKInputFixtureView alloc] initWithFrame:self.guest.frame];
    self.guest.acceptsMouseMovedEvents = YES;
    [self.guest makeFirstResponder:self.guest.contentView];
    [self.guest makeKeyAndOrderFront:nil];
    self.pump = [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
    }];
    BOOL selfTest = [NSProcessInfo.processInfo.arguments containsObject:@"--self-test"];
    if (selfTest || [NSProcessInfo.processInfo.arguments containsObject:@"--show-keyboard"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UIView *host = [self.guest valueForKey:@"_host"];
            AKTouchControls *controls = [host valueForKey:@"_touchControls"];
            CGSize originalSize = host.bounds.size;
            [controls toggleKeyboard];
            if (!selfTest) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [host layoutIfNeeded];
                assert(controls.keyboardVisible && CGSizeEqualToSize(originalSize, host.bounds.size));
                assert(host.keyboardLayoutGuide.layoutFrame.size.height > 100);
                assert(CGRectGetMaxY(controls.frame) <= CGRectGetMinY(host.keyboardLayoutGuide.layoutFrame));
                assert(CGRectGetMinY(controls.frame) >= 0);
                [controls insertText:@"Fixture @ñ🙂"];
                [controls deleteBackward];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    assert([((AKInputFixtureView *)self.guest.contentView).text isEqual:@"Fixture @ñ"]);
                    [controls dismissKeyboard];
                    assert(!controls.keyboardVisible && host.isFirstResponder);
                    [self stickAndTrackpadSelfTest:host controls:controls];
                });
            });
        });
    }
}
// Drives the two halves' routing directly with synthetic points on this
// test screen; the fixture view counts what arrived through the event queue.
- (void)stickAndTrackpadSelfTest:(UIView *)host controls:(AKTouchControls *)controls {
    AKInputFixtureView *view = (AKInputFixtureView *)self.guest.contentView;
    // On iPhone Duo the buttons stand in the status bar's side strip, with
    // keys 1 to 5, and keys 6 to 0 at the opposite edge; elsewhere in a row.
    [host layoutIfNeeded];
    NSArray<UIButton *> *quick = [controls valueForKey:@"_quickButtons"];
    for (UIButton *button in quick) assert(button.hidden == !controls.vertical);
    if (controls.vertical) {
        CGRect strip = controls.sideStrip;
        assert(strip.size.width >= 44 && strip.origin.y > 40);
        assert(CGRectContainsRect(strip, quick[4].frame) && !CGRectIntersectsRect(strip, quick[9].frame));
        assert(fabs(CGRectGetMidX(quick[9].frame) - (host.bounds.size.width - CGRectGetMidX(strip))) < 1);
        // The strip stays when UIKit stops reporting it (the status bar hides).
        [host setNeedsLayout]; [host layoutIfNeeded];
        assert(CGRectEqualToRect(controls.sideStrip, strip));
    }
    controls.stickEnabled = YES;
    assert(controls.trackpadEnabled);
    CGSize size = host.bounds.size;
    CGPoint origin = CGPointMake(size.width * 0.2, size.height * 0.6);
    [controls stickPhase:UITouchPhaseBegan at:origin];
    [controls stickPhase:UITouchPhaseMoved at:CGPointMake(origin.x + 30, origin.y - 30)];
    UIView *base = [controls valueForKey:@"_stickBase"];
    assert(base.superview == host && !base.hidden && CGPointEqualToPoint(base.center, origin));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
        assert(([view.keysDown isEqualToSet:[NSSet setWithArray:@[@13, @2]]]));
        [controls stickPhase:UITouchPhaseEnded at:CGPointMake(origin.x + 30, origin.y - 30)];
        assert(base.hidden);
        CGPoint right = CGPointMake(size.width * 0.75, size.height * 0.5);
        NSTimeInterval t = NSProcessInfo.processInfo.systemUptime;
        // Tap: left click. Double tap and slide: the right button held while dragging.
        [controls padFingers:1 at:right time:t];
        [controls padFingers:0 at:CGPointZero time:t + 0.05];
        [controls padFingers:1 at:right time:t + 0.15];
        [controls padFingers:1 at:CGPointMake(right.x + 40, right.y) time:t + 0.25];
        [controls padFingers:1 at:CGPointMake(right.x + 80, right.y) time:t + 0.35];
        [controls padFingers:0 at:CGPointZero time:t + 0.4];
        // Two-finger tap: right click. Two-finger slide: scroll wheel.
        [controls padFingers:2 at:right time:t + 1];
        [controls padFingers:0 at:CGPointZero time:t + 1.05];
        for (unsigned i = 0; i <= 6; i++) [controls padFingers:2 at:CGPointMake(right.x, right.y + 12 * i) time:t + 2 + i / 50.0];
        [controls padFingers:0 at:CGPointZero time:t + 2.2];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
            assert(!view.keysDown.count);
            assert(view.leftDowns == 1 && view.leftUps == 1 && view.lastClickCount == 1);
            assert(view.rightDowns == 2 && view.rightUps == 2 && view.rightDrags >= 1 && view.scrolls >= 1);
            NSLog(@"TOUCH_UI_SELF_TEST_PASS: keyboard layout, text delivery, delete and focus restoration; "
                  "stick keys and drawing, tap, double tap and hold, two-finger tap and scroll; %@ layout", controls.vertical ? @"side-strip column" : @"row");
            exit(EXIT_SUCCESS);
        });
    });
}
@end

@interface AKInputFixtureApp : UIResponder <UIApplicationDelegate>
@end
@implementation AKInputFixtureApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Input fixture" sessionRole:session.role];
    config.delegateClass = AKInputFixtureScene.class;
    return config;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AKInputFixtureApp.class)); } }
