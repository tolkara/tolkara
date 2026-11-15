#import "AppKit.h"
#import <dlfcn.h>
// Alert configuration is a desktop model and may be built on a worker thread.
// Only presentation creates UIKit objects, always on the main thread.
@interface AKAlertButton : AKStubObject
@property(copy) NSString *title, *keyEquivalent;
@property BOOL enabled;
@end
@implementation AKAlertButton
@end
@interface NSAlert : AKStubObject
@property(copy) NSString *messageText, *informativeText;
@property NSUInteger alertStyle;
@property(readonly) NSArray *buttons;
- (id)addButtonWithTitle:(NSString *)title;
- (NSInteger)runModal;
@end
@implementation NSAlert { NSMutableArray<AKAlertButton *> *_buttons; }
- (instancetype)init { if((self=[super init])) _buttons=[NSMutableArray new]; return self; }
- (NSArray *)buttons { return _buttons; }
- (id)addButtonWithTitle:(NSString *)title { AKAlertButton *button=[AKAlertButton new]; button.title=title; button.enabled=YES; [_buttons addObject:button]; return button; }
- (NSInteger)runModal {
    AKLog(@"guest alert: %@ — %@",self.messageText,self.informativeText);
    if(!_buttons.count) [self addButtonWithTitle:@"OK"];
    NSArray *buttons=[_buttons copy]; NSString *title=[self.messageText copy],*message=[self.informativeText copy];
    dispatch_semaphore_t completion=dispatch_semaphore_create(0);
    __block NSInteger result=-1001; // NSModalResponseAbort
    __block BOOL finished=NO;
    void (^present)(void)=^{
        UIViewController *presenter=nil;
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) if([scene isKindOfClass:UIWindowScene.class]) {
            for(UIWindow *window in ((UIWindowScene *)scene).windows) if(window.isKeyWindow) presenter=window.rootViewController;
        }
        while(presenter.presentedViewController) presenter=presenter.presentedViewController;
        if(!presenter) { finished=YES; dispatch_semaphore_signal(completion); return; }
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [buttons enumerateObjectsUsingBlock:^(AKAlertButton *button,NSUInteger index,BOOL *stop) {
            (void)stop;
            UIAlertAction *action=[UIAlertAction actionWithTitle:button.title style:UIAlertActionStyleDefault handler:^(UIAlertAction *selected) {
                (void)selected; result=1000+(NSInteger)index; finished=YES; dispatch_semaphore_signal(completion);
            }];
            action.enabled=button.enabled; [alert addAction:action];
        }];
        [presenter presentViewController:alert animated:YES completion:nil];
    };
    if(NSThread.isMainThread) {
        present(); while(!finished) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.1,true);
    } else {
        dispatch_async(dispatch_get_main_queue(),present);
        dispatch_semaphore_wait(completion,DISPATCH_TIME_FOREVER);
    }
    return result;
}
@end

#pragma mark - CFUserNotification

// CoreFoundation's user notification: a dialog the system shows for the
// process, with a header, a message, up to three buttons and optionally a
// progress bar, which the process updates and polls for a response. A game's
// first-run setup uses one for its progress (World of Warcraft, while it
// fetches the data it needs to start). iPadOS has the functions but refuses
// them to an app, which the game reads as the dialog being cancelled, so the
// runtime binds a guest's CFUserNotification imports to these instead
// (NativeGuest.m, hook). Shown as a UIKit alert over the current window.
typedef void (*AKUserNotificationCallBack)(CFTypeRef notification, CFOptionFlags responseFlags);
enum { AKUserNotificationDefaultResponse = 0, AKUserNotificationAlternateResponse = 1,
       AKUserNotificationOtherResponse = 2, AKUserNotificationCancelResponse = 3 };
// What CFUserNotificationReceiveResponse returns when its timeout passes: MACH_RCV_TIMED_OUT.
static const SInt32 AKUserNotificationTimedOut = 0x10004003;

// The dictionary's keys are CoreFoundation's constants where it has them.
static NSString *AKUserNotificationKey(const char *symbol, NSString *value) {
    CFStringRef *constant = dlsym(RTLD_DEFAULT, symbol);
    return constant && *constant ? (__bridge NSString *)*constant : value;
}

