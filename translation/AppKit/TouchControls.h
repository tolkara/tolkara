#import <UIKit/UIKit.h>

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
// The movement stick holds a key down until it reports the release.
- (void)touchKey:(unsigned short)code characters:(NSString *)characters pressed:(BOOL)pressed;
// The Shift button: held while touched, for the mouse and keys alike.
- (void)touchShift:(BOOL)pressed;
- (void)touchTrackpadChanged:(BOOL)enabled;
// Camera mode: the pointer goes to this point of the game's view (a touch's).
- (void)touchPointAt:(CGPoint)point;
@end

// A column's width: the largest button (44 points) and 6 on each side. The
// iPhone Duo's status-bar strip is wider (84 points); the game gets the rest.
#define AKTouchControlsColumnWidth 56.0
// The column layouts' buttons, in this order: the left side's from the top
// (keyboard, stick, trackpad, Shift, keys 6 to 0), then the right side's
// (Escape, Tab, keys 1 to 5, Jump).
enum { AKTouchLeftButtons = 9, AKTouchRightButtons = 8, AKTouchButtonCount = AKTouchLeftButtons + AKTouchRightButtons };
// With two columns a side, each side's first two buttons (keyboard and stick;
// Escape and Tab) stand in the outer column, at the top.
enum { AKTouchOuterButtons = 2 };
typedef struct {
    NSUInteger columns;   // a side: 0 is the row over the game, else 1 or 2
    CGFloat bottom;       // the columns' lower limit: a button that reaches below it is hidden
    CGRect game;          // the game's part of the container
    CGRect buttons[AKTouchButtonCount];   // in the container; columns only
} AKTouchLayout;
// The one layout decision, from a container's size and safe area and the
// iPhone Duo's side strip (CGRectNull without one):
// - With a strip: one column in it and one mirroring it at the other edge,
//   both from the strip's top, as wide as the strip.
// - Otherwise columns at both edges: one a side where nine buttons fit the
//   height at full size (an iPad), else two (an iPhone on its side). Their
//   rows stand in the middle of the height the safe area leaves, level on both
//   sides, the shorter right side at the bottom so that Jump is beside key 0.
//   A column never stands in a side inset (the Dynamic Island's), except the
//   outer of two, whose two buttons stand in the top rows, above the island;
//   so the game loses one column beyond the inset, or two columns where the
//   inset is narrower than one.
// - The row where the columns would leave the game under 400 points of width
//   (an iPhone upright, a narrow iPad window).
// Buttons are 44 points on a 52-point pitch, shrunk down to 34 on 40 to fit.
AKTouchLayout AKTouchLayoutFor(CGSize size, UIEdgeInsets safe, CGRect strip);

// Optional: the launcher's On-Screen Controls switch stores this Boolean.
// Without a stored choice they are shown on iPhone and not on iPad.
extern NSString *const AKTouchControlsDefaultsKey;   // "AKTouchControls"

// Optional: the launcher's Pointer Acceleration switch stores this Boolean
// (on without a stored choice). Off, the pointer moves by a constant gain:
// a mouse's free pointer follows its raw motion in place of the iPadOS
// pointer (AppKit.m, "Raw pointer"), times AKPointerSpeedDefaultsKey (a
// number, 1 without a stored choice), and the touch trackpad's gain no longer
// follows the finger's speed. Read when a game starts.
extern NSString *const AKPointerAccelerationDefaultsKey;   // "AKPointerAcceleration"
extern NSString *const AKPointerSpeedDefaultsKey;          // "AKPointerSpeed"
BOOL AKPointerAccelerationEnabled(void);
double AKPointerSpeed(void);

// Lives above the guest layer, but only its buttons intercept hit testing.
// The host supplies direct touches; hardware mouse input stays on its old path.
@interface AKTouchControls : UIView <UIKeyInput>
@property (class, nonatomic, readonly) BOOL enabled;
@property (nonatomic, weak) id<AKTouchControlsDelegate> delegate;
@property (nonatomic) BOOL trackpadEnabled;
// How touches on the game act while the controls handle them (trackpadEnabled):
// camera mode (the default, TouchCamera.h) touches the game directly with the
// right button, to turn the camera, attack or loot; cursor mode is the touch
// trackpad (TouchTrackpad.h), a relative pointer for menus and dragging spells.
// The hand button switches between them; the choice is remembered.
@property (nonatomic) BOOL cursorMode;
// The view the game draws in: touches on it drive the stick and the trackpad,
// in its coordinates. Without one, the view this one is in.
@property (nonatomic, weak) UIView *gameView;
// With the stick on, a touch landing on the left half of the game is a
// movement stick (W, A, S and D) and the right half is the trackpad. It
// needs trackpad mode: turning either on or off keeps the two consistent.
@property (nonatomic) BOOL stickEnabled;
@property (nonatomic, readonly) BOOL keyboardVisible;
// Where the buttons stand (AKTouchLayoutFor). In a column layout this view
// covers the game's container, taking touches only on its buttons, which
// stand beside the game; in the row it is the row itself: Jump, stick,
// trackpad and keyboard. Key buttons hold their key while touched. While the
// iOS keyboard is open, a column button that reaches below this view's bottom
// edge (the keyboard's top) is hidden, as one below the layout's limit always
// is; the others stay where they are.
@property (nonatomic) AKTouchLayout layout;
@property (nonatomic, readonly) BOOL vertical;
- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)cancelTouches;
- (void)toggleKeyboard;
- (void)dismissKeyboard;
// The two halves of touch routing; our own test screen drives them directly.
- (void)stickPhase:(UITouchPhase)phase at:(CGPoint)point;
- (void)padFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time;
@end
