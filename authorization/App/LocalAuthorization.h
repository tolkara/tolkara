#pragma once
#import <Foundation/Foundation.h>
#include "NativeCodeMemory.h"

// Main-thread notifications before attachment and after confirmed preparation.
// The former carries only the requested byte count, never addresses or keys.
FOUNDATION_EXPORT NSNotificationName const TKLocalArenaWillPrepare;
FOUNDATION_EXPORT NSNotificationName const TKLocalArenaDidPrepare;

@interface TKLocalAuthorization : NSObject
@property(nonatomic,readonly) BOOL localSessionReady;
// Direct reachability only, no pairing/credentials/debugging. A TCP connection
// alone does not authenticate the service or grant execution permission.
+ (void)probeDirectAccess:(void (^)(NSString *))completion;
+ (void)probeDirectService:(void (^)(NSString *))completion;
+ (void)probeRemotePairingService:(void (^)(NSString *))completion;
+ (void)probeLocalRouteService:(void (^)(NSString *))completion;
// The port of this device's developer service: 49152, or where iOS moved it (ServicePort.h).
+ (void)findServicePort:(void (^)(uint16_t port,NSString *report))completion;
- (void)startAndProbeLocalRoute:(void (^)(NSString *))completion;
- (void)startAndVerifyPairing:(void (^)(NSString *))completion;
- (void)startAndVerifyTunnel:(void (^)(NSString *))completion;
- (void)startAndPrepareLocalAuthorization:(void (^)(NSString *))completion;
// Explicit user action only: may display iPadOS's VPN configuration consent.
- (void)startLocalRoute:(void (^)(NSString *))completion;
- (void)stopLocalRoute;
@end
// Opt-in development loader only. No route is started or consent requested here.
// An unavailable/unconfigured helper rejects before any debugger attachment.
NCPreparation TKPrepareLocalArena(void *address,size_t size,void *context);

NCPreparation TKPrepareLocalArenaPair(void *address,size_t size,void *second,size_t secondSize,void *context);
