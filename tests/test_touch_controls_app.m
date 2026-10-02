// Original UIKit/AppKit fixture for manual touch/keyboard testing. No guest.
#import "AppKit.h"
#import "TouchControls.h"
#include <assert.h>

@interface AKInputFixtureView : NSView
@property CATextLayer *heading, *instructions, *result;
@property NSMutableString *text;
@property NSString *lastAction;
@end
@implementation AKInputFixtureView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [UIColor colorWithRed:0.06 green:0.10 blue:0.16 alpha:1].CGColor;
        _text = [NSMutableString new];
        _lastAction = @"Ready";
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
        _instructions.string = @"Slide: move • Tap: left click • Two fingers: scroll / right click\nThree-finger tap: middle click • Hold then slide: drag\nUse the keyboard button at the bottom right. This is an original test screen.";
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
    self.result.string = [NSString stringWithFormat:@"%@\nText: %@", self.lastAction, self.text];
    [CATransaction flush];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 51 && self.text.length) {
        [self.text deleteCharactersInRange:[self.text rangeOfComposedCharacterSequenceAtIndex:self.text.length - 1]];
    } else if (event.keyCode == 53) [self.text setString:@""];
    else if (event.characters.length && event.keyCode != 51) [self.text appendString:event.characters];
    self.lastAction = @"Keyboard input received";
    [self refresh];
}
- (void)mouseMoved:(NSEvent *)event {
    self.lastAction = [NSString stringWithFormat:@"Pointer %.0f, %.0f", event.locationInWindow.x, event.locationInWindow.y];
    [self refresh];
}
- (void)mouseDown:(NSEvent *)event { self.lastAction = event.clickCount == 2 ? @"Double click" : @"Left click / hold"; [self refresh]; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; self.lastAction = @"Right click / hold"; [self refresh]; }
- (void)otherMouseDown:(NSEvent *)event { (void)event; self.lastAction = @"Middle click"; [self refresh]; }
- (void)mouseDragged:(NSEvent *)event { (void)event; self.lastAction = @"Left drag"; [self refresh]; }
- (void)rightMouseDragged:(NSEvent *)event { (void)event; self.lastAction = @"Right drag"; [self refresh]; }
- (void)scrollWheel:(NSEvent *)event {
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
                    NSLog(@"TOUCH_UI_SELF_TEST_PASS: keyboard layout, text delivery, delete and focus restoration");
                    exit(EXIT_SUCCESS);
                });
            });
        });
    }
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
