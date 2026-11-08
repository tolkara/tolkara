#pragma once
#import <Foundation/Foundation.h>

// The port of this device's own Remote Pairing service (the developer service
// Developer service connects to through the local route). It is usually 49152,
// but iOS can start the service on another port of the dynamic range: an
// iPhone on iOS 27.2 advertised 54059 while 49152 refused connections. The
// service advertises itself over Bonjour as _remotepairing._tcp, like every
// paired device on the network; ours is the instance whose host resolves to
// one of this device's own addresses. Finding it needs Local Network access
// (NSBonjourServices, NSLocalNetworkUsageDescription), asked the first time.
// The port says nothing about the service's identity: pair-verify against the
// enrolled identity still authenticates whatever answers there.
@interface TKServicePort : NSObject
// Completes on the main queue with the port, or 0 when no advertisement of
// this device was found within `timeout` seconds; `note` says which.
+ (void)discoverWithTimeout:(NSTimeInterval)timeout completion:(void (^)(uint16_t port,NSString *note))completion;
@end