@interface AKUserNotification : NSObject
@property (copy) NSString *header, *message;
@property (copy) NSArray<NSString *> *buttons;   // default, alternate, other
@property NSNumber *progress;                     // nil without a progress bar
@property (readonly) BOOL responded, presented;
@property (readonly) CFOptionFlags response;
- (void)respond:(CFOptionFlags)response;
@end
@implementation AKUserNotification {
    dispatch_semaphore_t _answered;
    UIAlertController *_alert;
    UIProgressView *_bar;
    @public CFRunLoopSourceRef _source; CFRunLoopRef _loop; AKUserNotificationCallBack _callout; BOOL _delivered;
}
- (instancetype)init { if ((self = [super init])) _answered = dispatch_semaphore_create(0); return self; }
- (void)dealloc { if (_source) CFRelease(_source); }
- (void)read:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return;
    id (^text)(const char *, NSString *) = ^id(const char *symbol, NSString *name) {
        id value = dictionary[AKUserNotificationKey(symbol, name)];
        return [value isKindOfClass:NSString.class] ? value : nil;
    };
    self.header = text("kCFUserNotificationAlertHeaderKey", @"AlertHeader");
    self.message = text("kCFUserNotificationAlertMessageKey", @"AlertMessage");
    NSMutableArray *buttons = [NSMutableArray new];
    NSString *first = text("kCFUserNotificationDefaultButtonTitleKey", @"DefaultButtonTitle");
    [buttons addObject:first ?: @"OK"];
    NSString *second = text("kCFUserNotificationAlternateButtonTitleKey", @"AlternateButtonTitle");
    NSString *third = text("kCFUserNotificationOtherButtonTitleKey", @"OtherButtonTitle");
    if (second || third) [buttons addObject:second ?: @""];
    if (third) [buttons addObject:third];
    self.buttons = buttons;
    id progress = dictionary[AKUserNotificationKey("kCFUserNotificationProgressIndicatorValueKey", @"ProgressIndicatorValue")];
    self.progress = [progress isKindOfClass:NSNumber.class] ? progress : nil;
}
// The guest's thread may be the main one, in a loop of its own between
// updates: let UIKit present and draw before returning to it.
- (void)show {
    void (^show)(void) = ^{ [self showOnMain]; };
    if (NSThread.isMainThread) { show(); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true); [CATransaction flush]; }
    else dispatch_async(dispatch_get_main_queue(), show);
}
- (void)showOnMain {
    if (_responded) return;
    if (!_alert) {
        UIViewController *presenter = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) presenter = window.rootViewController;
        }
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        if (!presenter) return;   // tried again at the next update
        _alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleAlert];
        __weak AKUserNotification *weakSelf = self;
        [self.buttons enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
            (void)stop;
            if (!title.length) return;
            [self->_alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action; [weakSelf respond:index];
            }]];
        }];
        [presenter presentViewController:_alert animated:NO completion:nil];
        _presented = YES;
        AKLog(@"user notification shown: %lu button(s), progress=%d", (unsigned long)self.buttons.count, self.progress != nil);
    }
    _alert.title = self.header;
    // The bar stands under the message, in the alert's own view.
    _alert.message = self.progress ? [(self.message ?: @"") stringByAppendingString:@"\n\n"] : self.message;
    if (self.progress && !_bar) {
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        [_alert.view addSubview:_bar];
        [NSLayoutConstraint activateConstraints:@[
            [_bar.leadingAnchor constraintEqualToAnchor:_alert.view.leadingAnchor constant:20],
            [_bar.trailingAnchor constraintEqualToAnchor:_alert.view.trailingAnchor constant:-20],
            [_bar.bottomAnchor constraintEqualToAnchor:_alert.view.bottomAnchor constant:-64]]];
    }
    _bar.hidden = !self.progress;
    if (self.progress) _bar.progress = (float)MAX(0, MIN(1, self.progress.doubleValue));
}
- (void)dismiss {
    void (^dismiss)(void) = ^{
        UIAlertController *alert = self->_alert; self->_alert = nil; self->_bar = nil;
        [alert.presentingViewController dismissViewControllerAnimated:NO completion:nil];
    };
    if (NSThread.isMainThread) dismiss(); else dispatch_async(dispatch_get_main_queue(), dismiss);
}
- (void)respond:(CFOptionFlags)response {
    @synchronized (self) {
        if (_responded) return;
        _responded = YES; _response = response;
    }
    AKLog(@"user notification answered: response=%lu", (unsigned long)response);
    dispatch_semaphore_signal(_answered);
    [self dismiss];
    if (_source) { CFRunLoopSourceSignal(_source); if (_loop) CFRunLoopWakeUp(_loop); }
}
// 0 with the response once there is one; otherwise the timeout (0: none).
- (SInt32)receive:(CFOptionFlags *)response timeout:(CFTimeInterval)timeout {
    if (NSThread.isMainThread) {
        // UIKit needs this thread to show the alert and take the tap.
        CFAbsoluteTime end = timeout > 0 ? CFAbsoluteTimeGetCurrent() + timeout : INFINITY;
        while (!_responded && CFAbsoluteTimeGetCurrent() < end)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(0.05, MAX(0, end - CFAbsoluteTimeGetCurrent())), true);
    } else if (!_responded) {
        dispatch_semaphore_wait(_answered, timeout > 0 ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER);
        if (_responded) dispatch_semaphore_signal(_answered);   // a later call finds it too
    }
    if (!_responded) return AKUserNotificationTimedOut;
    if (response) *response = _response;
    return 0;
}
@end

