// GameController adapter: a Mac without gamepads. Experimental and opt-in
// (TOLKARA_EXPERIMENTAL_ADAPTERS=GameController; see the "experimental" marker),
// and in a generic build used only for a profile with TOLKARA_ADAPTERS naming
// it (the "opt-in" marker): Cyberpunk 2077. Other applications get iOS's.
// The AppKit adapter links the real framework for GCMouse raw input, and iOS
// then activates a legacy device session that reports the host's keyboard and
// mouse (in the simulator even a virtual MFi controller) and posts connect
// notifications macOS would only post for real hardware. One game's handler
// dereferenced state such a device lacks and crashed. This shim therefore
// stands alone (see the "standalone" marker): the guest gets stub classes that
// report no controllers, and its notification constants use names nothing
// posts, so its observers never fire, as on a Mac with no controller. Real
// gamepads are hidden too: an application using it loses gamepad input.
// Not yet validated on a device beyond that game's startup.
#import "AKSupport.h"

@interface GCController : AKStubObject
@end
@implementation GCController
+ (NSArray *)controllers { return @[]; }
+ (id)current { return nil; }
@end

@interface GCDualSenseGamepad : AKStubObject
@end
@implementation GCDualSenseGamepad
@end

@interface GCDualShockGamepad : AKStubObject
@end
@implementation GCDualShockGamepad
@end

// Connect, disconnect and current-controller names are deliberately namespaced:
// the real framework is loaded beside this shim and posts the real names.
NSString *const GCControllerDidConnectNotification = @"AKGCControllerDidConnectNotification";
NSString *const GCControllerDidDisconnectNotification = @"AKGCControllerDidDisconnectNotification";
NSString *const GCControllerDidBecomeCurrentNotification = @"AKGCControllerDidBecomeCurrentNotification";
NSString *const GCControllerDidStopBeingCurrentNotification = @"AKGCControllerDidStopBeingCurrentNotification";
NSString *const GCMouseDidConnectNotification = @"AKGCMouseDidConnectNotification";
NSString *const GCMouseDidDisconnectNotification = @"AKGCMouseDidDisconnectNotification";
NSString *const GCKeyboardDidConnectNotification = @"AKGCKeyboardDidConnectNotification";
NSString *const GCKeyboardDidDisconnectNotification = @"AKGCKeyboardDidDisconnectNotification";
// Everything else has its macOS value (checked against the host framework), so
// an application that keys dictionaries or compares names with them keeps working.
NSString *const GCProductCategoryDualSense = @"DualSense";
NSString *const GCProductCategoryDualShock4 = @"DualShock 4";
NSString *const GCProductCategoryXboxOne = @"Xbox One";
NSString *const GCHapticsLocalityDefault = @"Default";
NSString *const GCHapticsLocalityAll = @"All";
NSString *const GCHapticsLocalityHandles = @"Handles";
NSString *const GCHapticsLocalityLeftHandle = @"Left Handle";
NSString *const GCHapticsLocalityRightHandle = @"Right Handle";
NSString *const GCHapticsLocalityTriggers = @"Triggers";
NSString *const GCHapticsLocalityLeftTrigger = @"Left Trigger";
NSString *const GCHapticsLocalityRightTrigger = @"Right Trigger";
NSString *const GCInputButtonA = @"Button A";
NSString *const GCInputButtonB = @"Button B";
NSString *const GCInputButtonX = @"Button X";
NSString *const GCInputButtonY = @"Button Y";
NSString *const GCInputButtonMenu = @"Button Menu";
NSString *const GCInputButtonOptions = @"Button Options";
NSString *const GCInputButtonHome = @"Button Home";
NSString *const GCInputDualShockTouchpadButton = @"Touchpad Button";
NSString *const GCInputDualShockTouchpadOne = @"Touchpad 1";
NSString *const GCInputDualShockTouchpadTwo = @"Touchpad 2";
NSString *const GCInputLeftShoulder = @"Left Shoulder";
NSString *const GCInputRightShoulder = @"Right Shoulder";
NSString *const GCInputLeftTrigger = @"Left Trigger";
NSString *const GCInputRightTrigger = @"Right Trigger";
NSString *const GCInputLeftThumbstick = @"Left Thumbstick";
NSString *const GCInputRightThumbstick = @"Right Thumbstick";
NSString *const GCInputLeftThumbstickButton = @"Left Thumbstick Button";
NSString *const GCInputRightThumbstickButton = @"Right Thumbstick Button";
NSString *const GCInputDirectionPad = @"Direction Pad";
NSString *const GCInputXboxPaddleOne = @"Paddle 1";
NSString *const GCInputXboxPaddleTwo = @"Paddle 2";
NSString *const GCInputXboxPaddleThree = @"Paddle 3";
NSString *const GCInputXboxPaddleFour = @"Paddle 4";
const float GCHapticDurationInfinite = 1000000.0f;
