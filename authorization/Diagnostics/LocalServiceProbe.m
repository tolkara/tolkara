#import "LocalServiceProbe.h"
#import <QuartzCore/QuartzCore.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
// Bounded diagnostic only. Never sends identity, pairing or debug commands.
static BOOL TKProbeTransfer(int fd,void *bytes,size_t size,BOOL writing,CFTimeInterval deadline) {
    size_t offset=0;
    while(offset<size) {
        double left=deadline-CACurrentMediaTime();
        if(left<=0) {errno=ETIMEDOUT;return NO;}
        struct pollfd p={.fd=fd,.events=writing?POLLOUT:POLLIN};
        int ready=poll(&p,1,(int)(left*1000)+1);
        if(ready<0 && errno==EINTR)continue;
        if(ready<=0) {if(!ready)errno=ETIMEDOUT;return NO;}
        ssize_t n=writing?send(fd,(char *)bytes+offset,size-offset,0):recv(fd,(char *)bytes+offset,size-offset,0);
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0) {if(!n)errno=ECONNRESET;return NO;}
        offset+=(size_t)n;
    }
    return YES;
}

@implementation TKLocalServiceProbe
+ (void)probeService:(BOOL)remotePairing address:(NSString *)host completion:(void (^)(NSString *))completion {
    [self probeService:remotePairing address:host port:49152 completion:^(NSString *report,BOOL answered) { (void)answered;completion(report); }];
}
+ (void)probeService:(BOOL)remotePairing address:(NSString *)host port:(uint16_t)port completion:(void (^)(NSString *,BOOL))completion {
    if((![host isEqual:@"127.0.0.1"] && ![host isEqual:@"10.7.0.1"]) || port<49152) {
        dispatch_async(dispatch_get_main_queue(),^{completion(@"Diagnostic endpoint rejected.",NO);});return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *result=@"Local service query failed.";
        BOOL answered=NO;
        int fd=socket(AF_INET,SOCK_STREAM,0);
        if(fd>=0) {
            int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one);
            int flags=fcntl(fd,F_GETFL,0);
            struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_port=htons(port)};
            inet_pton(AF_INET,host.UTF8String,&address.sin_addr);
            BOOL connected=NO;
            if(flags>=0 && !fcntl(fd,F_SETFL,flags|O_NONBLOCK)) {
                int rc=connect(fd,(struct sockaddr *)&address,sizeof address);
                if(rc==0)connected=YES;
                else if(errno==EINPROGRESS) {
                    struct pollfd p={.fd=fd,.events=POLLOUT};
                    if(poll(&p,1,1500)>0) {
                        int error=0;socklen_t length=sizeof error;
                        connected=!getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)&&!error;
                    }
                }
            }
            if(connected) {
                if(remotePairing) {
                    NSDictionary *query=@{@"message":@{@"plain":@{@"_0":@{@"request":@{@"_0":@{@"handshake":@{@"_0":@{
                        @"hostOptions":@{@"attemptPairVerify":@YES},@"wireProtocolVersion":@19}}}}}}},@"originatedBy":@"host",@"sequenceNumber":@0};
                    NSData *body=[NSJSONSerialization dataWithJSONObject:query options:0 error:NULL];
                    uint8_t header[11]={'R','P','P','a','i','r','i','n','g',0,0};
                    header[9]=(uint8_t)(body.length>>8);header[10]=(uint8_t)body.length;
                    CFTimeInterval deadline=CACurrentMediaTime()+4;
                    if(TKProbeTransfer(fd,header,sizeof header,YES,deadline) && TKProbeTransfer(fd,(void *)body.bytes,body.length,YES,deadline) &&
                       TKProbeTransfer(fd,header,sizeof header,NO,deadline) && !memcmp(header,"RPPairing",9)) {
                        size_t size=((size_t)header[9]<<8)|header[10];
                        if(size && size<=16384) {
                            NSMutableData *reply=[NSMutableData dataWithLength:size];
                            if(TKProbeTransfer(fd,reply.mutableBytes,size,NO,deadline)) {
                                id object=[NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
                                BOOL valid=[object isKindOfClass:NSDictionary.class] && [object[@"originatedBy"] isEqual:@"device"];
                                id value=valid?object:nil;
                                for(NSString *key in @[@"message",@"plain",@"_0",@"response",@"_1",@"handshake",@"_0"])
                                    value=[value isKindOfClass:NSDictionary.class]?value[key]:nil;
                                answered=[value isKindOfClass:NSDictionary.class];
                                result=answered?@"Direct service returned a Remote Pairing handshake. Device identity and execution permission remain unverified.":@"Direct service returned RPPairing framing but an unexpected handshake schema.";
                            } else result=@"Remote Pairing reply body closed or timed out.";
                        } else result=@"Remote Pairing reply exceeded the diagnostic size limit.";
                    } else result=[NSString stringWithFormat:@"Direct connection opened, but Remote Pairing handshake failed (socket error %d).",errno];
                } else {
                NSData *body=[NSPropertyListSerialization dataWithPropertyList:@{@"Request":@"QueryType",@"Label":@"TolkaraDiagnostic"}
                    format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
                uint32_t length=htonl((uint32_t)body.length);
                CFTimeInterval deadline=CACurrentMediaTime()+4;
                if(TKProbeTransfer(fd,&length,4,YES,deadline) && TKProbeTransfer(fd,(void *)body.bytes,body.length,YES,deadline) &&
                   TKProbeTransfer(fd,&length,4,NO,deadline)) {
                    size_t size=ntohl(length);
                    if(size && size<=16384) {
                        NSMutableData *reply=[NSMutableData dataWithLength:size];
                        if(TKProbeTransfer(fd,reply.mutableBytes,size,NO,deadline)) {
                            id value=[NSPropertyListSerialization propertyListWithData:reply options:NSPropertyListImmutable format:NULL error:NULL];
                            BOOL lockdown=[value isKindOfClass:NSDictionary.class] && [value[@"Type"] isEqual:@"com.apple.mobile.lockdown"];
                            // Only emit our classifications, never arbitrary service data.
                            answered=lockdown;
                            result=lockdown?@"Direct service answered QueryType as com.apple.mobile.lockdown. Pairing and execution permission remain unverified.":@"Direct service returned a bounded reply, but it was not the expected lockdown QueryType response.";
                        } else result=@"Direct service closed or timed out while reading the query reply.";
                    } else result=@"Direct service reply does not use the expected bounded plist framing.";
                } else result=@"Direct connection opened, but the read-only lockdown query closed or timed out.";
                }
            } else result=@"Direct service connection could not be established.";
            close(fd);
        }
        NSString *report=[NSString stringWithFormat:@"Endpoint %@:%u. %@",host,(unsigned)port,result];
        dispatch_async(dispatch_get_main_queue(),^{completion(report,answered);});
    });
}
@end
