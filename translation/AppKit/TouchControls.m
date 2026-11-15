#import "TouchControls.h"
#import "TouchTrackpad.h"
#import "TouchCamera.h"
#import "TouchStick.h"
#import "AKSupport.h"
#import <GameController/GameController.h>

NSString *const AKTouchControlsDefaultsKey = @"AKTouchControls";
static NSString *const AKTouchTrackpadDefaultsKey = @"AKTouchTrackpadEnabled";
static NSString *const AKTouchStickDefaultsKey = @"AKTouchStickEnabled";
// Camera or cursor mode, remembered for games whose profile asks for camera
// mode (TOLKARA_TOUCH_MODE=camera); other games always use the trackpad.
static NSString *const AKTouchCursorModeDefaultsKey = @"AKTouchCursorMode";

@implementation AKTouchControls {
    UIButton *_keyboardButton, *_trackpadButton, *_stickButton, *_jumpButton, *_escapeButton, *_tabButton, *_shiftButton;
    BOOL _shiftHeld;
    UIImpactFeedbackGenerator *_haptic;   // a tick when a held touch is ready to drag
    NSArray<UIButton *> *_quickButtons;
    unsigned _quickHeld;   // bit i: the key of the held button tagged i is down
    UIView *_accessory, *_stickBase, *_stickKnob;
    NSTimer *_holdTimer;
    AKTrackpad _pad;
    AKTouchCamera _camera;
    BOOL _cameraProfile;   // the profile asks for camera mode: the hand button switches modes
    AKStick _stick;
    // UIKit keeps a touch's object for its lifetime. The stick's touch, and
    // left-half touches that arrive while it is held, never reach the trackpad.
    __weak UITouch *_stickTouch;
    NSHashTable<UITouch *> *_ignoredTouches;
    // A click lasts long enough for a game that polls the buttons once a
    // frame: a release sooner than that after its press waits here.
    NSTimeInterval _pressedAt[3];
    NSTimer *_release[3];
    // What iOS reported for the gesture in progress, for the log: sizes and
    // times only (when the first movement came and how large its steps were).
    struct { BOOL active; NSTimeInterval began, firstMove, last; CGPoint origin, previous; double reach, steps[6]; unsigned count, peak; } _trace;
    unsigned _traceReports;
}

static const NSTimeInterval AKTouchClickTime = 0.06;
- (void)flushReleases {
    for (unsigned button = 0; button < 3; button++) {
        if (!_release[button]) continue;
        [_release[button] invalidate]; _release[button] = nil;
        [self.delegate touchButton:button pressed:NO];
    }
}
- (void)button:(unsigned)button pressed:(BOOL)pressed {
    if (button > 2) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime, held = now - _pressedAt[button];
    if (pressed || held >= AKTouchClickTime) {
        [self flushReleases];
        if (pressed) _pressedAt[button] = now;
        [self.delegate touchButton:button pressed:pressed];
        return;
    }
    if (_release[button]) return;
    __weak AKTouchControls *weakSelf = self;
    _release[button] = [NSTimer timerWithTimeInterval:AKTouchClickTime - held repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        AKTouchControls *controls = weakSelf;
        if (!controls || !controls->_release[button]) return;
        controls->_release[button] = nil;
        [controls.delegate touchButton:button pressed:NO];
    }];
    [NSRunLoop.mainRunLoop addTimer:_release[button] forMode:NSRunLoopCommonModes];
}

static void AKEmitTouch(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    AKTouchControls *controls = (__bridge AKTouchControls *)context;
    switch (action) {
        // A click still waiting for its release ends before the pointer moves on.
        case AKTrackpadMove: [controls flushReleases]; [controls.delegate touchMoveBy:CGPointMake(x, y)]; break;
        case AKTrackpadScroll: [controls flushReleases]; [controls.delegate touchScrollBy:CGPointMake(x, y)]; break;
        case AKTrackpadDown: [controls button:button pressed:YES]; break;
        case AKTrackpadUp: [controls button:button pressed:NO]; break;
        case AKTrackpadPoint: [controls flushReleases]; [controls.delegate touchPointAt:CGPointMake(x, y)]; break;
    }
}

