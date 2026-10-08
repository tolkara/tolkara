#import "SteamCloudWire.h"
NS_ASSUME_NONNULL_BEGIN
// The first sync pulls verified remote bytes. Later syncs use a hash baseline
// to detect changes on both sides and refuse conflicts. Local backups are retained.
@interface TKSteamCloudSync : NSObject
@property(nonatomic) BOOL localGameRunning;
- (instancetype)initWithAppID:(uint32_t)appID remoteDirectory:(NSString *)remoteDirectory
                    localDirectory:(NSString *)localDirectory stateDirectory:(NSString *)stateDirectory
                    fileNames:(NSArray<NSString *> *)fileNames;
- (BOOL)syncUsername:(NSString *)username token:(NSString *)token allowUpload:(BOOL)allowUpload
              report:(NSString * _Nullable * _Nullable)report error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
