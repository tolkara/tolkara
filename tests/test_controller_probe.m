// The controller probe without a physical controller: the game-run trace is
// installed once however many runs ask for it and writes only to the current
// run's log, and the Diagnostics check puts back the input handler it
// replaced, refuses to run twice at once and leaves a handler that something
// else set meanwhile. Uses the framework's own virtual controller.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import "ControllerProbe.h"
#import "Diagnostics.h"
#include <assert.h>

static NSString *documents;
NSString *TKDocumentsPath(NSString *name) { return [documents stringByAppendingPathComponent:name]; }

static NSUInteger Occurrences(NSString *path, NSString *needle) {
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    assert(text);
    return [text componentsSeparatedByString:needle].count-1;
}
static void Connect(GCController *controller) {
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:controller];
}
static void RunLoopFor(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void TestTrace(GCController *controller) {
    NSString *marker=TKDocumentsPath(@"trace-controllers");
    NSString *first=TKDocumentsPath(@"first.log"), *second=TKDocumentsPath(@"second.log"), *third=TKDocumentsPath(@"third.log");
    FILE *log1=fopen(first.fileSystemRepresentation,"w"), *log2=fopen(second.fileSystemRepresentation,"w"),
         *log3=fopen(third.fileSystemRepresentation,"w");
    assert(log1 && log2 && log3);

    // Not asked for: nothing is written and nothing listens.
    TKControllerProbeStartLogging(log1);
    Connect(controller);
    fflush(log1);
    assert(Occurrences(first,@"[controller]")==0);
    TKControllerProbeStartLogging(NULL);

    // Asked for, and started twice for the same run (a start that is retried):
    // one summary per start, and each event once.
    assert([@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    TKControllerProbeStartLogging(log1);
    TKControllerProbeStartLogging(log1);
    Connect(controller);
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:controller];
    fflush(log1);
    assert(Occurrences(first,@"[controller] trace (--trace-controllers)")==2);
    assert(Occurrences(first,@"[controller] did connect:")==1);
    assert(Occurrences(first,@"[controller] did disconnect:")==1);
    assert(Occurrences(first,@"  elements (")>=1);   // the connected controller is described

    // A second run in the same process: its events go to its own log only.
    TKControllerProbeStartLogging(log2);
    Connect(controller);
    fflush(log1); fflush(log2);
    assert(Occurrences(first,@"[controller] did connect:")==1);
    assert(Occurrences(second,@"[controller] did connect:")==1);

    // A later run without the trace: silent, though the observers remain.
    assert([NSFileManager.defaultManager removeItemAtPath:marker error:NULL]);
    TKControllerProbeStartLogging(log3);
    Connect(controller);
    fflush(log1); fflush(log2); fflush(log3);
    assert(Occurrences(first,@"[controller] did connect:")==1);
    assert(Occurrences(second,@"[controller] did connect:")==1);
    assert(Occurrences(third,@"[controller]")==0);
    fclose(log1); fclose(log2); fclose(log3);
}

static void TestCheck(GCController *controller, BOOL replaceMeanwhile) {
    GCPhysicalInputProfile *profile=controller.physicalInputProfile;
    __block int earlierCalls=0;
    void (^earlier)(GCPhysicalInputProfile *, GCControllerElement *)=^(GCPhysicalInputProfile *p, GCControllerElement *e) {
        (void)p; (void)e; earlierCalls++;
    };
    profile.valueDidChangeHandler=earlier;
    id found=profile.valueDidChangeHandler;

    __block NSString *result=nil;
    __block int progress=0;
    TKControllerProbeRun(0.6,^(NSString *text, BOOL finished) {
        assert(NSThread.isMainThread);
        if (finished) result=text; else progress++;
    });
    // Asynchronous: it has returned with the check still running.
    assert(progress==1 && !result);
    Connect(controller);
    assert((id)profile.valueDidChangeHandler!=found);   // the check listens now
    id ofCheck=profile.valueDidChangeHandler;
    Connect(controller);
    assert((id)profile.valueDidChangeHandler==ofCheck);   // set once per controller

    // A second start while one runs is refused and changes nothing.
    __block NSString *refused=nil;
    TKControllerProbeRun(0.6,^(NSString *text, BOOL finished) { assert(finished); refused=text; });
    assert([refused containsString:@"already running"]);
    assert((id)profile.valueDidChangeHandler==ofCheck);

    id meanwhile=nil;
    if (replaceMeanwhile) {
        profile.valueDidChangeHandler=^(GCPhysicalInputProfile *p, GCControllerElement *e) { (void)p; (void)e; };
        meanwhile=profile.valueDidChangeHandler;
    }
    RunLoopFor(1.5);
    assert(result);
    assert([result containsString:@"did connect:"]);
    assert([result isEqualToString:[NSString stringWithContentsOfFile:TKDocumentsPath(@"controller-probe.txt")
                                                             encoding:NSUTF8StringEncoding error:NULL]]);
    // What the controller had is back, or what replaced ours is kept.
    assert((id)profile.valueDidChangeHandler==(replaceMeanwhile ? meanwhile : found));
    // And the check can run again afterwards.
    __block BOOL again=NO;
    TKControllerProbeRun(0.1,^(NSString *text, BOOL finished) { (void)text; if (finished) again=YES; });
    RunLoopFor(0.8);
    assert(again);
    assert((id)profile.valueDidChangeHandler==(replaceMeanwhile ? meanwhile : found));
    profile.valueDidChangeHandler=nil;
    assert(earlierCalls==0);
}

int main(void) {
    @autoreleasepool {
        const char *temporary=getenv("TMPDIR");
        documents=[(temporary && *temporary ? @(temporary) : NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL]);
        GCController *controller=[GCController controllerWithExtendedGamepad];
        assert(controller && controller.physicalInputProfile);
        TestTrace(controller);
        TestCheck(controller,NO);
        TestCheck(controller,YES);
        [NSFileManager.defaultManager removeItemAtPath:documents error:NULL];
        puts("controller probe: ok");
    }
    return 0;
}
