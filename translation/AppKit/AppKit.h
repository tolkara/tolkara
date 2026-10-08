// AppKit shim for iPadOS: the subset of the AppKit ABI the guest uses, backed by UIKit.
// Class and selector names must match macOS AppKit exactly; the guest binds to
// them by name. This header is for the shim's own sources only.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "AKSupport.h"
#import "WindowFullscreen.h"

typedef CGRect NSRect;
typedef CGPoint NSPoint;
typedef CGSize NSSize;

typedef NS_ENUM(NSUInteger, NSEventType) {
    NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2,
    NSEventTypeRightMouseDown = 3, NSEventTypeRightMouseUp = 4,
    NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6, NSEventTypeRightMouseDragged = 7,
    NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11, NSEventTypeFlagsChanged = 12,
    NSEventTypeScrollWheel = 22,
    NSEventTypeOtherMouseDown = 25, NSEventTypeOtherMouseUp = 26, NSEventTypeOtherMouseDragged = 27,
};
typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
    NSEventModifierFlagCapsLock = 1 << 16, NSEventModifierFlagShift = 1 << 17,
    NSEventModifierFlagControl = 1 << 18, NSEventModifierFlagOption = 1 << 19,
    NSEventModifierFlagCommand = 1 << 20,
};

@class NSWindow, NSView, NSEvent, NSCursor;

@interface NSResponder : AKStubObject
@property (assign) NSResponder *nextResponder;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events;
- (void)insertText:(id)text;
- (void)doCommandBySelector:(SEL)selector;
- (void)keyDown:(NSEvent *)e;
- (void)keyUp:(NSEvent *)e;
- (void)flagsChanged:(NSEvent *)e;
- (void)mouseDown:(NSEvent *)e;
- (void)mouseUp:(NSEvent *)e;
- (void)mouseMoved:(NSEvent *)e;
- (void)mouseDragged:(NSEvent *)e;
- (void)rightMouseDown:(NSEvent *)e;
- (void)rightMouseUp:(NSEvent *)e;
- (void)rightMouseDragged:(NSEvent *)e;
- (void)otherMouseDown:(NSEvent *)e;
- (void)otherMouseUp:(NSEvent *)e;
- (void)otherMouseDragged:(NSEvent *)e;
- (void)scrollWheel:(NSEvent *)e;
@end

@interface NSEvent : AKStubObject
@property NSEventType type;
@property NSEventModifierFlags modifierFlags;
@property NSTimeInterval timestamp;
@property (weak) NSWindow *window;
@property NSPoint locationInWindow;   // bottom-left origin, points
@property CGFloat deltaX, deltaY, scrollingDeltaX, scrollingDeltaY;
@property unsigned short keyCode;     // macOS virtual key code
@property (copy) NSString *characters, *charactersIgnoringModifiers;
@property BOOL isARepeat;
@property NSInteger buttonNumber, clickCount;
// Its Quartz event (a CGEventRef): the location in global display coordinates.
- (CFTypeRef)CGEvent;
+ (NSPoint)mouseLocation;
@end

// A region of a view whose mouse movement its owner follows. The iPad's
// pointer never leaves the application's view, so no entered or exited
// events are sent; the area is kept for its owner.
@interface NSTrackingArea : AKStubObject
- (instancetype)initWithRect:(NSRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary *)userInfo;
@property (readonly) NSRect rect;
@property (readonly) NSUInteger options;
@property (readonly, weak) id owner;
@property (readonly, copy) NSDictionary *userInfo;
@end

