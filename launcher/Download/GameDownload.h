#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Experimental. Fetches an application's own files from its publisher's
// content servers into Documents, for a user with no Mac to copy them from.
// A profile's `download` block says what to fetch (profiles/README.md); the
// only service is "blizzard": Blizzard's public version and content servers,
// which need no account. Tolkara hosts and bundles none of the files.
//
// Only the application itself is fetched (for World of Warcraft, about
// 200 MB). The game's data is not: the game fetches what it needs when it
// first starts. Each file is checked against the content key the server's
// file list gives for it before it is put in place, and a download that was
// stopped continues where it left off.
extern NSString *const TKGameDownloadErrorDomain;

// One request: the whole resource when range.length is 0.
typedef NSData * _Nullable (^TKGameDownloadFetch)(NSURL *url, NSRange range, NSError **error);

@interface TKGameDownload : NSObject
// Same rules as tools/check_profile.py (check_download).
+ (BOOL)validConfiguration:(id)configuration workingDirectory:(NSString *)workingDirectory;
// Regions and languages the block offers: [{id, name, portal}], [locale].
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)regionsOfConfiguration:(NSDictionary *)configuration;
+ (NSArray<NSString *> *)localesOfConfiguration:(NSDictionary *)configuration;

- (nullable instancetype)initWithConfiguration:(NSDictionary *)configuration documents:(NSString *)documents
                              workingDirectory:(NSString *)workingDirectory region:(NSString *)region locale:(NSString *)locale;
// Tests supply the network; otherwise HTTPS requests.
@property (nonatomic, copy, nullable) TKGameDownloadFetch fetch;
// Called on the downloading thread: what is happening and how far along (0 to 1).
@property (nonatomic, copy, nullable) void (^progress)(NSString *phase, double fraction);
// From any thread; -run: then stops with NSUserCancelledError.
- (void)cancel;
// Background thread only.
- (BOOL)run:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
