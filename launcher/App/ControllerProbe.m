// A host-side view of the iPad's GameController framework, for diagnosing
// gamepad input in apps that run inside Tolkara.
//
// The framework is process-wide: a guest's gamepad code and Tolkara's own
// adapters talk to the same objects and notifications. This probe therefore
// answers both halves of the question — whether iPadOS delivers a controller
// to this process at all (the interactive Diagnostics check, and the startup
// summary), and what a guest asks the framework for (the class-method
// wrappers the startup form installs, which log the guest's own calls).
//
// Nothing here runs application code, and the startup form never registers a
// handler on a controller, so a game's own input handlers are untouched. The
// interactive form sets its own handlers and must not be used while a game is
// running: input handlers are single-assignment.
#import "ControllerProbe.h"
#import "Diagnostics.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdatomic.h>
#include <string.h>

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
    if (controller.gamepad) [profiles addObject:@"gamepad"];
    if (controller.microGamepad) [profiles addObject:@"microGamepad"];
    [text appendFormat:@"  profiles: %@\n", profiles.count ? [profiles componentsJoinedByString:@", "] : @"(none)"];
    NSArray<NSString *> *keys=physical.elements.allKeys;
    keys=[keys sortedArrayUsingSelector:@selector(compare:)];
    [text appendFormat:@"  elements (%lu): %@\n", (unsigned long)keys.count,
        keys.count ? [keys componentsJoinedByString:@", "] : @"(none)"];
    return text;
}

static NSString *TKControllerElementName(GCControllerElement *element, NSMapTable *names) {
    NSString *name=names ? [names objectForKey:element] : nil;
    if ([name length]) return name;
    return NSStringFromClass(element.class);
}

#pragma mark - Startup logging (no handlers, safe during a game)

static FILE *TKProbeLog;   // the native-guest.log FILE* for the life of the run
static _Atomic int TKControllersCalls, TKSupportsHIDCalls, TKCurrentCalls;
static NSArray<GCController *> *(*TKOriginalControllers)(id, SEL);
static BOOL (*TKOriginalSupportsHIDDevice)(id, SEL, void *);
static GCController *(*TKOriginalCurrent)(id, SEL);

// `caller` is the guest's (or the host's) return address, read in the method
// wrapper itself: __builtin_return_address(0) evaluated in this helper would
// name the wrapper instead.
static const char *TKProbeCaller(void *caller) {
    static char line[256];
    Dl_info info={0};
    if (dladdr(caller,&info) && info.dli_fname) {
        const char *base=strrchr(info.dli_fname,'/');
        snprintf(line,sizeof line,"%s+%#lx",base?base+1:info.dli_fname,
                 info.dli_fbase ? (unsigned long)((char *)caller-(char *)info.dli_fbase) : 0UL);
    } else {
        snprintf(line,sizeof line,"%p (outside any registered image)",caller);
    }
    return line;
}

// +[GCController controllers]: how a game's pad code asks the framework for
// its devices. The wrapper answers exactly as the real method does, and names
// the caller so the log can say whether the guest made the call.
static NSArray<GCController *> *TKProbedControllers(id self, SEL _cmd) {
    NSArray<GCController *> *controllers=TKOriginalControllers(self,_cmd);
    if (TKProbeLog && atomic_fetch_add(&TKControllersCalls,1)<40)
        fprintf(TKProbeLog,"[controller] +[GCController controllers] -> %lu controller(s), caller %s\n",
                (unsigned long)controllers.count,TKProbeCaller(__builtin_return_address(0)));
    return controllers;
}

// +[GCController supportsHIDDevice:]: SDL's macOS IOKit gamepad driver asks
// this for every HID device it enumerates, to leave GameController-supported
// pads to the GameController path.
static BOOL TKProbedSupportsHIDDevice(id self, SEL _cmd, void *device) {
    BOOL supported=TKOriginalSupportsHIDDevice(self,_cmd,device);
    if (TKProbeLog && atomic_fetch_add(&TKSupportsHIDCalls,1)<40)
        fprintf(TKProbeLog,"[controller] +[GCController supportsHIDDevice:%p] -> %s, caller %s\n",
                device,supported?"YES":"NO",TKProbeCaller(__builtin_return_address(0)));
    return supported;
}

