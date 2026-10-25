#import "LocalArenaPublisher.h"
#include "Control/ArenaControl.h"
#include <assert.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>

static NSData *reply(NSData *request,TKACOutcome outcome) {
    uint8_t bytes[TKAC_SIZE]; assert(tkac_reply(request.bytes,request.length,outcome,bytes,sizeof bytes));
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}
static NCPreparation prepare(void *address,size_t size,void *context) {
    return [(__bridge TKLocalArenaPublisher *)context prepare:address size:size timeout:.08];
}
static NCPreparation prepare_pair(void *first,size_t firstSize,void *second,size_t secondSize,void *context) {
    return [(__bridge TKLocalArenaPublisher *)context prepare:first size:firstSize second:second secondSize:secondSize timeout:.08];
}
int main(void) { @autoreleasepool {
    for(unsigned pairMode=0;pairMode<2;pairMode++)
    for(NSString *mode in @[@"success",@"rejected",@"detached",@"unknown",@"wrongReply",@"timeout",@"notSent",@"contradictory"]) {
        __block void (^late)(NSData *); __block NSData *sent;
        __block uint64_t challenge_address=0; __block unsigned calls=0;
        TKLocalArenaPublisher *publisher=[[TKLocalArenaPublisher alloc] initWithTransport:^BOOL(NSData *message,void (^completion)(NSData *)) {
            calls++; sent=message; TKACRequest request; assert(tkac_decode(message.bytes,message.length,&request));
            assert(request.pid==(uint32_t)getpid() && request.uid==(uint32_t)geteuid());
            assert(!memcmp((void *)(uintptr_t)request.challenge_address,request.challenge,32));
            assert((request.second_size!=0)==(pairMode!=0));
            if(pairMode) for(size_t i=0;i<request.second_size;i++)assert(((uint8_t *)(uintptr_t)request.second_address)[i]==0);
            challenge_address=request.challenge_address;
            for(size_t i=0;i<request.size;i++)assert(((uint8_t *)(uintptr_t)request.address)[i]==0);
            if([mode isEqual:@"notSent"])return NO;
            if([mode isEqual:@"contradictory"]) { completion(reply(message,TKAC_PREPARED));return NO; }
            if([mode isEqual:@"timeout"]) { late=completion; return YES; }
            // A main-queue reply must be delivered while the synchronous native
            // loader waits, proving it did not block the app's dispatch queue.
            dispatch_async(dispatch_get_main_queue(),^{
                TKACOutcome outcome=[mode isEqual:@"success"]?TKAC_PREPARED:
                    [mode isEqual:@"rejected"]?TKAC_REJECTED:[mode isEqual:@"detached"]?TKAC_FAILED_DETACHED:TKAC_UNCERTAIN;
                NSMutableData *response=[reply(message,outcome) mutableCopy];
                if([mode isEqual:@"wrongReply"])((uint8_t *)response.mutableBytes)[80]^=1;
                completion(response);
            });
            return YES;
        }];
        NativeCodeMemory memory={0},quarantine={0},second={0},secondQuarantine={0};
        BOOL result=pairMode ? nc_create_pair(&memory,16384,UINTPTR_MAX,&second,16384,prepare_pair,(__bridge void *)publisher,&quarantine,&secondQuarantine) :
            nc_create_managed(&memory,16384,prepare,(__bridge void *)publisher,&quarantine);
        BOOL success=[mode isEqual:@"success"];
        BOOL uncertain=[@[@"unknown",@"wrongReply",@"timeout",@"contradictory"] containsObject:mode];
        assert(result==success && calls==1 && quarantine.quarantined==uncertain);
        if(pairMode) {
            assert(second.published==success && secondQuarantine.quarantined==uncertain);
            if(uncertain) { uint8_t byte=0; assert(!nc_write(&secondQuarantine,0,&byte,1)); }
            if(!success) assert(!second.executable);
        }
        if(uncertain) {
            assert(!memory.executable && !quarantine.published);
            uint8_t byte=1;assert(!nc_write(&quarantine,0,&byte,1));
        }
        if(late) { late(reply(sent,TKAC_PREPARED)); late=nil; assert(quarantine.quarantined && !memory.executable); }
        assert([publisher prepare:(void *)0x200000 size:16384 timeout:.01]==NC_REJECTED && calls==1);
        publisher=nil;
        if(uncertain) {
            uint8_t value=0;vm_size_t actual=0;
            assert(vm_read_overwrite(mach_task_self(),(vm_address_t)challenge_address,1,(vm_address_t)&value,&actual)==KERN_SUCCESS && actual==1);
        }
        nc_destroy(&memory); nc_destroy(&quarantine); nc_destroy(&second); nc_destroy(&secondQuarantine);
    }
    // The wire accepts the full ceiling without touching fake arena memory;
    // a synthetic rejection finishes immediately, even with the longest timeout.
    __block unsigned boundaryCalls=0;
    TKLocalArenaPublisher *boundary=[[TKLocalArenaPublisher alloc] initWithTransport:^BOOL(NSData *message,void (^completion)(NSData *)) {
        TKACRequest request; assert(tkac_decode(message.bytes,message.length,&request));
        assert(request.size==2048ull*1024u*1024u); boundaryCalls++;
        completion(reply(message,TKAC_REJECTED)); return YES;
    }];
    assert([boundary prepare:(void *)0x200000 size:2048ull*1024u*1024u timeout:1850.01]==NC_REJECTED && boundaryCalls==0);
    assert([boundary prepare:(void *)0x200000 size:2048ull*1024u*1024u+16384 timeout:1830]==NC_REJECTED && boundaryCalls==0);
    assert([boundary prepare:(void *)0x200000 size:2048ull*1024u*1024u timeout:1850]==NC_REJECTED && boundaryCalls==1);
    puts("PASS: local publisher run-loop progress, exact receipt, rejection, uncertain quarantine, late-reply/retry denial and retained challenge");
} }
