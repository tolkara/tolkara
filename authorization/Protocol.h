#pragma once
#import <Foundation/Foundation.h>

#define TK_AUTH_PROTOCOL_VERSION 1
// The extension is always "<app bundle id>.authorization"; builders choose the app id.
#define TK_AUTH_PROVIDER_ID [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".authorization"]
#define TK_AUTH_INTERFACE @"10.7.0.2"
#define TK_AUTH_PEER @"10.7.0.1"
// The device's Remote Pairing port, unless iOS moved it (App/ServicePort.h).
#define TK_AUTH_SERVICE_PORT 49152

// A connected route is never evidence that guest code may execute. The status
// explicitly reports authorization separately until the real protocol succeeds.
static inline NSDictionary *TKRouteStatus(BOOL running,NSUInteger reflected,NSUInteger dropped) {
    return @{@"version":@TK_AUTH_PROTOCOL_VERSION,@"routeRunning":@(running),
        @"nativeExecutionReady":@NO,@"authorizationState":@"notConfigured",
        @"reflectedPackets":@(reflected),@"droppedPackets":@(dropped)};
}
