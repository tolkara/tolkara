// A host-side view of the iPad's GameController framework, for diagnosing
// gamepad input in apps that run inside Tolkara.
//
// The framework is process-wide: a guest's gamepad code and Tolkara's own
// adapters talk to the same objects and notifications. This probe answers
// whether iPadOS delivers a controller to this process at all: interactively
// (the Diagnostics check) and, for a game run, as a trace of what the
// framework lists and announces.
//
// Nothing here runs application code. The trace only reads the framework and
// listens to its notifications: it replaces no method and sets no handler, so
// it cannot change what a game receives. The interactive check does set its
// own input handler on each controller, and puts back what it found.
#import "ControllerProbe.h"
#import "Diagnostics.h"
#import <GameController/GameController.h>
#include <stdatomic.h>

#pragma mark - Descriptions

// One line per fact, so the log is readable with or without a controller.
static NSString *TKControllerDescription(GCController *controller) {
    NSMutableString *text=[NSMutableString string];
    [text appendFormat:@"  name: %@\n", controller.vendorName.length ? controller.vendorName : @"(unnamed)"];
    [text appendFormat:@"  category: %@\n", controller.productCategory.length ? controller.productCategory : @"(none)"];
    [text appendFormat:@"  playerIndex: %ld\n", (long)controller.playerIndex];
    [text appendFormat:@"  attached to device: %@\n", controller.isAttachedToDevice ? @"yes" : @"no"];
    NSMutableArray<NSString *> *profiles=[NSMutableArray new];
    GCPhysicalInputProfile *physical=controller.physicalInputProfile;
    if (physical) [profiles addObject:@"physicalInputProfile"];
    if (controller.extendedGamepad) [profiles addObject:@"extendedGamepad"];
    if (controller.microGamepad) [profiles addObject:@"microGamepad"];
    [text appendFormat:@"  profiles: %@\n", profiles.count ? [profiles componentsJoinedByString:@", "] : @"(none)"];
    NSArray<NSString *> *keys=physical.elements.allKeys;
    keys=[keys sortedArrayUsingSelector:@selector(compare:)];
    [text appendFormat:@"  elements (%lu): %@\n", (unsigned long)keys.count,
        keys.count ? [keys componentsJoinedByString:@", "] : @"(none)"];
    return text;
}

static NSString *TKControllerName(id object) {
    NSString *name=[object isKindOfClass:GCController.class] ? [(GCController *)object vendorName] : nil;
    return name.length ? name : @"(unnamed)";
}

#pragma mark - Trace of a game run (observation only)

// The log of the current run, or NULL when this run did not ask for the
// trace. The observers below live as long as the process and read it afresh
// for every line, on whichever thread the framework posts from.
static _Atomic(FILE *) TKTraceLog;

static void TKTraceEvent(const char *event, NSNotification *note) {
    FILE *log=atomic_load(&TKTraceLog);
    if (!log) return;
    BOOL controller=[note.object isKindOfClass:GCController.class];
    fprintf(log,"[controller] %s: %s; the framework lists %lu controller(s)\n",event,
            TKControllerName(note.object).UTF8String,(unsigned long)GCController.controllers.count);
    if (controller && !strcmp(event,"did connect")) fprintf(log,"%s",TKControllerDescription(note.object).UTF8String);
    fflush(log);
}

