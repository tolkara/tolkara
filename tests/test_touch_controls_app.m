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
            [host.superview setNeedsLayout]; [host.superview layoutIfNeeded];
            CGSize originalSize = host.bounds.size;
            NSArray<NSValue *> *columns = [self checkColumns:host controls:controls];
            [controls toggleKeyboard];
            if (!selfTest) return;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [host.superview layoutIfNeeded];
                assert(controls.keyboardVisible && CGSizeEqualToSize(originalSize, host.bounds.size));
                CGFloat keyboardTop = CGRectGetMinY(host.superview.keyboardLayoutGuide.layoutFrame);
                // An iPad simulator counts the Mac's keyboard as a hardware
                // keyboard, and iOS then shows only the row above its own.
                CGFloat keyboardHeight = host.keyboardLayoutGuide.layoutFrame.size.height;
                BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
                assert(keyboardHeight > 100 || (pad && keyboardHeight >= 44));
                if (keyboardHeight <= 100) NSLog(@"touch controls: iOS showed only the row above its keyboard (%.0f points)", keyboardHeight);
                assert(CGRectGetMaxY(controls.frame) <= keyboardTop);
                assert(CGRectGetMinY(controls.frame) >= 0);
                // With the keyboard open the game and every button stay where
                // they were; the buttons it would cover are hidden.
                NSArray<NSValue *> *open = [self columnFrames:host controls:controls hidden:keyboardTop];
                assert([open isEqual:columns]);
                [controls insertText:@"Fixture @ñ🙂"];
                [controls deleteBackward];
                // Paste sits between → and Return and types the clipboard's
                // text without its line break.
                UIStackView *row = (UIStackView *)controls.inputAccessoryView;
                assert(row.arrangedSubviews.count == 7);
                UIView *pasteControl = row.arrangedSubviews[4].subviews.firstObject;
                assert([pasteControl isKindOfClass:UIPasteControl.class] && ((UIPasteControl *)pasteControl).target == (id)controls);
                assert([((UIButton *)row.arrangedSubviews[3]).currentTitle isEqual:@"→"] && [((UIButton *)row.arrangedSubviews[5]).currentTitle isEqual:@"↵"]);
                NSArray<NSItemProvider *> *clipboard = @[[[NSItemProvider alloc] initWithObject:@" Pa$te\r\n"]];
                assert([controls canPasteItemProviders:clipboard]);
                [controls pasteItemProviders:clipboard];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    assert([((AKInputFixtureView *)self.guest.contentView).text isEqual:@"Fixture @ñ Pa$te"]);
                    [controls dismissKeyboard];
                    assert(!controls.keyboardVisible && host.isFirstResponder);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [host.superview layoutIfNeeded];
                        assert([[self columnFrames:host controls:controls hidden:CGFLOAT_MAX] isEqual:columns]);
                        [self stickAndTrackpadSelfTest:host controls:controls];
                    });
                });
            });
        });
    }
}
// The game's frame, then the column buttons' frames, in the container. In a
// column layout the buttons that reach below `hidden` (the iOS keyboard's top)
// or the columns' own lower limit must be hidden and the others shown. The
// row gives the game's frame alone.
- (NSArray<NSValue *> *)columnFrames:(UIView *)host controls:(AKTouchControls *)controls hidden:(CGFloat)hidden {
    NSMutableArray<NSValue *> *frames = [NSMutableArray arrayWithObject:[NSValue valueWithCGRect:host.frame]];
    if (!controls.vertical) return frames;
    assert(controls.superview == host.superview && CGPointEqualToPoint(controls.frame.origin, CGPointZero));
    NSArray<UIButton *> *buttons = [controls valueForKey:@"_columnButtons"];
    assert(buttons.count == AKTouchButtonCount);
    unsigned shown = 0;
    hidden = MIN(hidden, controls.layout.bottom);
    for (UIButton *button in buttons) {
        assert(button.hidden == (CGRectGetMaxY(button.frame) > hidden));
        shown += !button.hidden;
        [frames addObject:[NSValue valueWithCGRect:button.frame]];
    }
    // The keyboard button is among those that stay, to close the keyboard.
    assert(shown >= 2 && !buttons[0].hidden);
    return frames;
}
// The layout this screen must get: an iPhone on its side two columns a side,
// an iPad or the iPhone Duo's inner display one. Every button on the screen,
// clear of the others and of the game, which lies between the columns and is
// the display the game is told. Returns columnFrames with the keyboard closed.
- (NSArray<NSValue *> *)checkColumns:(UIView *)host controls:(AKTouchControls *)controls {
    UIView *container = host.superview;
    CGRect bounds = container.bounds, game = host.frame;
    BOOL duo = !CGRectIsNull([[host valueForKey:@"_touchStrip"] CGRectValue]);
    BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    NSUInteger expected = bounds.size.width < bounds.size.height && phone ? 0 : phone && !duo ? 2 : 1;
    NSLog(@"touch controls: %lu column(s) a side, container %@ safe %@ game %@", (unsigned long)controls.layout.columns,
          NSStringFromCGSize(bounds.size), NSStringFromUIEdgeInsets(container.safeAreaInsets), NSStringFromCGRect(game));
    assert(controls.layout.columns == expected);
    NSArray<NSValue *> *frames = [self columnFrames:host controls:controls hidden:CGFLOAT_MAX];
    if (!expected) { assert(CGRectEqualToRect(game, bounds)); return frames; }
    UIEdgeInsets safe = container.safeAreaInsets;
    NSMutableSet<NSNumber *> *left = [NSMutableSet new], *right = [NSMutableSet new];
    NSArray<UIButton *> *buttons = [controls valueForKey:@"_columnButtons"];
    for (NSUInteger i = 1; i < frames.count; i++) {
        CGRect frame = frames[i].CGRectValue;
        // Only the Duo's short columns may have more buttons than fit.
        assert(duo || !buttons[i - 1].hidden);
        if (buttons[i - 1].hidden) continue;
        assert(CGRectContainsRect(bounds, frame) && frame.size.width >= 34 && frame.size.width == frame.size.height);
        assert(!CGRectIntersectsRect(frame, game));
        // Clear of the home indicator's inset and, but for the outer column's
        // buttons at the top, of the side insets.
        assert(CGRectGetMaxY(frame) <= bounds.size.height - safe.bottom && CGRectGetMinY(frame) >= safe.top);
        BOOL leftSide = i <= AKTouchLeftButtons;
        assert(leftSide == (CGRectGetMaxX(frame) <= CGRectGetMinX(game)) && leftSide != (CGRectGetMinX(frame) >= CGRectGetMaxX(game)));
        if (!duo && (CGRectGetMinX(frame) < safe.left || CGRectGetMaxX(frame) > bounds.size.width - safe.right))
            assert(expected == 2 && CGRectGetMaxY(frame) < bounds.size.height / 2 - 70);
        [leftSide ? left : right addObject:@(CGRectGetMidX(frame))];
        for (NSUInteger j = 1; j < i; j++) assert(!CGRectIntersectsRect(CGRectInset(frame, -4, -4), frames[j].CGRectValue));
    }
    assert(left.count == expected && right.count == expected);
    // The game: the full height, in the middle where the insets are equal, and
    // no narrower than one column past each inset (two where there is none).
    assert(game.origin.y == 0 && game.size.height == bounds.size.height);
    if (safe.left == safe.right) assert(CGRectGetMidX(game) == CGRectGetMidX(bounds));
    if (!duo) assert(game.origin.x == AKTouchControlsColumnWidth + MAX(safe.left, (expected - 1) * AKTouchControlsColumnWidth));
    assert(CGSizeEqualToSize(NSScreen.mainScreen.frame.size, game.size));
    assert(CGSizeEqualToSize(self.guest.contentView.frame.size, game.size));
    return frames;
}
// Drives the two halves' routing directly with synthetic points on this
// test screen; the fixture view counts what arrived through the event queue.
- (void)stickAndTrackpadSelfTest:(UIView *)host controls:(AKTouchControls *)controls {
    AKInputFixtureView *view = (AKInputFixtureView *)self.guest.contentView;
    // In a column layout the right side has Escape, Tab, 1 to 5 and Jump
    // and the left the toggles, Shift and 6 to 0. Elsewhere they stand in a row.
    [host layoutIfNeeded];
    NSArray<UIButton *> *quick = [controls valueForKey:@"_quickButtons"];
    UIButton *jump = [controls valueForKey:@"_jumpButton"], *escape = [controls valueForKey:@"_escapeButton"];
    for (UIButton *button in [quick arrayByAddingObject:escape])
        assert(button.hidden == (!controls.vertical || CGRectGetMaxY(button.frame) > controls.layout.bottom));
    assert(!jump.hidden);
    if (controls.vertical) {
        UIView *container = host.superview;
        CGFloat middle = container.bounds.size.width / 2;
        assert(CGRectGetMidX(escape.frame) > middle && CGRectGetMidX(quick[4].frame) > middle && CGRectGetMidX(quick[9].frame) < middle);
        assert(CGRectGetMidX(jump.frame) == CGRectGetMidX(quick[4].frame) && CGRectGetMinY(jump.frame) > CGRectGetMaxY(quick[4].frame));
        assert(controls.superview == container && controls.gameView == host);
    }
    CGRect strip = [[host valueForKey:@"_touchStrip"] CGRectValue];
    if (!CGRectIsNull(strip)) {
        // The iPhone Duo: the columns start below the status bar, in the strip
        // and mirroring it, and the game has the space between them.
        UIView *container = host.superview;
        CGFloat middle = container.bounds.size.width / 2;
        assert(controls.layout.columns == 1 && strip.size.width >= 44 && strip.origin.y > 40);
        assert(escape.frame.origin.y == strip.origin.y && CGRectGetMidX(escape.frame) == MAX(CGRectGetMidX(strip), 2 * middle - CGRectGetMidX(strip)));
        CGFloat side = CGRectGetMidX(strip) > middle ? container.bounds.size.width - CGRectGetMinX(strip) : CGRectGetMaxX(strip);
        assert(CGRectEqualToRect(host.frame, CGRectInset(container.bounds, side, 0)));
        // The strip stays when UIKit stops reporting it (the status bar hides).
        AKTouchLayout before = controls.layout, after;
        [container setNeedsLayout]; [container layoutIfNeeded];
        after = controls.layout;
        assert(CGRectEqualToRect([[host valueForKey:@"_touchStrip"] CGRectValue], strip) && !memcmp(&before, &after, sizeof after));
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
                  "stick keys and drawing, tap, double tap and hold, two-finger tap and scroll; %@ layout, unmoved by the keyboard",
                  @[@"row", @"one column a side", @"two columns a side"][controls.layout.columns]);
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