// +[GCController current]: the pad the player last used, another way a game
// asks the framework for its controller.
static GCController *TKProbedCurrent(id self, SEL _cmd) {
    GCController *current=TKOriginalCurrent(self,_cmd);
    if (TKProbeLog && atomic_fetch_add(&TKCurrentCalls,1)<40)
        fprintf(TKProbeLog,"[controller] +[GCController current] -> %s, caller %s\n",
                (current.vendorName ?: @"(none)").UTF8String,TKProbeCaller(__builtin_return_address(0)));
    return current;
}

// The controller list through the saved original, so the probe's own looks
// never read as guest calls.
static NSArray<GCController *> *TKQueryControllers(void) {
    return TKOriginalControllers ? TKOriginalControllers((id)GCController.class,@selector(controllers))
                                 : GCController.controllers;
}

#pragma mark - Guest interaction audit

// The guest's gamepad code can only fail silently if nothing says which of it
// is running. These wrap the GameController setters a gamepad backend is known
// to use; a log line proves the guest found a controller object and started
// listening to it.
static NSMutableDictionary<NSString *,NSValue *> *TKSetterOriginals;
static void TKProbedSetter(id self, SEL _cmd, uintptr_t arg) {
    if (TKProbeLog) {
        static NSMutableDictionary<NSString *,NSNumber *> *seen;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen=[NSMutableDictionary new]; });
        NSString *key=[NSString stringWithFormat:@"%@@%@",NSStringFromClass(object_getClass(self)),NSStringFromSelector(_cmd)];
        @synchronized (seen) {
            NSUInteger count=seen[key].unsignedIntegerValue;
            if (count<3) {
                seen[key]=@(count+1);
                fprintf(TKProbeLog,"[controller] guest: -[%s %s]\n",NSStringFromClass(object_getClass(self)).UTF8String,
                        NSStringFromSelector(_cmd).UTF8String);
            }
        }
    }
    // A framework may hand out private subclasses; the original lives on the
    // class the setter was installed on, wherever in the hierarchy that is.
    void (*original)(id, SEL, uintptr_t)=NULL;
    @synchronized (TKSetterOriginals) {
        for (Class cls=object_getClass(self);cls&&!original;cls=class_getSuperclass(cls)) {
            NSValue *boxed=TKSetterOriginals[[NSString stringWithFormat:@"%p@%@",cls,NSStringFromSelector(_cmd)]];
            if (boxed) original=(void *)boxed.pointerValue;
        }
    }
    if (original) original(self,_cmd,arg);
}
static void TKSwizzleSetter(Class cls, SEL selector) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ TKSetterOriginals=[NSMutableDictionary new]; });
    NSString *key=[NSString stringWithFormat:@"%p@%@",cls,NSStringFromSelector(selector)];
    IMP previous=method_setImplementation(method,(IMP)TKProbedSetter);
    @synchronized (TKSetterOriginals) { TKSetterOriginals[key]=[NSValue valueWithPointer:previous]; }
}
static void TKInstallSetterAudit(void) {
    TKSwizzleSetter(GCController.class,@selector(setShouldMonitorBackgroundEvents:));
    TKSwizzleSetter(GCController.class,@selector(setControllerPausedHandler:));
    TKSwizzleSetter(GCController.class,@selector(setHandlerQueue:));
    for (Class cls in @[GCExtendedGamepad.class,GCGamepad.class,GCControllerButtonInput.class,
                        GCControllerAxisInput.class,GCControllerDirectionPad.class])
        TKSwizzleSetter(cls,@selector(setValueChangedHandler:));
}

