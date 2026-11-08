#import "LocalAuthorization.h"
#import "Diagnostics/LocalServiceProbe.h"
#import "ServicePort.h"
#import "Protocol.h"
#import "LocalArenaPublisher.h"
#import "LocalArenaPoller.h"
#include "Control/ArenaControl.h"
#import <NetworkExtension/NetworkExtension.h>
#import <QuartzCore/QuartzCore.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

NSNotificationName const TKLocalArenaWillPrepare = @"TKLocalArenaWillPrepare";
NSNotificationName const TKLocalArenaDidPrepare = @"TKLocalArenaDidPrepare";

static void announceArena(NSNotificationName name, NSDictionary *info) {
    void (^announce)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:name object:nil userInfo:info];
        [CATransaction flush];
    };
    if (NSThread.isMainThread) announce();
    else dispatch_sync(dispatch_get_main_queue(), announce);
}

@interface TKLocalAuthorization ()
@property(nonatomic,strong) NETunnelProviderManager *manager;
@property(nonatomic,readwrite) BOOL localSessionReady;
@end

static void TKWaitForRoute(NETunnelProviderManager *manager,CFTimeInterval deadline,void (^completion)(BOOL)) {
    if(manager.connection.status==NEVPNStatusConnected) {completion(YES);return;}
    if(CACurrentMediaTime()>=deadline) {completion(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        TKWaitForRoute(manager,deadline,completion);
    });
}
static void TKWaitForStoppedRoute(NETunnelProviderManager *manager,CFTimeInterval deadline,void (^completion)(BOOL)) {
    NEVPNStatus status=manager.connection.status;
    if(status==NEVPNStatusDisconnected || status==NEVPNStatusInvalid) {completion(YES);return;}
    if(CACurrentMediaTime()>=deadline) {completion(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        TKWaitForStoppedRoute(manager,deadline,completion);
    });
}
@implementation TKLocalAuthorization
- (void)startAndProbeLocalRoute:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:0 completion:completion];
}
- (void)startAndVerifyPairing:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:1 completion:completion];
}
- (void)startAndVerifyTunnel:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:2 completion:completion];
}
- (void)startAndPrepareLocalAuthorization:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:3 completion:completion];
}
- (void)startAndProbeLocalRoute:(NSUInteger)mode completion:(void (^)(NSString *))completion {
    self.localSessionReady=NO;
    [self startLocalRoute:^(NSString *startResult) {
        TKWaitForRoute(self.manager,CACurrentMediaTime()+10,^(BOOL connected) {
            if(!connected) {
                completion([NSString stringWithFormat:@"Route did not connect (status %ld). %@",(long)self.manager.connection.status,startResult]);return;
            }
            [TKLocalAuthorization findServicePort:^(uint16_t port,NSString *result) {
                __block BOOL delivered=NO;
                void (^finish)(NSString *,BOOL)=^(NSString *report,BOOL ready) {
                    void (^deliver)(void)=^{
                        if(delivered)return;delivered=YES;
                        self.localSessionReady=ready;completion(report);
                    };
                    if(NSThread.isMainThread)deliver();else dispatch_async(dispatch_get_main_queue(),deliver);
                };
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    if(delivered)return;
                    finish(@"Local service setup timed out. Close and reopen the app to retry.",NO);
                    [self.manager.connection stopVPNTunnel];
                });
                // The enrolment is in the Keychain group both builds of Tolkara share, keyed by device; the
                // second build (docs/MULTIPROCESS.md) learns which device from the first through their App Group.
                NSString *groupName=[NSBundle.mainBundle objectForInfoDictionaryKey:@"TolkaraAppGroup"];
                NSUserDefaults *shared=[groupName isKindOfClass:NSString.class]?[[NSUserDefaults alloc] initWithSuiteName:groupName]:nil;
                NSString *device=[NSUserDefaults.standardUserDefaults stringForKey:@"TKEnrolledDeviceIdentifier"];
                if (device.length) [shared setObject:device forKey:@"TKEnrolledDeviceIdentifier"];
                else device=[shared stringForKey:@"TKEnrolledDeviceIdentifier"]?:@"";
                NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@TK_AUTH_PROTOCOL_VERSION,
                    @"operation":mode==3?@"prepareAuthorization":mode==2?@"verifyTunnel":mode==1?@"verifyPairing":@"probeService",@"deviceIdentifier":device,
                    @"servicePort":@(port)} options:0 error:NULL];
                NSError *error=nil;
                BOOL sent=[(NETunnelProviderSession *)self.manager.connection sendProviderMessage:request returnError:&error responseHandler:^(NSData *data) {
                    // The provider replies nil when it declines or fails; nil.length is 0,
                    // and JSON parsing of nil data raises inside this handler.
                    id state=data && data.length<=4096?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
                    NSString *report=result;
                    NSString *helper=[state isKindOfClass:NSDictionary.class]?state[@"helperProbe"]:nil;
                    if([helper isKindOfClass:NSString.class] && helper.length<=1024)report=[report stringByAppendingFormat:@" Helper: %@",helper];
                    if([state isKindOfClass:NSDictionary.class])
                        report=[report stringByAppendingFormat:@" Route status: running=%d, reflected=%llu, dropped=%llu.",[state[@"routeRunning"] boolValue],[state[@"reflectedPackets"] unsignedLongLongValue],[state[@"droppedPackets"] unsignedLongLongValue]];
                    BOOL ready=[state isKindOfClass:NSDictionary.class] && [state[@"readyForPreparation"] isEqual:@YES];
                    finish(report,ready);
                }];
                if(!sent)finish([result stringByAppendingString:@" Provider status unavailable."],NO);
            }];
        });
    }];
}
+ (void)probeDirectService:(void (^)(NSString *))completion {
    [TKLocalServiceProbe probeService:NO address:@"127.0.0.1" completion:completion];
}
+ (void)probeRemotePairingService:(void (^)(NSString *))completion {
    [TKLocalServiceProbe probeService:YES address:@"127.0.0.1" completion:completion];
}
+ (void)probeLocalRouteService:(void (^)(NSString *))completion {
    [self findServicePort:^(uint16_t port,NSString *report) { (void)port;completion(report); }];
}
// The developer service usually answers on 49152 through the route; that is
// tried first, so a device where it does never needs Local Network access.
// Otherwise the port this device advertises over Bonjour is tried
// (ServicePort.h). Completes on the main queue with the port to use and the
// probes' report; 49152 when nothing better was found.
+ (void)findServicePort:(void (^)(uint16_t port,NSString *report))completion {
    [TKLocalServiceProbe probeService:YES address:TK_AUTH_PEER port:TK_AUTH_SERVICE_PORT completion:^(NSString *first,BOOL answered) {
        if(answered) {completion(TK_AUTH_SERVICE_PORT,first);return;}
        // Long enough for the one-time Local Network question to be answered.
        [TKServicePort discoverWithTimeout:30 completion:^(uint16_t port,NSString *note) {
            if(!port || port==TK_AUTH_SERVICE_PORT) {completion(TK_AUTH_SERVICE_PORT,[first stringByAppendingFormat:@" %@",note]);return;}
            [TKLocalServiceProbe probeService:YES address:TK_AUTH_PEER port:port completion:^(NSString *second,BOOL found) {
                (void)found;
                completion(port,[NSString stringWithFormat:@"%@ %@ %@",first,note,second]);
            }];
        }];
    }];
}
+ (void)probeDirectAccess:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int fd=socket(AF_INET,SOCK_STREAM,0),result=errno;
        if(fd>=0) {
            int flags=fcntl(fd,F_GETFL,0);
            if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)result=errno;
            else {
                struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_port=htons(49152)};
                inet_pton(AF_INET,"127.0.0.1",&address.sin_addr);
                int rc=connect(fd,(struct sockaddr *)&address,sizeof address);result=rc==0?0:errno;
                if(rc<0 && result==EINPROGRESS) {
                    struct pollfd p={.fd=fd,.events=POLLOUT};rc=poll(&p,1,1500);
                    if(rc>0) {socklen_t n=sizeof result;if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&result,&n))result=errno;}
                    else result=rc==0?ETIMEDOUT:errno;
                }
            }
            close(fd);
        }
        NSString *text=result?[NSString stringWithFormat:@"Direct loopback port 49152: %s (%d). This does not establish that every direct route is unavailable.",strerror(result),result]:@"Direct loopback port 49152 accepted a connection. Service identity, pairing and native authorization are not verified.";
        dispatch_async(dispatch_get_main_queue(),^{completion(text);});
    });
}
- (void)startLocalRoute:(void (^)(NSString *))completion {
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *managers,NSError *error) {
        if(error) {dispatch_async(dispatch_get_main_queue(),^{completion(error.localizedDescription);});return;}
        NETunnelProviderManager *selected=nil;
        for(NETunnelProviderManager *candidate in managers) {
            if([candidate.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] &&
               [((NETunnelProviderProtocol *)candidate.protocolConfiguration).providerBundleIdentifier isEqual:TK_AUTH_PROVIDER_ID]) {selected=candidate;break;}
        }
        self.manager=selected?:[NETunnelProviderManager new];
        NETunnelProviderProtocol *configuration=[NETunnelProviderProtocol new];
        configuration.providerBundleIdentifier=TK_AUTH_PROVIDER_ID;
        configuration.serverAddress=TK_AUTH_PEER;
        configuration.includeAllNetworks=NO;
        configuration.excludeLocalNetworks=NO;
        configuration.disconnectOnSleep=YES;
        self.manager.protocolConfiguration=configuration;
        self.manager.localizedDescription=@"Tolkara local development route";
        self.manager.enabled=YES;
        self.manager.onDemandEnabled=NO;
        [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            if(saveError) {dispatch_async(dispatch_get_main_queue(),^{completion(saveError.localizedDescription);});return;}
            [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
                if(loadError) {dispatch_async(dispatch_get_main_queue(),^{completion(loadError.localizedDescription);});return;}
                // Every cold app launch needs an unused helper transaction.
                // Stop only our own route and wait for actual OS teardown.
                [self.manager.connection stopVPNTunnel];
                TKWaitForStoppedRoute(self.manager,CACurrentMediaTime()+10,^(BOOL stopped) {
                    NSError *startError=nil;
                    BOOL requested=stopped && [self.manager.connection startVPNTunnelAndReturnError:&startError];
                    NSString *text=requested?@"Local route started; authentication is a separate step.":(startError.localizedDescription?:@"The previous local session did not stop in time.");
                    dispatch_async(dispatch_get_main_queue(),^{completion(text);});
                });
            }];
        }];
    }];
}
- (void)stopLocalRoute { [self.manager.connection stopVPNTunnel]; }
@end

