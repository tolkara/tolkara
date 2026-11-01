#import <UIKit/UIKit.h>

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
// The movement stick holds a key down until it reports the release.
- (void)touchKey:(unsigned short)code characters:(NSString *)characters pressed:(BOOL)pressed;
- (void)touchTrackpadChanged:(BOOL)enabled;
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
// With the stick on, a touch landing on the left half of the game is a
// movement stick (W, A, S and D) and the right half is the trackpad. It
// needs trackpad mode: turning either on or off keeps the two consistent.
@property (nonatomic) BOOL stickEnabled;
@property (nonatomic, readonly) BOOL keyboardVisible;
// The iPhone Duo's side strip in this view's coordinates, or CGRectNull for
// the row. With a strip this view covers the game, taking touches only on its
// buttons, in a column in the strip and one mirroring it at the other edge:
// on the right Escape, Tab, keys 1 to 5 and Jump; on the left the keyboard,
// stick and trackpad buttons and keys 6 to 0. Without a strip the row is Jump,
// stick, trackpad and keyboard. Key buttons hold their key while touched.
@property (nonatomic) CGRect sideStrip;
@property (nonatomic, readonly) BOOL vertical;
- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)cancelTouches;
- (void)toggleKeyboard;
- (void)dismissKeyboard;
// The two halves of touch routing; our own test screen drives them directly.
- (void)stickPhase:(UITouchPhase)phase at:(CGPoint)point;
- (void)padFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time;
@end