void TKControllerProbeStartLogging(FILE *log) {
    BOOL requested=log && ([NSProcessInfo.processInfo.arguments containsObject:@"--trace-controllers"] ||
        [NSFileManager.defaultManager fileExistsAtPath:TKDocumentsPath(@"trace-controllers")]);
    // A process can start more than one run (a start that stopped early, then
    // another): each call moves the output, or ends it for a run without the
    // trace. The earlier run's log is not written to again.
    atomic_store(&TKTraceLog,requested ? log : NULL);
    if (!requested) return;

    // Once per process, however many runs ask: a second set of observers
    // would print every event twice.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        [center addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                        usingBlock:^(NSNotification *note) { TKTraceEvent("did connect",note); }];
        [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                        usingBlock:^(NSNotification *note) { TKTraceEvent("did disconnect",note); }];
        // The framework names a controller current when the player uses it:
        // evidence that its input arrives, without listening to it ourselves.
        [center addObserverForName:GCControllerDidBecomeCurrentNotification object:nil queue:nil
                        usingBlock:^(NSNotification *note) { TKTraceEvent("did become current",note); }];
    });

    NSArray<GCController *> *controllers=GCController.controllers;
    fprintf(log,"[controller] trace (--trace-controllers): the framework lists %lu controller(s); GCMouse %lu; GCKeyboard %s\n",
            (unsigned long)controllers.count,(unsigned long)GCMouse.mice.count,GCKeyboard.coalescedKeyboard?"present":"none");
    for (GCController *controller in controllers)
        fprintf(log,"[controller] listed:\n%s",TKControllerDescription(controller).UTF8String);
    fflush(log);
}

#pragma mark - Interactive check (Diagnostics)

// One value per element: the last one wins; order of first change is kept.
static void TKRecordChange(NSMutableArray<NSString *> *order, NSMutableDictionary<NSString *,NSString *> *values,
                           NSString *name, GCControllerElement *element) {
    // Only buttons and axes carry a scalar value; a direction pad reports
    // through its own axes, which arrive as separate elements.
    float value=0;
    if ([element isKindOfClass:GCControllerButtonInput.class]) value=((GCControllerButtonInput *)element).value;
    else if ([element isKindOfClass:GCControllerAxisInput.class]) value=((GCControllerAxisInput *)element).value;
    @synchronized(values) {
        if (!values[name]) [order addObject:name];
        values[name]=[NSString stringWithFormat:@"%@ = %.3f (%@)",name,value,NSStringFromClass(element.class)];
    }
}

// A handler the check put on a controller, and the one that was there.
@interface TKControllerProbeHandler : NSObject
@property(nonatomic, strong) GCPhysicalInputProfile *profile;
@property(nonatomic, copy) id ours;
@property(nonatomic, copy, nullable) id previous;
@end
@implementation TKControllerProbeHandler
@end

