#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TKSteamCloudCoordinator : NSObject
+ (BOOL)configuredProfile:(NSString *)profile documents:(NSString *)documents;
- (instancetype)initWithProfile:(NSString *)profile documents:(NSString *)documents;
// Background thread only. Consumes an approved-login.json into this app's Keychain.
- (BOOL)prepareWithReport:(NSString * _Nullable * _Nullable)report error:(NSError **)error;
- (void)startPeriodicSync;
- (void)flush;
@end
NS_ASSUME_NONNULL_END
