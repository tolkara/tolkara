#import "AKSupport.h"
#include <assert.h>
#include <stdatomic.h>
static atomic_uint destroyed, called;
@interface Capture : NSObject
- (void)use;
@end
@implementation Capture
- (void)use { atomic_fetch_add(&called,1); }
- (void)dealloc { atomic_fetch_add(&destroyed,1); }
@end
static size_t owner(uintptr_t pc) { (void)pc; return 0; }
int main(void) { @autoreleasepool {
    AKConfigureProcessCallbacks(4,owner);
    dispatch_queue_t queue=dispatch_queue_create("retirement-fixture",DISPATCH_QUEUE_SERIAL);
    __block unsigned synchronous=0;
    AKDispatchProcessBlock(0,1,queue,0,^{ synchronous++; });
    assert(synchronous==1);
    dispatch_semaphore_t started=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0);
    dispatch_async(queue,^{ dispatch_semaphore_signal(started); dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER); });
    dispatch_semaphore_wait(started,DISPATCH_TIME_FOREVER);
    @autoreleasepool {
        Capture *capture=[Capture new];
        AKDispatchProcessBlock(1,0,queue,0,^{ [capture use]; });
        AKDispatchProcessBlock(1,2,queue,DISPATCH_TIME_NOW,^{ [capture use]; });
    }
    AKRetireProcessCallbacks(1);
    assert(AKProcessCallbacksDrained(1));
    dispatch_semaphore_signal(release);
    dispatch_sync(queue,^{});
    assert(!atomic_load(&called) && !atomic_load(&destroyed));
    AKDispatchProcessBlock(2,0,queue,0,^{
        dispatch_semaphore_signal(started);
        dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);
    });
    dispatch_semaphore_wait(started,DISPATCH_TIME_FOREVER);
    AKRetireProcessCallbacks(2);
    assert(!AKProcessCallbacksDrained(2));
    dispatch_semaphore_signal(release);
    dispatch_sync(queue,^{});
    assert(AKProcessCallbacksDrained(2));
    AKDispatchProcessBlock(1,1,queue,0,^{ synchronous++; });
    assert(synchronous==1);
    AKDispatchProcessBlock(3,1,queue,0,^{ synchronous++; });
    assert(synchronous==2);
    puts("PASS: queued work skips retired guest entry and destruction; active work drains; live slots still dispatch");
} }