void TKControllerProbeStartLogging(FILE *log) {
    if (!log) return;
    // This form rewires GameController methods in the process for the whole
    // run; without --trace-controllers (or Documents/trace-controllers) a game
    // run is left untouched. The Diagnostics check works either way.
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    if (![arguments containsObject:@"--trace-controllers"] &&
        ![NSFileManager.defaultManager fileExistsAtPath:TKDocumentsPath(@"trace-controllers")]) return;
    TKProbeLog=log;
    fflush(stdout); fflush(stderr);

    Method controllers=class_getClassMethod(GCController.class,@selector(controllers));
    if (controllers) TKOriginalControllers=(void *)method_setImplementation(controllers,(IMP)TKProbedControllers);
    Method supportsHID=class_getClassMethod(GCController.class,@selector(supportsHIDDevice:));
    if (supportsHID) TKOriginalSupportsHIDDevice=(void *)method_setImplementation(supportsHID,(IMP)TKProbedSupportsHIDDevice);
    Method current=class_getClassMethod(GCController.class,@selector(current));
    if (current) TKOriginalCurrent=(void *)method_setImplementation(current,(IMP)TKProbedCurrent);
    TKInstallSetterAudit();

    // Query through the saved originals so the probe's own look does not read
    // as a guest call in the log.
    NSArray<GCController *> *controllers0=TKOriginalControllers
        ? TKOriginalControllers((id)GCController.class,@selector(controllers)) : GCController.controllers;
    fprintf(log,"[controller] host probe: %lu controller(s); GCMouse %lu; GCKeyboard %s\n",
            (unsigned long)controllers0.count,(unsigned long)GCMouse.mice.count,GCKeyboard.coalescedKeyboard?"present":"none");
    for (GCController *controller in controllers0)
        fprintf(log,"[controller] connected:\n%s",TKControllerDescription(controller).UTF8String);

    // Every change while the game runs is evidence of delivery, whichever way
    // the game gets it.
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        if (TKProbeLog && [note.object isKindOfClass:GCController.class])
            fprintf(TKProbeLog,"[controller] did connect:\n%s",TKControllerDescription(note.object).UTF8String);
    }];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        if (TKProbeLog && [note.object isKindOfClass:GCController.class])
            fprintf(TKProbeLog,"[controller] did disconnect: %s\n",
                    ([(GCController *)note.object vendorName]?:@"(unnamed)").UTF8String);
    }];
    fflush(log);

    // The list can come and go while the game starts (the system's controller
    // session settles after launch). Record when it changes for six minutes,
    // so a game that initialized its gamepad support in a gap can be told
    // apart from one that never saw a controller. Queried through the saved
    // original, so the probe's own polling stays out of the guest-call log.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND,0), ^{
        NSInteger last=-1;
        for (int tick=0;tick<72;tick++) {
            NSArray<GCController *> *now=TKQueryControllers();
            if ((NSInteger)now.count!=last || tick%6==0) {
                last=(NSInteger)now.count;
                if (TKProbeLog) fprintf(TKProbeLog,"[controller] count=%ld (t=%ds)\n",(long)last,tick*5);
            }
            [NSThread sleepForTimeInterval:5.0];
        }
    });
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

