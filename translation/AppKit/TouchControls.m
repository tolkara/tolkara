#import "TouchControls.h"
#import "TouchTrackpad.h"
#import "TouchStick.h"

NSString *const AKTouchControlsDefaultsKey = @"AKTouchControls";
static NSString *const AKTouchTrackpadDefaultsKey = @"AKTouchTrackpadEnabled";
static NSString *const AKTouchStickDefaultsKey = @"AKTouchStickEnabled";

@implementation AKTouchControls {
    UIButton *_keyboardButton, *_trackpadButton, *_stickButton;
    UIView *_accessory, *_stickBase, *_stickKnob;
    NSTimer *_holdTimer;
    AKTrackpad _pad;
    AKStick _stick;
    // UIKit keeps a touch's object for its lifetime. The stick's touch, and
    // left-half touches that arrive while it is held, never reach the trackpad.
    __weak UITouch *_stickTouch;
    NSHashTable<UITouch *> *_ignoredTouches;
}

static void AKEmitTouch(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    AKTouchControls *controls = (__bridge AKTouchControls *)context;
    switch (action) {
        case AKTrackpadMove: [controls.delegate touchMoveBy:CGPointMake(x, y)]; break;
        case AKTrackpadScroll: [controls.delegate touchScrollBy:CGPointMake(x, y)]; break;
        case AKTrackpadDown: [controls.delegate touchButton:button pressed:YES]; break;
        case AKTrackpadUp: [controls.delegate touchButton:button pressed:NO]; break;
    }
}

// macOS key codes and characters of a US keyboard's W, A, S and D.
static void AKEmitStick(void *context, unsigned direction, bool pressed) {
    AKTouchControls *controls = (__bridge AKTouchControls *)context;
    unsigned short code = direction == AKStickUp ? 13 : direction == AKStickLeft ? 0 : direction == AKStickDown ? 1 : 2;
    NSString *characters = direction == AKStickUp ? @"w" : direction == AKStickLeft ? @"a" : direction == AKStickDown ? @"s" : @"d";
    [controls.delegate touchKey:code characters:characters pressed:pressed];
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

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.zPosition = 100001;
        _ignoredTouches = [NSHashTable weakObjectsHashTable];
        _stickButton = [self buttonWithSymbol:@"dpad" label:@"Enable movement stick" action:@selector(toggleStick)];
        _stickButton.accessibilityIdentifier = @"tolkara.stick";
        _stickButton.accessibilityHint = @"A touch on the left half becomes a stick for W, A, S and D; the right half is the trackpad.";
        _keyboardButton = [self buttonWithSymbol:@"keyboard" label:@"Show keyboard" action:@selector(toggleKeyboard)];
        _keyboardButton.accessibilityIdentifier = @"tolkara.keyboard";
        _trackpadButton = [self buttonWithSymbol:@"hand.draw" label:@"Enable touch trackpad" action:@selector(toggleTrackpad)];
        _trackpadButton.accessibilityIdentifier = @"tolkara.trackpad";
        _trackpadButton.accessibilityHint = @"One finger moves the pointer; tap to click. Double-tap and hold to drag. Hold one finger or tap two for right click. Two fingers scroll. Three fingers tap for middle click. Long-press this button for mouse buttons.";
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
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchTrackpadDefaultsKey];
        BOOL phone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        self.trackpadEnabled = saved ? saved.boolValue : phone;
        NSNumber *savedStick = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchStickDefaultsKey];
        self.stickEnabled = self.trackpadEnabled && (savedStick ? savedStick.boolValue : phone);
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendInput:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
    }
    return self;
}

// The gaps between the buttons belong to the game.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return CGRectContainsPoint(_stickButton.frame, point) || CGRectContainsPoint(_trackpadButton.frame, point) ||
           CGRectContainsPoint(_keyboardButton.frame, point);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _stickButton.frame = CGRectMake(0, 0, 44, 44);
    _trackpadButton.frame = CGRectMake(52, 0, 44, 44);
    _keyboardButton.frame = CGRectMake(104, 0, 44, 44);
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
    _trackpadButton.tintColor = enabled ? UIColor.systemCyanColor : UIColor.whiteColor;
    _trackpadButton.accessibilityLabel = enabled ? @"Disable touch trackpad" : @"Enable touch trackpad";
    _trackpadButton.accessibilityValue = enabled ? @"On" : @"Off";
    [self.delegate touchTrackpadChanged:enabled];
}
- (void)toggleTrackpad {
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
    if (self.keyboardVisible) [self dismissKeyboard];
    else [self becomeFirstResponder];
}
- (void)dismissKeyboard {
    if (self.isFirstResponder) {
        [self resignFirstResponder];
        [self.superview becomeFirstResponder];
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
    UIView *host = self.superview;
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
- (void)padFingers:(unsigned)fingers at:(CGPoint)center time:(NSTimeInterval)time {
    if (!fingers && !_pad.fingers && !_pad.dragging) return;
    AKTrackpadUpdate(&_pad, fingers, center.x, center.y, time, AKEmitTouch, (__bridge void *)self);
    [_holdTimer invalidate]; _holdTimer = nil;
    if (_pad.fingers && !_pad.blocked && !_pad.lifting && !_pad.dragging && _pad.travelled <= 8) {
        __weak AKTouchControls *weakSelf = self;
        _holdTimer = [NSTimer timerWithTimeInterval:MAX(0.01, _pad.started + 0.46 - NSProcessInfo.processInfo.systemUptime)
                                          repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            AKTouchControls *controls = weakSelf;
            if (controls) AKTrackpadHold(&controls->_pad, NSProcessInfo.processInfo.systemUptime, AKEmitTouch, (__bridge void *)controls);
        }];
        [NSRunLoop.mainRunLoop addTimer:_holdTimer forMode:NSRunLoopCommonModes];
    }
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
    UIView *host = self.superview;
    if (_stickBase.superview != host) {
        [host insertSubview:_stickBase belowSubview:self];
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
    // A stick touch that outlives a cancellation stays inert until lifted.
    if (_stickTouch) [_ignoredTouches addObject:_stickTouch];
    _stickTouch = nil;
    if (_stick.active) [self stickPhase:UITouchPhaseCancelled at:CGPointZero];
}
- (void)suspendInput:(NSNotification *)notification {
    (void)notification;
    [self cancelTouches];
    _pad = (AKTrackpad){0};
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
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