// macOS key codes and characters of a US keyboard's W, A, S and D.
static void AKEmitStick(void *context, unsigned direction, bool pressed) {
    AKTouchControls *controls = (__bridge AKTouchControls *)context;
    unsigned short code = direction == AKStickUp ? 13 : direction == AKStickLeft ? 0 : direction == AKStickDown ? 1 : 2;
    NSString *characters = direction == AKStickUp ? @"w" : direction == AKStickLeft ? @"a" : direction == AKStickDown ? @"s" : @"d";
    [controls.delegate touchKey:code characters:characters pressed:pressed];
}

// Buttons that hold a key while touched, by tag: macOS key codes of a US
// keyboard's 1 to 9 and 0, then Space (Jump), Escape and Tab.
static const unsigned short AKQuickKeyCodes[] = {18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 49, 53, 48};
enum { AKJumpTag = 10, AKEscapeTag, AKTabTag, AKShiftTag };
static NSString *AKQuickKeyCharacters(NSInteger index) {
    if (index >= AKJumpTag) return @[@" ", @"\x1b", @"\t"][index - AKJumpTag];
    return [NSString stringWithFormat:@"%ld", (long)(index + 1) % 10];
}

+ (BOOL)enabled {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchControlsDefaultsKey];
    return [saved isKindOfClass:NSNumber.class] ? saved.boolValue :
        UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];
    button.layer.cornerRadius = 22;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.4].CGColor;
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}

