#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Valve's public Steam protocol, over TLS WebSockets. No game code or IPC emulation.
FOUNDATION_EXPORT NSData *TKCloudProto(NSDictionary<NSNumber *, id> *fields);
FOUNDATION_EXPORT NSDictionary<NSNumber *, NSArray *> * _Nullable TKCloudParse(NSData *data);
FOUNDATION_EXPORT uint64_t TKCloudNumber(NSDictionary *fields, unsigned field);
FOUNDATION_EXPORT NSData * _Nullable TKCloudBytes(NSDictionary *fields, unsigned field);

@interface TKSteamCloudConnection : NSObject
@property(nonatomic, readonly) uint64_t steamID;
@property(nonatomic, readonly) uint64_t clientID;
- (BOOL)connectWithUsername:(NSString *)username token:(NSString *)token error:(NSError **)error;
- (nullable NSDictionary *)call:(NSString *)method fields:(NSDictionary *)fields error:(NSError **)error;
- (void)disconnect;
@end
NS_ASSUME_NONNULL_END
