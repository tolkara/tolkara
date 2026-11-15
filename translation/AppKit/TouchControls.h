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

// Optional: the launcher's On-Screen Controls switch stores this Boolean.
// Without a stored choice they are shown on iPhone and not on iPad.
extern NSString *const AKTouchControlsDefaultsKey;   // "AKTouchControls"

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
// The iPhone Duo's side strip in this view's coordinates, or CGRectNull for
// the row. With a strip this view covers the screen, taking touches only on its
// buttons, in a column in the strip and one mirroring it at the other edge:
// on the right Escape, Tab, keys 1 to 5 and Jump; on the left the keyboard,
// stick, trackpad and Shift buttons and keys 6 to 0. Without a strip the row is Jump,
// stick, trackpad and keyboard. Key buttons hold their key while touched.
@property (nonatomic) CGRect sideStrip;
// A column's width at most: the largest button (44 points) and 6 on each side.
// The iPhone Duo's status-bar strip is wider (84 points); the game gets the rest.
#define AKTouchControlsColumnWidth 56.0
@property (nonatomic, readonly) BOOL vertical;
- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)cancelTouches;
- (void)toggleKeyboard;
- (void)dismissKeyboard;
// The two halves of touch routing; our own test screen drives them directly.
- (void)stickPhase:(UITouchPhase)phase at:(CGPoint)point;
- (void)padFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time;
@end