- (UIButton *)heldKeyButtonWithSymbol:(NSString *)symbol label:(NSString *)label tag:(NSInteger)tag {
    UIButton *button = [self buttonWithSymbol:symbol label:label action:@selector(quickKeyUp:)];
    button.tag = tag;
    [button addTarget:self action:@selector(quickKeyDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(quickKeyUp:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.zPosition = 100001;
        _ignoredTouches = [NSHashTable weakObjectsHashTable];
        _stickButton = [self buttonWithSymbol:@"dpad" label:@"Enable movement stick" action:@selector(toggleStick)];
        _stickButton.accessibilityIdentifier = @"tolkara.stick";
        _stickButton.accessibilityHint = @"A touch on the left half becomes a stick for W, A, S and D; the right half is the trackpad.";
        _keyboardButton = [self buttonWithSymbol:@"keyboard" label:@"Show keyboard" action:@selector(toggleKeyboard)];
        _keyboardButton.accessibilityIdentifier = @"tolkara.keyboard";
        const char *mode = getenv("TOLKARA_TOUCH_MODE");
        _cameraProfile = mode && !strcmp(mode, "camera");
        _trackpadButton = [self buttonWithSymbol:@"hand.draw" label:@"Enable touch trackpad" action:@selector(toggleTrackpad)];
        _trackpadButton.accessibilityIdentifier = @"tolkara.trackpad";
        _trackpadButton.accessibilityHint = @"One finger moves the pointer; tap to click. Hold, then slide to drag with the left button. Double-tap and hold for the right button. Tap two fingers for right click. Two fingers scroll. Three fingers tap for middle click. Long-press this button for mouse buttons.";
        __weak AKTouchControls *weakSelf = self;
        NSMutableArray<UIAction *> *actions = [NSMutableArray new];
        NSArray<NSString *> *buttons = @[@"Left click", @"Right click", @"Middle click"];
        for (unsigned i = 0; i < buttons.count; i++) {
            [actions addObject:[UIAction actionWithTitle:buttons[i] image:nil identifier:nil handler:^(UIAction *action) {
                (void)action;
                AKTouchControls *controls = weakSelf;
                [controls cancelTouches];
                [controls.delegate touchButton:i pressed:YES];
                [controls.delegate touchButton:i pressed:NO];
            }]];
        }
        _trackpadButton.menu = [UIMenu menuWithTitle:@"Mouse buttons" children:actions];
        _stickButton.tag = _keyboardButton.tag = _trackpadButton.tag = -1;   // not key buttons
        // Keys 1 to 9 and 0 (a game's action slots), held while touched. Shown
        // only in the column layout, where the side strips have room for them.
        _sideStrip = CGRectNull;
        NSMutableArray<UIButton *> *quick = [NSMutableArray new];
        for (NSInteger i = 0; i < 10; i++) {
            NSString *key = AKQuickKeyCharacters(i);
            UIButton *button = [self heldKeyButtonWithSymbol:[key stringByAppendingString:@".circle"]
                                                       label:[@"Key " stringByAppendingString:key] tag:i];
            button.hidden = YES;
            button.accessibilityIdentifier = [@"tolkara.key" stringByAppendingString:key];
            [quick addObject:button];
        }
        _quickButtons = quick;
        _jumpButton = [self heldKeyButtonWithSymbol:@"arrow.up" label:@"Jump" tag:AKJumpTag];
        _jumpButton.accessibilityIdentifier = @"tolkara.jump";
        _jumpButton.accessibilityHint = @"Holds Space while touched.";
        // Escape and Tab (e.g. to select a target), in the column layout only.
        _escapeButton = [self heldKeyButtonWithSymbol:@"escape" label:@"Escape" tag:AKEscapeTag];
        _escapeButton.accessibilityIdentifier = @"tolkara.escape";
        _tabButton = [self heldKeyButtonWithSymbol:@"arrow.right.to.line" label:@"Tab" tag:AKTabTag];
        _tabButton.accessibilityIdentifier = @"tolkara.tab";
        // Shift, held while touched: with a drag it moves a spell on a locked
        // bar or splits a stack. In the column layout only.
        _shiftButton = [self heldKeyButtonWithSymbol:@"shift" label:@"Shift" tag:AKShiftTag];
        _shiftButton.accessibilityIdentifier = @"tolkara.shift";
        _shiftButton.accessibilityHint = @"Holds Shift while touched.";
        _escapeButton.hidden = _tabButton.hidden = _shiftButton.hidden = YES;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchTrackpadDefaultsKey];
        BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        // Camera mode needs the controls to take touches; it starts in camera
        // mode unless cursor mode was chosen last time.
        _cursorMode = !_cameraProfile || [NSUserDefaults.standardUserDefaults boolForKey:AKTouchCursorModeDefaultsKey];
        self.trackpadEnabled = _cameraProfile || (saved ? saved.boolValue : phone);
        NSNumber *savedStick = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchStickDefaultsKey];
        self.stickEnabled = self.trackpadEnabled && (savedStick ? savedStick.boolValue : phone);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendInput:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
        // iOS hides its keyboard while a hardware keyboard is connected (a
        // Bluetooth one, or a Mac's through Device Hub); log when that changes.
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hardwareKeyboardChanged:) name:GCKeyboardDidConnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hardwareKeyboardChanged:) name:GCKeyboardDidDisconnectNotification object:nil];
    }
    return self;
}