static TKLocalArenaPublisher *localArenaPublisher(void) {
    static TKLocalArenaPublisher *publisher;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        publisher=[[TKLocalArenaPublisher alloc] initWithTransport:^BOOL(NSData *request,void (^completion)(NSData *)) {
            // Loading preferences is asynchronous. Once queued, loss of its
            // callback is uncertainty, even if no provider message was sent yet.
            [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *managers,NSError *error) {
                NETunnelProviderSession *session=nil;
                if(!error) for(NETunnelProviderManager *candidate in managers) {
                    if([candidate.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] &&
                       [((NETunnelProviderProtocol *)candidate.protocolConfiguration).providerBundleIdentifier isEqual:TK_AUTH_PROVIDER_ID] &&
                       candidate.connection.status==NEVPNStatusConnected) {
                        session=(NETunnelProviderSession *)candidate.connection; break;
                    }
                }
                if(!session) {
                    uint8_t reply[TKAC_SIZE];
                    BOOL valid=tkac_reply(request.bytes,request.length,TKAC_REJECTED,reply,sizeof reply);
                    completion(valid?[NSData dataWithBytes:reply length:sizeof reply]:nil); return;
                }
                TKLocalArenaPoller *poller=[[TKLocalArenaPoller alloc] initWithTransport:^BOOL(NSData *message,void (^reply)(NSData *)) {
                    NSError *sendError=nil;
                    return [session sendProviderMessage:message returnError:&sendError responseHandler:reply];
                }];
                [poller start:request completion:completion];
            }];
            return YES;
        }];
    });
    return publisher;
}
NCPreparation TKPrepareLocalArenaPair(void *address,size_t size,void *second,size_t secondSize,void *context) {
    (void)context;
    CFTimeInterval began=CACurrentMediaTime();
    announceArena(TKLocalArenaWillPrepare, @{@"bytes":@(size+secondSize)});
    NCPreparation result=[localArenaPublisher() prepare:address size:size second:second secondSize:secondSize timeout:1830];
    announceArena(TKLocalArenaDidPrepare, @{@"prepared":@(result == NC_PREPARED)});
    fprintf(stderr,"[local-launch] arena result=%u bytes=%zu elapsed=%.3fs\n",(unsigned)result,size+secondSize,CACurrentMediaTime()-began);
    return result;
}

NCPreparation TKPrepareLocalArena(void *address,size_t size,void *context) {
    return TKPrepareLocalArenaPair(address,size,NULL,0,context);
}
