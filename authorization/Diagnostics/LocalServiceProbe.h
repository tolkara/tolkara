#pragma once
#import <Foundation/Foundation.h>
// Credential-free protocol identification. Completes on the main queue.
// Only fixed development endpoints are accepted; no debugger commands.
@interface TKLocalServiceProbe : NSObject
+ (void)probeService:(BOOL)remotePairing address:(NSString *)host completion:(void (^)(NSString *))completion;
// `answered`: the service replied with the expected handshake (Remote Pairing)
// or lockdown QueryType reply. The port must be TK_AUTH_SERVICE_PORT or in the
// dynamic range above it.
+ (void)probeService:(BOOL)remotePairing address:(NSString *)host port:(uint16_t)port completion:(void (^)(NSString *report,BOOL answered))completion;
@end