void TKControllerProbeRun(NSTimeInterval seconds, void (^report)(NSString *text, BOOL finished)) {
    static BOOL running;   // main thread only
    if (running) { report(@"A controller check is already running.",YES); return; }
    running=YES;

    NSMutableString *text=[NSMutableString string];
    [text appendString:@"Game controller check — the iPad's GameController framework, as Tolkara sees it.\n\n"];
    [text appendFormat:@"shouldMonitorBackgroundEvents: %@\n", GCController.shouldMonitorBackgroundEvents?@"YES":@"NO"];

    NSMutableArray<NSString *> *order=[NSMutableArray new];
    NSMutableDictionary<NSString *,NSString *> *values=[NSMutableDictionary new];
    NSMutableArray<TKControllerProbeHandler *> *handlers=[NSMutableArray new];
    NSMutableArray<NSString *> *events=[NSMutableArray new];
    NSMutableArray<NSString *> *timeline=[NSMutableArray new];

    // A controller's profile has one input handler: set ours once per
    // controller, and remember what it replaces.
    void (^attach)(GCController *)=^(GCController *controller) {
        GCPhysicalInputProfile *profile=controller.physicalInputProfile;
        if (!profile) return;
        @synchronized (handlers) {
            for (TKControllerProbeHandler *handler in handlers) if (handler.profile==profile) return;
            NSMapTable<GCControllerElement *,NSString *> *names=[NSMapTable strongToStrongObjectsMapTable];
            for (NSString *key in profile.elements) [names setObject:key forKey:profile.elements[key]];
            TKControllerProbeHandler *handler=[TKControllerProbeHandler new];
            handler.profile=profile;
            handler.previous=profile.valueDidChangeHandler;
            handler.ours=^(GCPhysicalInputProfile *changed, GCControllerElement *element) {
                (void)changed;
                NSString *name=[names objectForKey:element];
                TKRecordChange(order,values,name.length ? name : NSStringFromClass(element.class),element);
            };
            profile.valueDidChangeHandler=handler.ours;
            [handlers addObject:handler];
        }
    };

    // A controller connected before the app launched can be missing from
    // +controllers on some systems; connect notifications still arrive, so
    // watch for them for the whole window instead of only reading the list once.
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    id connectObserver=[center addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                                        usingBlock:^(NSNotification *note) {
        GCController *controller=[note.object isKindOfClass:GCController.class] ? note.object : nil;
        @synchronized (events) {
            [events addObject:[NSString stringWithFormat:@"did connect: %@ (%@)",
                controller.vendorName ?: @"?", controller.productCategory ?: @"?"]];
        }
        if (controller) attach(controller);
    }];
    id disconnectObserver=[center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                                           usingBlock:^(NSNotification *note) {
        @synchronized (events) { [events addObject:[NSString stringWithFormat:@"did disconnect: %@",TKControllerName(note.object)]]; }
    }];

    NSArray<GCController *> *initial=GCController.controllers;
    for (GCController *controller in initial) attach(controller);
    // Ask the framework to look for wireless controllers. On some systems the
    // list stays empty until this has run once.
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:^{
        @synchronized (events) {
            [events addObject:[NSString stringWithFormat:@"wireless discovery finished (controllers now %lu)",
                (unsigned long)GCController.controllers.count]];
        }
    }];

    [text appendFormat:@"Controllers at check start: %lu\n", (unsigned long)initial.count];
    [text appendFormat:@"Press buttons and move the sticks for %d seconds…\n\n", (int)seconds];
    report([text copy],NO);

    // Watched from a timer, so the main run loop is never nested: the screen
    // stays live, and nothing else that runs meanwhile is inside this check.
    NSDate *start=[NSDate date];
    __block NSUInteger lastCount=NSUIntegerMax;
    __block NSDate *lastLine=[NSDate distantPast];
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tick) {
        NSArray<GCController *> *now=GCController.controllers;
        NSTimeInterval elapsed=-[start timeIntervalSinceNow];
        if (elapsed<seconds) {
            for (GCController *controller in now) attach(controller);
            if (now.count!=lastCount || -[lastLine timeIntervalSinceNow]>=2.0) {
                lastCount=now.count;
                lastLine=[NSDate date];
                [timeline addObject:[NSString stringWithFormat:@"t=%4.1fs controllers=%lu",elapsed,(unsigned long)now.count]];
            }
            return;
        }
        [tick invalidate];
        [GCController stopWirelessControllerDiscovery];
        [center removeObserver:connectObserver];
        [center removeObserver:disconnectObserver];
        // Put back what each controller had. One whose handler is no longer
        // ours was given another meanwhile, and keeps it.
        @synchronized (handlers) {
            for (TKControllerProbeHandler *handler in handlers)
                if ((id)handler.profile.valueDidChangeHandler==handler.ours) handler.profile.valueDidChangeHandler=handler.previous;
            [handlers removeAllObjects];
        }

        [text appendFormat:@"Controllers at check end: %lu\n\n", (unsigned long)now.count];
        [text appendString:@"Controller count over the check:\n"];
        for (NSString *line in timeline) [text appendFormat:@"  %@\n", line];
        @synchronized (events) {
            [text appendString:@"\nFramework events:\n"];
            if (events.count) for (NSString *line in events) [text appendFormat:@"  %@\n", line];
            else [text appendString:@"  (none)\n"];
        }
        NSUInteger number=0;
        for (GCController *controller in now)
            [text appendFormat:@"\nController %lu:\n%@", (unsigned long)++number, TKControllerDescription(controller)];
        @synchronized (values) {
            [text appendString:@"\n"];
            if (order.count) {
                [text appendFormat:@"Input reached the app (%lu element(s) changed):\n", (unsigned long)order.count];
                for (NSString *name in order) [text appendFormat:@"  %@\n", values[name]];
            } else {
                [text appendString:@"No input from any controller reached the app.\n"
                                    "If the framework listed a controller above, its input is not being delivered;\n"
                                    "if it listed none, the controller is not delivered to apps (check Settings > Bluetooth).\n"];
            }
        }
        [text writeToFile:TKDocumentsPath(@"controller-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        running=NO;
        report([text copy],YES);
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