NSString *TKControllerProbeReport(void) {
    const NSTimeInterval seconds=10;
    NSMutableString *report=[NSMutableString string];
    [report appendString:@"Game controller check — the iPad's GameController framework, as Tolkara sees it.\n\n"];
    [report appendFormat:@"shouldMonitorBackgroundEvents: %@\n", GCController.shouldMonitorBackgroundEvents?@"YES":@"NO"];

    NSMutableArray<NSString *> *order=[NSMutableArray new];
    NSMutableDictionary<NSString *,NSString *> *values=[NSMutableDictionary new];
    NSMapTable<GCControllerElement *,NSString *> *names=[NSMapTable strongToStrongObjectsMapTable];
    NSMutableSet<GCController *> *attached=[NSMutableSet new];
    NSMutableArray<NSString *> *events=[NSMutableArray new];
    NSMutableArray<NSString *> *timeline=[NSMutableArray new];

    // Input handlers are single-assignment: attach exactly once per controller.
    __block void (^attach)(GCController *);
    attach=^(GCController *controller) {
        @synchronized (attached) {
            if ([attached containsObject:controller]) return;
            [attached addObject:controller];
        }
        GCPhysicalInputProfile *profile=controller.physicalInputProfile;
        for (NSString *key in profile.elements) [names setObject:key forKey:profile.elements[key]];
        if ([profile respondsToSelector:NSSelectorFromString(@"setValueDidChangeHandler:")]) {
            profile.valueDidChangeHandler=^(GCPhysicalInputProfile *changed, GCControllerElement *element) {
                TKRecordChange(order,values,TKControllerElementName(element,names),element);
            };
        } else if (controller.extendedGamepad) {
            controller.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *changed, GCControllerElement *element) {
                TKRecordChange(order,values,TKControllerElementName(element,names),element);
            };
        } else if (controller.gamepad) {
            controller.gamepad.valueChangedHandler=^(GCGamepad *changed, GCControllerElement *element) {
                TKRecordChange(order,values,TKControllerElementName(element,names),element);
            };
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
        NSString *name=[note.object isKindOfClass:GCController.class] ? [(GCController *)note.object vendorName] : nil;
        @synchronized (events) { [events addObject:[NSString stringWithFormat:@"did disconnect: %@", name ?: @"?"]]; }
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

    [report appendFormat:@"Controllers at check start: %lu\n", (unsigned long)initial.count];
    [report appendFormat:@"Press buttons and move the sticks for %d seconds…\n\n", (int)seconds];
    NSDate *start=[NSDate date];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    NSUInteger lastCount=(NSUInteger)-1;
    NSDate *lastLine=[NSDate distantPast];
    while (deadline.timeIntervalSinceNow>0) {
        @autoreleasepool {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
        NSArray<GCController *> *now=GCController.controllers;
        for (GCController *controller in now) attach(controller);
        if (now.count!=lastCount || -[lastLine timeIntervalSinceNow]>=2.0) {
            lastCount=now.count;
            lastLine=[NSDate date];
            @synchronized (timeline) {
                [timeline addObject:[NSString stringWithFormat:@"t=%4.1fs controllers=%lu",
                    -[start timeIntervalSinceNow], (unsigned long)now.count]];
            }
        }
    }
    for (GCController *controller in attached) {
        if ([controller.physicalInputProfile respondsToSelector:NSSelectorFromString(@"setValueDidChangeHandler:")])
            controller.physicalInputProfile.valueDidChangeHandler=nil;
    }
    [center removeObserver:connectObserver];
    [center removeObserver:disconnectObserver];

    NSArray<GCController *> *final=GCController.controllers;
    [report appendFormat:@"Controllers at check end: %lu\n\n", (unsigned long)final.count];
    @synchronized (timeline) {
        [report appendString:@"Controller count over the check:\n"];
        for (NSString *line in timeline) [report appendFormat:@"  %@\n", line];
    }
    @synchronized (events) {
        [report appendString:@"\nFramework events:\n"];
        if (events.count) for (NSString *line in events) [report appendFormat:@"  %@\n", line];
        else [report appendString:@"  (none)\n"];
    }
    if (final.count || GCController.controllers.count) {
        [report appendString:@"\n"];
        NSUInteger number=0;
        for (GCController *controller in GCController.controllers)
            [report appendFormat:@"Controller %lu:\n%@\n", (unsigned long)++number, TKControllerDescription(controller)];
    }
    @synchronized (values) {
        [report appendString:@"\n"];
        if (order.count) {
            [report appendFormat:@"Input reached the app (%lu element(s) changed):\n", (unsigned long)order.count];
            for (NSString *name in order) [report appendFormat:@"  %@\n", values[name]];
        } else {
            [report appendString:@"No input from any controller reached the app.\n"
                                "If the framework listed a controller above, its input is not being delivered;\n"
                                "if it listed none, the controller is not delivered to apps (check Settings > Bluetooth).\n"];
        }
    }
    [report writeToFile:TKDocumentsPath(@"controller-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return report;
}