@interface NSView : NSResponder
- (instancetype)initWithFrame:(NSRect)frame;
@property (nonatomic) NSRect frame;
@property (nonatomic) NSRect bounds;
@property (nonatomic) BOOL wantsLayer;
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, readonly) NSView *superview;
@property (nonatomic, readonly) NSArray<NSView *> *subviews;
- (CALayer *)makeBackingLayer;
- (void)addSubview:(NSView *)v;
- (void)removeFromSuperview;
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v;
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v;
- (void)setFrameSize:(NSSize)s;
- (void)viewDidMoveToWindow;
- (void)resetCursorRects;
- (void)discardCursorRects;
- (void)addCursorRect:(NSRect)rect cursor:(NSCursor *)cursor;
- (NSCursor *)ak_cursorAtPoint:(NSPoint)point;
- (NSPoint)convertPointToBacking:(NSPoint)point;
- (NSPoint)convertPointFromBacking:(NSPoint)point;
- (NSSize)convertSizeFromBacking:(NSSize)s;
- (NSSize)convertSizeToBacking:(NSSize)s;
- (NSRect)convertRectFromBacking:(NSRect)r;
- (NSRect)convertRectToBacking:(NSRect)r;
@property (nonatomic, readonly) NSArray<NSTrackingArea *> *trackingAreas;
- (void)addTrackingArea:(NSTrackingArea *)area;
- (void)removeTrackingArea:(NSTrackingArea *)area;
- (void)updateTrackingAreas;
// Layer-backed drawing: a view marked for display gets updateLayer on the
// main thread's next turn, if it wants that (drawRect: is not supported).
@property (nonatomic) BOOL needsDisplay;
- (void)setNeedsDisplayInRect:(NSRect)rect;
- (void)displayIfNeeded;
- (void)display;
@property (nonatomic, readonly) BOOL wantsUpdateLayer;
- (void)updateLayer;
@end

@interface NSWindow : NSResponder <AKFullscreenWindow>
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d;
// Unique for the process; visible windows are numbered front to back.
@property (readonly) NSInteger windowNumber;
+ (NSArray<NSNumber *> *)windowNumbersWithOptions:(NSUInteger)options;
+ (NSInteger)windowNumberAtPoint:(NSPoint)point belowWindowWithWindowNumber:(NSInteger)windowNumber;
@property (nonatomic, strong) NSView *contentView;
@property (copy) NSString *title;
@property BOOL acceptsMouseMovedEvents;
@property BOOL releasedWhenClosed;
@property BOOL hasShadow;
- (void)setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate;
@property NSUInteger styleMask;
@property NSInteger level;
@property(weak) NSWindow *parentWindow;
@property NSSize contentMinSize, contentMaxSize, contentAspectRatio, contentResizeIncrements;
@property(strong) id backgroundColor;
@property(readonly, getter=isMiniaturized) BOOL miniaturized;
- (void)setContentSize:(NSSize)size;
- (void)invalidateCursorRectsForView:(NSView *)view;
- (id)screen;
@property (weak) id delegate;
@property NSPoint ak_mouseLocation;
- (NSPoint)mouseLocationOutsideOfEventStream;
@property (readonly) CGFloat backingScaleFactor;
@property (readonly) NSRect frame;
@property (readonly) NSResponder *firstResponder;
@property (readonly, getter=isKeyWindow) BOOL keyWindow;
@property (readonly, getter=isVisible) BOOL visible;
@property (readonly) NSUInteger occlusionState;
@property NSUInteger collectionBehavior;
@property (readonly) NSRect contentLayoutRect;
- (NSPoint)convertPointToScreen:(NSPoint)p;
- (NSPoint)convertPointFromScreen:(NSPoint)p;
- (void)toggleFullScreen:(id)sender;
// Windows on the iPad have no frame of their own: content and frame are one.
- (NSRect)frameRectForContentRect:(NSRect)rect;
- (NSRect)contentRectForFrameRect:(NSRect)rect;
+ (NSRect)frameRectForContentRect:(NSRect)rect styleMask:(NSUInteger)style;
+ (NSRect)contentRectForFrameRect:(NSRect)rect styleMask:(NSUInteger)style;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)orderFront:(id)sender;
- (void)makeKeyWindow;
- (void)setIsVisible:(BOOL)visible;
- (void)orderOut:(id)sender;
- (BOOL)makeFirstResponder:(NSResponder *)r;
- (void)sendEvent:(NSEvent *)e;
- (void)close;
@end