// The gaps between the buttons belong to the game.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    for (UIView *button in self.subviews)
        if ([button isKindOfClass:UIButton.class] && !button.hidden && CGRectContainsPoint(button.frame, point)) return YES;
    return NO;
}
- (BOOL)vertical { return !CGRectIsNull(_sideStrip); }
- (void)setSideStrip:(CGRect)strip {
    if (CGRectEqualToRect(_sideStrip, strip)) return;
    _sideStrip = strip;
    [self releaseQuickKeys];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.vertical) {
        for (UIView *button in self.subviews) button.layer.cornerRadius = 22;
        _jumpButton.frame = CGRectMake(0, 0, 44, 44);
        _stickButton.frame = CGRectMake(52, 0, 44, 44);
        _trackpadButton.frame = CGRectMake(104, 0, 44, 44);
        _keyboardButton.frame = CGRectMake(156, 0, 44, 44);
        for (UIButton *button in _quickButtons) button.hidden = YES;
        _escapeButton.hidden = _tabButton.hidden = _shiftButton.hidden = YES;
        [self quickKeyUp:_shiftButton];
        return;
    }
    // One column in the strip and one mirroring it, both from below the status
    // bar: on the right (wherever the strip is) Escape, Tab, 1 to 5 and Jump at
    // the bottom; on the left the keyboard, stick, trackpad, Shift and 6 to 0.
    CGRect strip = self.sideStrip;
    CGFloat stripCentre = CGRectGetMidX(strip), otherCentre = self.bounds.size.width - stripCentre;
    NSArray<UIButton *> *right = [[@[_escapeButton, _tabButton] arrayByAddingObjectsFromArray:[_quickButtons subarrayWithRange:NSMakeRange(0, 5)]]
                                  arrayByAddingObject:_jumpButton];
    NSArray<UIButton *> *left = [@[_keyboardButton, _stickButton, _trackpadButton, _shiftButton] arrayByAddingObjectsFromArray:[_quickButtons subarrayWithRange:NSMakeRange(5, 5)]];
    [self layoutColumn:right centre:MAX(stripCentre, otherCentre) top:strip.origin.y];
    [self layoutColumn:left centre:MIN(stripCentre, otherCentre) top:strip.origin.y];
}
// Top to bottom, shrunk (to 34 points) to fit; what still does not fit (above
// the iOS keyboard) is hidden from the bottom up, so the keyboard button stays.
- (void)layoutColumn:(NSArray<UIButton *> *)column centre:(CGFloat)centre top:(CGFloat)top {
    if (!column.count) return;
    CGFloat height = self.bounds.size.height - top;
    CGFloat pitch = MAX(40, MIN(52, floor((height + 6) / column.count))), size = MIN(44, pitch - 6);
    CGFloat x = floor(centre - size / 2), y = top;
    for (UIButton *button in column) {
        button.frame = CGRectMake(x, y, size, size);
        button.layer.cornerRadius = size / 2;
        BOOL fits = y + size <= self.bounds.size.height;
        if (!fits) [self quickKeyUp:button];
        button.hidden = !fits;
        y += pitch;
    }
}
- (void)setShiftHeld:(BOOL)held {
    if (_shiftHeld == held) return;
    _shiftHeld = held;
    _shiftButton.tintColor = held ? UIColor.systemCyanColor : UIColor.whiteColor;
    [self.delegate touchShift:held];
}
- (void)quickKeyDown:(UIButton *)button {
    if (button.tag == AKShiftTag) { [self setShiftHeld:YES]; return; }
    if (button.tag < 0 || button.tag > AKTabTag) return;
    unsigned bit = 1u << button.tag;
    if (_quickHeld & bit) return;
    _quickHeld |= bit;
    [self.delegate touchKey:AKQuickKeyCodes[button.tag] characters:AKQuickKeyCharacters(button.tag) pressed:YES];
}
- (void)quickKeyUp:(UIButton *)button {
    if (button.tag == AKShiftTag) { [self setShiftHeld:NO]; return; }
    if (button.tag < 0 || button.tag > AKTabTag) return;
    unsigned bit = 1u << button.tag;
    if (!(_quickHeld & bit)) return;
    _quickHeld &= ~bit;
    [self.delegate touchKey:AKQuickKeyCodes[button.tag] characters:AKQuickKeyCharacters(button.tag) pressed:NO];
}
- (void)releaseQuickKeys {
    for (UIButton *button in _quickButtons) [self quickKeyUp:button];
    for (UIButton *button in @[_jumpButton, _escapeButton, _tabButton, _shiftButton]) [self quickKeyUp:button];
}
- (void)setStickEnabled:(BOOL)enabled {
    [self cancelTouches];
    _stickEnabled = enabled;
    _stickButton.tintColor = enabled ? UIColor.systemCyanColor : UIColor.whiteColor;
    _stickButton.accessibilityLabel = enabled ? @"Disable movement stick" : @"Enable movement stick";
    _stickButton.accessibilityValue = enabled ? @"On" : @"Off";
    if (enabled && !self.trackpadEnabled) self.trackpadEnabled = YES;
}
- (void)toggleStick {
    self.stickEnabled = !self.stickEnabled;
    [NSUserDefaults.standardUserDefaults setBool:self.stickEnabled forKey:AKTouchStickDefaultsKey];
    [NSUserDefaults.standardUserDefaults setBool:self.trackpadEnabled forKey:AKTouchTrackpadDefaultsKey];
}
- (void)setTrackpadEnabled:(BOOL)enabled {
    [self cancelTouches];
    _trackpadEnabled = enabled;
    if (!enabled && self.stickEnabled) self.stickEnabled = NO;
    [self updateTrackpadButton];
    [self.delegate touchTrackpadChanged:enabled];
}
- (void)setCursorMode:(BOOL)cursorMode {
    [self cancelTouches];
    _cursorMode = cursorMode;
    [self updateTrackpadButton];
    // The host draws a pointer in cursor mode only.
    [self.delegate touchTrackpadChanged:self.trackpadEnabled];
}
// For a camera-mode game the hand button shows the mode: a camera while
// touches turn the camera, a cyan pointer in cursor mode.
- (void)updateTrackpadButton {
    if (_cameraProfile) {
        [_trackpadButton setImage:[UIImage systemImageNamed:_cursorMode ? @"cursorarrow" : @"rotate.3d"] forState:UIControlStateNormal];
        _trackpadButton.tintColor = _cursorMode ? UIColor.systemCyanColor : UIColor.whiteColor;
        _trackpadButton.accessibilityLabel = @"Cursor mode";
        _trackpadButton.accessibilityValue = _cursorMode ? @"On" : @"Off";
        _trackpadButton.accessibilityHint = _cursorMode ? @"One finger moves the pointer; tap to click. Turn off for camera mode." :
            @"Slide one finger to turn the camera; tap to right-click where you touch. Hold, then slide to drag with the left button. Two fingers scroll or tap to left-click. Turn on for a pointer.";
        return;
    }
    BOOL enabled = self.trackpadEnabled;
    _trackpadButton.tintColor = enabled ? UIColor.systemCyanColor : UIColor.whiteColor;
    _trackpadButton.accessibilityLabel = enabled ? @"Disable touch trackpad" : @"Enable touch trackpad";
    _trackpadButton.accessibilityValue = enabled ? @"On" : @"Off";
}
- (void)toggleTrackpad {
    if (_cameraProfile) {
        self.cursorMode = !self.cursorMode;
        if (!self.trackpadEnabled) self.trackpadEnabled = YES;
        [NSUserDefaults.standardUserDefaults setBool:self.cursorMode forKey:AKTouchCursorModeDefaultsKey];
        return;
    }
    self.trackpadEnabled = !self.trackpadEnabled;
    [NSUserDefaults.standardUserDefaults setBool:self.trackpadEnabled forKey:AKTouchTrackpadDefaultsKey];
    [NSUserDefaults.standardUserDefaults setBool:self.stickEnabled forKey:AKTouchStickDefaultsKey];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)keyboardVisible { return self.isFirstResponder; }
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    [self updateKeyboardButton];
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    [self updateKeyboardButton];
    return accepted;
}
- (void)updateKeyboardButton {
    [_keyboardButton setImage:[UIImage systemImageNamed:self.keyboardVisible ? @"keyboard.chevron.compact.down" : @"keyboard"] forState:UIControlStateNormal];
    _keyboardButton.accessibilityLabel = self.keyboardVisible ? @"Hide keyboard" : @"Show keyboard";
}
- (void)toggleKeyboard {
    [self cancelTouches];
    if (self.keyboardVisible) { [self dismissKeyboard]; return; }
    BOOL accepted = [self becomeFirstResponder];
    // Whether the keyboard itself appears is iOS's choice: with a hardware
    // keyboard connected it shows only the row above it. No text is logged.
    AKLog(@"software keyboard requested accepted=%d window_key=%d hardware_keyboard=%d",
          accepted, self.window.isKeyWindow, GCKeyboard.coalescedKeyboard != nil);
    __weak AKTouchControls *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 6 / 10), dispatch_get_main_queue(), ^{
        AKTouchControls *controls = weakSelf;
        if (controls) AKLog(@"software keyboard first_responder=%d height=%.0f", controls.isFirstResponder,
                            controls.superview.keyboardLayoutGuide.layoutFrame.size.height);
    });
}
- (void)dismissKeyboard {
    if (self.isFirstResponder) {
        [self resignFirstResponder];
        [(self.gameView ?: self.superview) becomeFirstResponder];
    }
}
// The guest owns the text and selection. Do not cache account/password text
// or claim knowledge of its editing range. Always allow a backspace request.
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text { [self.delegate touchInsertText:text]; }
- (void)deleteBackward { [self.delegate touchSpecialKey:51 characters:@"\x7f"]; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UITextSmartInsertDeleteType)smartInsertDeleteType { return UITextSmartInsertDeleteTypeNo; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDefault; }
- (BOOL)isSecureTextEntry { return YES; }

