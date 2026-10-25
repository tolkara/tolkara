#import "LocalArenaPublisher.h"
#include "Control/ArenaControl.h"
#include <sys/mman.h>
#include <unistd.h>
#include <math.h>
#include <stdio.h>

@implementation TKLocalArenaPublisher {
    TKArenaTransport _transport;
    NSCondition *_condition;
    BOOL _used, _finished;
    NCPreparation _outcome;
    void *_challenge;
    size_t _challengeSize;
}
- (instancetype)initWithTransport:(TKArenaTransport)transport {
    if((self=[super init])) { _transport=[transport copy]; _condition=[NSCondition new]; }
    return self;
}
- (NCPreparation)prepare:(void *)address size:(size_t)size timeout:(NSTimeInterval)timeout {
    return [self prepare:address size:size second:NULL secondSize:0 timeout:timeout];
}
- (NCPreparation)prepare:(void *)address size:(size_t)size second:(void *)second
                    secondSize:(size_t)secondSize timeout:(NSTimeInterval)timeout {
    [_condition lock];
    if(_used || !isfinite(timeout) || timeout<=0 || timeout>TKAC_MAX_TIMEOUT_SECONDS || !_transport) {
        [_condition unlock]; return NC_REJECTED;
    }
    if(secondSize>TKAC_MAX_ARENA_BYTES || size>TKAC_MAX_ARENA_BYTES-secondSize) {
        fprintf(stderr,"[local-launch] arena request exceeds developer-service limit: %zu bytes requested, %zu bytes maximum\n",size,(size_t)TKAC_MAX_ARENA_BYTES);
        [_condition unlock]; return NC_REJECTED;
    }
    _used=YES; _outcome=NC_UNCERTAIN;
    _challengeSize=(size_t)getpagesize();
    _challenge=mmap(NULL,_challengeSize,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(_challenge==MAP_FAILED) { _challenge=NULL; _finished=YES; _outcome=NC_REJECTED; [_condition unlock]; return NC_REJECTED; }
    arc4random_buf(_challenge,32);
    if(mprotect(_challenge,_challengeSize,PROT_READ)) { _finished=YES; _outcome=NC_REJECTED; [_condition unlock]; return NC_REJECTED; }
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    TKACRequest request={.pid=(uint32_t)getpid(),.uid=(uint32_t)geteuid(),
        .address=(uintptr_t)address,.size=size,.second_address=(uintptr_t)second,.second_size=secondSize,.challenge_address=(uintptr_t)_challenge,
        .deadline_ms=(uint64_t)ceil(deadline*1000)};
    memcpy(request.challenge,_challenge,32); arc4random_buf(request.identifier,16);
    uint8_t wire[TKAC_SIZE];
    if(!tkac_encode(&request,wire,sizeof wire)) { _finished=YES; _outcome=NC_REJECTED; [_condition unlock]; return NC_REJECTED; }
    NSData *message=[NSData dataWithBytes:wire length:sizeof wire];
    [_condition unlock];
    BOOL submitted=_transport(message,^(NSData *reply) {
        [self->_condition lock];
        if(!self->_finished) {
            TKACOutcome result=TKAC_UNCERTAIN;
            BOOL valid=NSProcessInfo.processInfo.systemUptime<deadline &&
                tkac_match(message.bytes,message.length,reply.bytes,reply.length,&result);
            self->_outcome=!valid?NC_UNCERTAIN:result==TKAC_PREPARED?NC_PREPARED:
                (result==TKAC_REJECTED || result==TKAC_FAILED_DETACHED)?NC_REJECTED:NC_UNCERTAIN;
            self->_finished=YES; [self->_condition broadcast];
        }
        [self->_condition unlock];
    });
    [_condition lock];
    if(!submitted) {
        // A transport which both replied and denied submission contradicted its
        // contract. It cannot authorize execution or safe release of mappings.
        _outcome=_finished?NC_UNCERTAIN:NC_REJECTED; _finished=YES;
    }
    while(!_finished) {
        if(NSProcessInfo.processInfo.systemUptime>=deadline) { _outcome=NC_UNCERTAIN; _finished=YES; break; }
        if(NSThread.isMainThread) {
            [_condition unlock];
            @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,true); }
            [_condition lock];
        } else { [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
    }
    NCPreparation outcome=_outcome;
    [_condition unlock]; return outcome;
}
- (void)dealloc {
    // A delayed helper may still read the challenge. Quarantine it just as the
    // allocator quarantines the arena; release only at process exit.
    if(_challenge && _outcome!=NC_UNCERTAIN) munmap(_challenge,_challengeSize);
}
@end
