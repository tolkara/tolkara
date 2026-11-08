#import "ServicePort.h"
#include <arpa/inet.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

// One search: a browse, a resolve per instance and an address lookup per
// resolved host, all on one serial queue. The first address that belongs to
// this device decides; the timeout ends the search otherwise.
@interface TKServicePortSearch : NSObject {
@public
    dispatch_queue_t queue;
    NSMutableArray<NSValue *> *references;
    NSMutableArray *contexts;
    NSSet<NSData *> *ownAddresses;
    NSUInteger instances;
    DNSServiceErrorType error;
    BOOL done;
    void (^completion)(uint16_t,NSString *);
}
@end
@implementation TKServicePortSearch
@end

// What an address lookup carries: its search and the instance's port.
@interface TKServicePortCandidate : NSObject {
@public
    __unsafe_unretained TKServicePortSearch *search;
    uint16_t port;
}
@end
@implementation TKServicePortCandidate
@end

static NSSet<NSData *> *own_addresses(void) {
    NSMutableSet *addresses=[NSMutableSet new];
    struct ifaddrs *list=NULL;
    if(getifaddrs(&list))return addresses;
    for(struct ifaddrs *item=list;item;item=item->ifa_next) {
        if(!item->ifa_addr || (item->ifa_flags&IFF_LOOPBACK))continue;
        if(item->ifa_addr->sa_family==AF_INET)
            [addresses addObject:[NSData dataWithBytes:&((struct sockaddr_in *)item->ifa_addr)->sin_addr length:4]];
        else if(item->ifa_addr->sa_family==AF_INET6)
            [addresses addObject:[NSData dataWithBytes:&((struct sockaddr_in6 *)item->ifa_addr)->sin6_addr length:16]];
    }
    freeifaddrs(list);
    return addresses;
}

static void finish(TKServicePortSearch *search,uint16_t port,NSString *note) {
    if(search->done)return;
    search->done=YES;
    for(NSValue *reference in search->references) DNSServiceRefDeallocate(reference.pointerValue);
    [search->references removeAllObjects];
    void (^completion)(uint16_t,NSString *)=search->completion;
    search->completion=nil;
    dispatch_async(dispatch_get_main_queue(),^{completion(port,note);});
    [search->contexts removeAllObjects];
}

static BOOL track(TKServicePortSearch *search,DNSServiceRef reference,DNSServiceErrorType status) {
    if(status!=kDNSServiceErr_NoError)return NO;
    if(DNSServiceSetDispatchQueue(reference,search->queue)!=kDNSServiceErr_NoError) {DNSServiceRefDeallocate(reference);return NO;}
    [search->references addObject:[NSValue valueWithPointer:reference]];
    return YES;
}

static void address_reply(DNSServiceRef reference,DNSServiceFlags flags,uint32_t interface,DNSServiceErrorType status,
                          const char *host,const struct sockaddr *address,uint32_t ttl,void *context) {
    (void)reference;(void)interface;(void)host;(void)ttl;
    TKServicePortCandidate *candidate=(__bridge TKServicePortCandidate *)context;
    TKServicePortSearch *search=candidate->search;
    if(search->done || status!=kDNSServiceErr_NoError || !(flags&kDNSServiceFlagsAdd) || !address)return;
    NSData *bytes=nil;
    if(address->sa_family==AF_INET) bytes=[NSData dataWithBytes:&((const struct sockaddr_in *)address)->sin_addr length:4];
    else if(address->sa_family==AF_INET6) bytes=[NSData dataWithBytes:&((const struct sockaddr_in6 *)address)->sin6_addr length:16];
    if(bytes && [search->ownAddresses containsObject:bytes])
        finish(search,candidate->port,[NSString stringWithFormat:@"This device advertises its developer service on port %u.",candidate->port]);
}

static void resolve_reply(DNSServiceRef reference,DNSServiceFlags flags,uint32_t interface,DNSServiceErrorType status,
                          const char *name,const char *host,uint16_t port,uint16_t length,const unsigned char *text,void *context) {
    (void)reference;(void)flags;(void)name;(void)length;(void)text;
    TKServicePortSearch *search=(__bridge TKServicePortSearch *)context;
    if(search->done || status!=kDNSServiceErr_NoError || !host)return;
    TKServicePortCandidate *candidate=[TKServicePortCandidate new];
    candidate->search=search; candidate->port=ntohs(port);
    if(candidate->port<49152)return;
    DNSServiceRef lookup=NULL;
    DNSServiceErrorType started=DNSServiceGetAddrInfo(&lookup,0,interface,kDNSServiceProtocol_IPv4|kDNSServiceProtocol_IPv6,
                                                      host,address_reply,(__bridge void *)candidate);
    if(track(search,lookup,started)) [search->contexts addObject:candidate];
}

static void browse_reply(DNSServiceRef reference,DNSServiceFlags flags,uint32_t interface,DNSServiceErrorType status,
                         const char *name,const char *type,const char *domain,void *context) {
    (void)reference;
    TKServicePortSearch *search=(__bridge TKServicePortSearch *)context;
    if(search->done)return;
    if(status!=kDNSServiceErr_NoError) {search->error=status;return;}
    if(!(flags&kDNSServiceFlagsAdd) || search->instances>=32)return;
    search->instances++;
    DNSServiceRef resolve=NULL;
    DNSServiceErrorType started=DNSServiceResolve(&resolve,0,interface,name,type,domain,resolve_reply,context);
    track(search,resolve,started);
}

@implementation TKServicePort
+ (void)discoverWithTimeout:(NSTimeInterval)timeout completion:(void (^)(uint16_t,NSString *))completion {
    TKServicePortSearch *search=[TKServicePortSearch new];
    search->queue=dispatch_queue_create("local.tolkara.service-port",DISPATCH_QUEUE_SERIAL);
    search->references=[NSMutableArray new];
    search->contexts=[NSMutableArray new];
    search->completion=[completion copy];
    dispatch_async(search->queue,^{
        search->ownAddresses=own_addresses();
        DNSServiceRef browse=NULL;
        DNSServiceErrorType started=DNSServiceBrowse(&browse,0,kDNSServiceInterfaceIndexAny,"_remotepairing._tcp","local.",
                                                     browse_reply,(__bridge void *)search);
        if(!track(search,browse,started)) {
            finish(search,0,[NSString stringWithFormat:@"Bonjour search for the developer service could not start (%d).",started]);return;
        }
        // The search object stays alive until this deadline, which outlives every callback.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)),search->queue,^{
            NSString *note=search->error==kDNSServiceErr_PolicyDenied
                ? @"Tolkara has no Local Network access (Settings > Privacy & Security > Local Network), so it cannot find where the developer service moved."
                : [NSString stringWithFormat:@"No advertisement of this device's developer service found (%lu on the network).",(unsigned long)search->instances];
            finish(search,0,note);
        });
    });
}
@end