CFTypeRef AKUserNotificationCreate(CFAllocatorRef allocator, CFTimeInterval timeout, CFOptionFlags flags, SInt32 *error, CFDictionaryRef dictionary) {
    (void)allocator;
    AKLog(@"user notification: create flags=0x%lx dictionary=%d", (unsigned long)flags, dictionary != NULL);
    AKUserNotification *notification = [AKUserNotification new];
    [notification read:(__bridge NSDictionary *)dictionary];
    AKLog(@"user notification created: header=%d message=%d progress=%d timeout=%.0f",
          notification.header != nil, notification.message != nil, notification.progress != nil, timeout);
    [notification show];
    // A notification with a timeout answers by itself when it passes, as the system's does.
    if (timeout > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [notification respond:AKUserNotificationCancelResponse];
    });
    if (error) *error = 0;
    return (__bridge_retained CFTypeRef)notification;
}
SInt32 AKUserNotificationUpdate(CFTypeRef reference, CFTimeInterval timeout, CFOptionFlags flags, CFDictionaryRef dictionary) {
    (void)timeout; (void)flags;
    AKUserNotification *notification = (__bridge AKUserNotification *)reference;
    if (![notification isKindOfClass:AKUserNotification.class]) return -1;
    [notification read:(__bridge NSDictionary *)dictionary];
    [notification show];
    return 0;
}
SInt32 AKUserNotificationCancel(CFTypeRef reference) {
    AKUserNotification *notification = (__bridge AKUserNotification *)reference;
    if (![notification isKindOfClass:AKUserNotification.class]) return -1;
    [notification respond:AKUserNotificationCancelResponse];
    return 0;
}
SInt32 AKUserNotificationReceiveResponse(CFTypeRef reference, CFTimeInterval timeout, CFOptionFlags *responseFlags) {
    AKUserNotification *notification = (__bridge AKUserNotification *)reference;
    if (![notification isKindOfClass:AKUserNotification.class]) return -1;
    return [notification receive:responseFlags timeout:timeout];
}
static void AKUserNotificationPerform(void *info) {
    AKUserNotification *notification = (__bridge AKUserNotification *)info;
    if (!notification.responded || notification->_delivered || !notification->_callout) return;
    notification->_delivered = YES;
    notification->_callout((__bridge CFTypeRef)notification, notification.response);
}
static void AKUserNotificationScheduled(void *info, CFRunLoopRef loop, CFRunLoopMode mode) {
    (void)mode;
    AKUserNotification *notification = (__bridge AKUserNotification *)info;
    notification->_loop = loop;
    if (notification.responded) { CFRunLoopSourceSignal(notification->_source); CFRunLoopWakeUp(loop); }
}
// The callout runs on the run loop the source is added to, once, with the response.
CFRunLoopSourceRef AKUserNotificationCreateRunLoopSource(CFAllocatorRef allocator, CFTypeRef reference, AKUserNotificationCallBack callout, CFIndex order) {
    AKUserNotification *notification = (__bridge AKUserNotification *)reference;
    if (reference && ![notification isKindOfClass:AKUserNotification.class]) {
        // Not one of ours: say what it is (its type only), for the log.
        CFStringRef type = CFCopyTypeIDDescription(CFGetTypeID(reference));
        AKLog(@"user notification: run loop source asked for a %@ (allocator=%p order=%ld)", (__bridge NSString *)type, allocator, (long)order);
        if (type) CFRelease(type);
    } else AKLog(@"user notification: run loop source for %@ callout=%d", [notification class], callout != NULL);
    if (![notification isKindOfClass:AKUserNotification.class] || !callout) return NULL;
    if (!notification->_source) {
        // The source does not retain the notification: the notification owns it.
        CFRunLoopSourceContext context = {0};
        context.info = (__bridge void *)notification;
        context.schedule = AKUserNotificationScheduled;
        context.perform = AKUserNotificationPerform;
        notification->_callout = callout;
        notification->_source = CFRunLoopSourceCreate(allocator, order, &context);
    }
    return notification->_source ? (CFRunLoopSourceRef)CFRetain(notification->_source) : NULL;
}
