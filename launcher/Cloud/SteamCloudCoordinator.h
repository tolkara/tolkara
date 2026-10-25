#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TKSteamCloudCoordinator : NSObject
// configuration: the profile's steamCloud block. Without one, a
// Documents/SteamCloud/<profile>/config.json of the same shape is used.
+ (BOOL)configuredProfile:(NSString *)profile documents:(NSString *)documents configuration:(nullable NSDictionary *)configuration;
- (instancetype)initWithProfile:(NSString *)profile documents:(NSString *)documents configuration:(nullable NSDictionary *)configuration;
// Background thread only. Consumes an approved-login.json into this app's Keychain.
- (BOOL)prepareWithReport:(NSString * _Nullable * _Nullable)report error:(NSError **)error;
- (void)startPeriodicSync;
- (void)flush;
@end
NS_ASSUME_NONNULL_END