@interface NSApplication : NSResponder
@property (nonatomic,readonly) NSEvent *currentEvent;
+ (NSApplication *)sharedApplication;
- (NSWindow *)windowWithWindowNumber:(NSInteger)number;
@property (weak) id delegate;
@property NSUInteger presentationOptions;
@property (strong) id mainMenu, servicesMenu, windowsMenu, helpMenu;
@property (readonly) NSWindow *keyWindow, *mainWindow;
@property (readonly) NSArray<NSWindow *> *windows;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly, getter=isActive) BOOL active;
- (BOOL)setActivationPolicy:(NSInteger)p;
- (void)activateIgnoringOtherApps:(BOOL)f;
- (void)finishLaunching;
- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate;
- (void)sendEvent:(NSEvent *)e;
- (void)postEvent:(NSEvent *)e atStart:(BOOL)atStart;
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dq;
@end

// A window that floats above documents; on the iPad, a window like any other.
@interface NSPanel : NSWindow
@property (getter=isFloatingPanel) BOOL floatingPanel;
@property BOOL becomesKeyOnlyIfNeeded, worksWhenModal;
@end

extern NSApplication *NSApp;
extern int NSApplicationMain(int argc, const char *argv[]);

@interface NSWindowController : NSResponder
- (instancetype)initWithWindow:(NSWindow *)window;
@property (nonatomic, strong) NSWindow *window;
- (void)showWindow:(id)sender;
- (void)close;
@end

// Shim-internal: the modifier state after a modifier key goes down or up, and
// reconciled with the modifiers UIKit reports (held keys are device bits).
NSEventModifierFlags AKModifiersAfterKey(NSEventModifierFlags held, UIKeyboardHIDUsage usage, BOOL down);
NSEventModifierFlags AKModifiersReconciled(NSEventModifierFlags held, NSEventModifierFlags reported);
// Shim-internal
@interface NSWindow (AKInternal)
- (void)ak_hostBoundsChanged:(CGRect)bounds;
@end

@class NSMenu;
@interface NSMenuItem : AKStubObject
@property(copy) NSString *title;
@property(copy) NSString *keyEquivalent;
@property SEL action;
@property(weak) id target;
@property(strong) NSMenu *submenu;
@property(weak) NSMenu *menu;
@property NSInteger tag, state;
@property NSUInteger keyEquivalentModifierMask;
@property BOOL enabled, hidden;
@property(strong) id representedObject;
@property(readonly) BOOL isSeparatorItem;
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key;
+ (instancetype)separatorItem;
@end
@interface NSMenu : AKStubObject
@property(copy) NSString *title;
@property BOOL autoenablesItems;
@property(weak) id delegate;
@property(readonly) NSArray<NSMenuItem *> *itemArray;
@property(readonly) NSInteger numberOfItems;
- (instancetype)initWithTitle:(NSString *)title;
- (void)addItem:(NSMenuItem *)item;
- (void)insertItem:(NSMenuItem *)item atIndex:(NSInteger)index;
- (void)removeItem:(NSMenuItem *)item;
- (void)removeItemAtIndex:(NSInteger)index;
- (NSMenuItem *)itemAtIndex:(NSInteger)index;
- (NSMenuItem *)itemWithTag:(NSInteger)tag;
- (NSMenuItem *)itemWithTitle:(NSString *)title;
- (NSInteger)indexOfItem:(NSMenuItem *)item;
- (void)setSubmenu:(NSMenu *)submenu forItem:(NSMenuItem *)item;
@end

@interface NSScreen : AKStubObject
+ (NSArray<NSScreen *> *)screens;
+ (NSScreen *)mainScreen;
@property(readonly) NSRect frame, visibleFrame;
@property(readonly) CGFloat backingScaleFactor;
@property(readonly) NSDictionary *deviceDescription;
@end