- (UIView *)inputAccessoryView {
    if (!_accessory) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        row.distribution = UIStackViewDistributionFillEqually;
        row.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
        NSArray<NSString *> *titles = @[@"Esc", @"Tab", @"←", @"→", @"↵", @"⌄"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = (NSInteger)i;
            button.tintColor = UIColor.whiteColor;
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.accessibilityLabel = @[@"Escape", @"Tab", @"Left arrow", @"Right arrow", @"Return", @"Hide keyboard"][i];
            [button addTarget:self action:@selector(accessoryKey:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:button];
        }
        _accessory = row;
    }
    return _accessory;
}
- (void)accessoryKey:(UIButton *)button {
    if (button.tag == 5) { [self dismissKeyboard]; return; }
    const unsigned short codes[] = {53, 48, 123, 124, 36};
    NSArray<NSString *> *characters = @[@"\x1b", @"\t", @"\uF702", @"\uF703", @"\r"];
    if (button.tag >= 0 && button.tag < 5) [self.delegate touchSpecialKey:codes[button.tag] characters:characters[button.tag]];
}

- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackpadEnabled) return;
    for (UITouch *touch in touches) if (touch.phase == UITouchPhaseCancelled) [self cancelTouches];
    // UIKit can report one event's touches to several handlers (began and
    // moved), so the same event may arrive twice; each step is idempotent.
    UIView *host = self.gameView ?: self.superview;
    unsigned count = 0;
    CGPoint center = CGPointZero;
    for (UITouch *touch in event.allTouches) {
        if (touch.type != UITouchTypeDirect || touch.view != host) continue;
        BOOL over = touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
        CGPoint point = [touch locationInView:host];
        if (touch == _stickTouch) {
            [self stickPhase:touch.phase at:point];
            if (over) _stickTouch = nil;
            continue;
        }
        if ([_ignoredTouches containsObject:touch]) {
            if (over) [_ignoredTouches removeObject:touch];
            continue;
        }
        if (over) continue;
        // Where a touch lands decides its half for the rest of its life.
        if (touch.phase == UITouchPhaseBegan && self.stickEnabled && point.x < host.bounds.size.width / 2) {
            if (_stickTouch) [_ignoredTouches addObject:touch];
            else { _stickTouch = touch; [self stickPhase:UITouchPhaseBegan at:point]; }
            continue;
        }
        center.x += point.x; center.y += point.y; count++;
    }
    if (count) { center.x /= count; center.y /= count; }
    [self padFingers:count at:center time:event.timestamp];
}
// One line per gesture for the first of a session: how long after landing
// iOS reported the first movement, how large that and the next steps were,
// and how far the gesture went. Sizes in points and times only.
- (void)traceFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time {
    if (_traceReports >= 300) return;
    if (!fingers) {
        if (!_trace.active) return;
        NSMutableString *steps = [NSMutableString new];
        for (unsigned i = 0; i < MIN(_trace.count, 6u); i++) [steps appendFormat:@"%s%.1f", i ? "," : "", _trace.steps[i]];
        _traceReports++;
        AKLog(@"touch gesture mode=%s fingers=%u ms=%.0f first_move_ms=%.0f steps=%u first=[%@] reach=%.0f",
              _cursorMode ? "cursor" : "camera", _trace.peak, (time - _trace.began) * 1000,
              _trace.count ? (_trace.firstMove - _trace.began) * 1000 : -1, _trace.count, steps, _trace.reach);
        _trace.active = NO;
        return;
    }
    if (!_trace.active) {
        memset(&_trace, 0, sizeof _trace);
        _trace.active = YES; _trace.began = time; _trace.origin = _trace.previous = center;
    }
    if (fingers != _trace.peak && fingers > _trace.peak) { _trace.peak = fingers; _trace.previous = center; return; }
    double step = hypot(center.x - _trace.previous.x, center.y - _trace.previous.y);
    _trace.previous = center;
    if (!(step > 0) || fingers != _trace.peak) return;
    if (!_trace.count) _trace.firstMove = time;
    if (_trace.count < 6) _trace.steps[_trace.count] = step;
    _trace.count++;
    _trace.reach = MAX(_trace.reach, hypot(center.x - _trace.origin.x, center.y - _trace.origin.y));
}
- (void)padFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time {
    [self traceFingers:fingers at:center time:time];
    [_holdTimer invalidate]; _holdTimer = nil;
    BOOL waiting;
    NSTimeInterval started;
    if (!_cursorMode) {
        if (!fingers && !_camera.fingers) return;
        // A camera drag presses the right button in the middle of the game.
        UIView *host = self.gameView ?: self.superview;
        _camera.anchored = host != nil;
        _camera.anchorX = host.bounds.size.width / 2; _camera.anchorY = host.bounds.size.height / 2;
        AKTouchCameraUpdate(&_camera, fingers, center.x, center.y, time, AKEmitTouch, (__bridge void *)self);
        waiting = _camera.fingers == 1 && _camera.peak == 1 && !_camera.blocked && !_camera.lifting && !_camera.pressed &&
                  !_camera.armed && _camera.reach <= AKTouchCameraSlop;
        started = _camera.started;
    } else {
        if (!fingers && !_pad.fingers && !_pad.dragging) return;
        AKTrackpadUpdate(&_pad, fingers, center.x, center.y, time, AKEmitTouch, (__bridge void *)self);
        waiting = _pad.fingers && !_pad.blocked && !_pad.lifting && !_pad.dragging && !_pad.armed && _pad.reach <= 8;
        started = _pad.started;
    }
    if (!waiting) return;
    // A touch still resting when the hold time is up: one finger is then
    // ready to drag with the left button, which a tick tells the hand.
    [_haptic prepare];
    __weak AKTouchControls *weakSelf = self;
    _holdTimer = [NSTimer timerWithTimeInterval:MAX(0.01, started + AKTouchHoldTime + 0.01 - NSProcessInfo.processInfo.systemUptime)
                                      repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        AKTouchControls *controls = weakSelf;
        if (!controls) return;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        BOOL armed = controls->_cursorMode ? AKTrackpadHold(&controls->_pad, now, AKEmitTouch, (__bridge void *)controls)
                                           : AKTouchCameraHold(&controls->_camera, now);
        if (armed) [controls->_haptic impactOccurred];
    }];
    [NSRunLoop.mainRunLoop addTimer:_holdTimer forMode:NSRunLoopCommonModes];
}
- (UIView *)stickCircle:(CGFloat)diameter alpha:(CGFloat)alpha {
    UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, diameter, diameter)];
    circle.userInteractionEnabled = NO;
    circle.hidden = YES;
    circle.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:alpha];
    circle.layer.cornerRadius = diameter / 2;
    circle.layer.borderWidth = 1;
    circle.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.5].CGColor;
    circle.layer.zPosition = 100001;
    return circle;
}
- (void)stickPhase:(UITouchPhase)phase at:(CGPoint)point {
    if (phase == UITouchPhaseBegan) AKStickBegin(&_stick, point.x, point.y);
    else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) AKStickEnd(&_stick, AKEmitStick, (__bridge void *)self);
    else AKStickMove(&_stick, point.x, point.y, AKEmitStick, (__bridge void *)self);
    [self drawStick];
}
// Drawn under the buttons where the finger landed; it never takes touches.
- (void)drawStick {
    if (!_stickBase) {
        _stickBase = [self stickCircle:2 * AKStickRadius alpha:0.25];
        _stickKnob = [self stickCircle:48 alpha:0.45];
    }
    // In the game's view and its coordinates, below these buttons.
    UIView *host = self.gameView ?: self.superview;
    if (_stickBase.superview != host) {
        if (self.superview == host) [host insertSubview:_stickBase belowSubview:self];
        else [host addSubview:_stickBase];
        [host insertSubview:_stickKnob aboveSubview:_stickBase];
    }
    _stickBase.hidden = _stickKnob.hidden = !_stick.active;
    if (!_stick.active) return;
    _stickBase.center = CGPointMake(_stick.originX, _stick.originY);
    _stickKnob.center = CGPointMake(_stick.x, _stick.y);
    _stickKnob.backgroundColor = _stick.directions ? [UIColor.systemCyanColor colorWithAlphaComponent:0.5] :
                                                     [UIColor.blackColor colorWithAlphaComponent:0.45];
}
- (void)cancelTouches {
    [_holdTimer invalidate]; _holdTimer = nil;
    AKTrackpadCancel(&_pad, AKEmitTouch, (__bridge void *)self);
    if (!_pad.fingers) _pad = (AKTrackpad){0};
    AKTouchCameraCancel(&_camera, AKEmitTouch, (__bridge void *)self);
    if (!_camera.fingers) _camera = (AKTouchCamera){0};
    // A stick touch that outlives a cancellation stays inert until lifted.
    if (_stickTouch) [_ignoredTouches addObject:_stickTouch];
    _stickTouch = nil;
    if (_stick.active) [self stickPhase:UITouchPhaseCancelled at:CGPointZero];
    [self flushReleases];
    _trace.active = NO;
}
- (void)hardwareKeyboardChanged:(NSNotification *)notification {
    AKLog(@"hardware keyboard %@ (any connected=%d)", [notification.name isEqual:GCKeyboardDidConnectNotification] ? @"connected" : @"disconnected",
          GCKeyboard.coalescedKeyboard != nil);
}
- (void)suspendInput:(NSNotification *)notification {
    if (self.keyboardVisible) AKLog(@"touch controls suspended reason=%@", notification ? notification.name : @"removed from window");
    [self cancelTouches];
    [self releaseQuickKeys];
    _pad = (AKTrackpad){0};
    _camera = (AKTouchCamera){0};
    [_ignoredTouches removeAllObjects];
    [self dismissKeyboard];
}
- (void)windowResigned:(NSNotification *)notification {
    if (notification.object == self.window) [self suspendInput:notification];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self suspendInput:nil];
}
- (void)dealloc {
    [_holdTimer invalidate];
    for (unsigned button = 0; button < 3; button++) [_release[button] invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
