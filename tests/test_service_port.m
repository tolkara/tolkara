// TKServicePort finds the port this machine itself advertises for
// _remotepairing._tcp, ignoring other devices' advertisements on the network.
#import "ServicePort.h"
#include <assert.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <stdio.h>
#include <unistd.h>

static uint16_t discover(NSTimeInterval timeout, NSString **note) {
    __block BOOL done=NO; __block uint16_t found=0; __block NSString *text=nil;
    [TKServicePort discoverWithTimeout:timeout completion:^(uint16_t port, NSString *message) {
        assert(NSThread.isMainThread);
        found=port; text=message; done=YES;
    }];
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:timeout+5];
    while(!done && limit.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    assert(done);
    if(note) *note=text;
    return found;
}

int main(void) { @autoreleasepool {
    // Without an advertisement of its own, this machine has none to report,
    // whatever other devices advertise.
    NSString *note=nil;
    assert(discover(3,&note)==0);
    assert([note containsString:@"No advertisement"]);
    printf("no own service: %s\n",note.UTF8String);

    // An advertisement by this machine, on a port of the dynamic range.
    const uint16_t port=61234;
    char name[64]; snprintf(name,sizeof name,"tolkara-test-%d",getpid());
    DNSServiceRef registration=NULL;
    DNSServiceErrorType status=DNSServiceRegister(&registration,0,kDNSServiceInterfaceIndexAny,name,"_remotepairing._tcp",
                                                  "local.",NULL,htons(port),0,NULL,NULL,NULL);
    assert(status==kDNSServiceErr_NoError);
    assert(DNSServiceSetDispatchQueue(registration,dispatch_get_main_queue())==kDNSServiceErr_NoError);
    uint16_t found=discover(10,&note);
    printf("own service: %u (%s)\n",found,note.UTF8String);
    assert(found==port);
    assert([note containsString:@"61234"]);
    DNSServiceRefDeallocate(registration);
    puts("service port tests passed");
    return 0;
} }
