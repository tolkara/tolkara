#import <UIKit/UIKit.h>

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
- (void)touchTrackpadChanged:(BOOL)enabled;
@end

// Optional: the launcher's On-Screen Controls switch stores this Boolean.
// Without a stored choice they are shown on iPhone and not on iPad.
extern NSString *const AKTouchControlsDefaultsKey;   // "AKTouchControls"

// Lives above the guest layer, but only the two buttons intercept hit testing.
// The host supplies direct touches; hardware mouse input stays on its old path.
@interface AKTouchControls : UIView <UIKeyInput>
@property (class, nonatomic, readonly) BOOL enabled;
@property (nonatomic, weak) id<AKTouchControlsDelegate> delegate;
@property (nonatomic) BOOL trackpadEnabled;
@property (nonatomic, readonly) BOOL keyboardVisible;
- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)cancelTouches;
- (void)toggleKeyboard;
- (void)dismissKeyboard;
@end
