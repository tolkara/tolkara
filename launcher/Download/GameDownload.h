#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Experimental. Fetches an application's own files from its publisher's
// servers into Documents, for a user with no Mac to copy them from. A
// profile's `download` block says what to fetch (profiles/README.md), by
// service. Tolkara hosts and bundles none of an application's files.
//
// "blizzard": Blizzard's public version and content servers, which need no
// account. Only the application itself is fetched (for World of Warcraft,
// about 200 MB). The game's data is not: the game fetches what it needs when
// it first starts. Each file is checked against the content key the server's
// file list gives for it before it is put in place.
//
// "steam": the Windows Steam client from Valve's public update server, each
// package checked against the SHA-256 Valve's own list gives for it, and
// before it the Windows runtime Steam runs in (Tolkara's build of Wine and
// FEX with an empty Windows prefix: one archive from the address in the
// block, checked against the block's SHA-256). Steam finishes its own
// installation at its first start; the user signs in there.
//
// A download that was stopped continues where it left off.
extern NSString *const TKGameDownloadErrorDomain;

// One request: the whole resource when range.length is 0.
typedef NSData * _Nullable (^TKGameDownloadFetch)(NSURL *url, NSRange range, NSError **error);

@interface TKGameDownload : NSObject
// Same rules as tools/check_profile.py (check_download). `runtime` is the
// profile's own: a "steam" block needs one, a "blizzard" block has none.
+ (BOOL)validConfiguration:(id)configuration workingDirectory:(NSString *)workingDirectory runtime:(nullable NSString *)runtime;
// Regions and languages the block offers: [{id, name, portal}], [locale].
// Empty for a service that asks neither ("steam").
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)regionsOfConfiguration:(NSDictionary *)configuration;
+ (NSArray<NSString *> *)localesOfConfiguration:(NSDictionary *)configuration;
// Whether what a profile's download fetches is in Documents: its executable
// and, for "steam", steam.exe in the working directory.
+ (BOOL)profileIsInPlace:(NSDictionary *)profile documents:(NSString *)documents;

// "blizzard": the build installed for the block's product, from the
// install's .build.info: @{@"region", @"build", @"version"}. Nil when there is
// no row for the product, or its region is not one the block offers.
+ (nullable NSDictionary<NSString *, NSString *> *)installedBuildOfConfiguration:(NSDictionary *)configuration documents:(NSString *)documents;
// "blizzard": the language the install's settings file names, when the block
// offers it; nil otherwise.
+ (nullable NSString *)installedLocaleOfConfiguration:(NSDictionary *)configuration documents:(NSString *)documents
                                     workingDirectory:(NSString *)workingDirectory;

// region and locale: one of each the block offers; nil when it offers none.
- (nullable instancetype)initWithConfiguration:(NSDictionary *)configuration documents:(NSString *)documents
                              workingDirectory:(NSString *)workingDirectory runtime:(nullable NSString *)runtime
                                        region:(nullable NSString *)region locale:(nullable NSString *)locale;
// Tests supply the network; otherwise HTTPS requests.
@property (nonatomic, copy, nullable) TKGameDownloadFetch fetch;
// How much of a large file is asked for at a time (8 MiB); tests use less.
@property (nonatomic) NSUInteger chunk;
// Called on the downloading thread: what is happening and how far along (0 to 1).
@property (nonatomic, copy, nullable) void (^progress)(NSString *phase, double fraction);
// From any thread; -run: then stops with NSUserCancelledError.
- (void)cancel;
// Background thread only.
- (BOOL)run:(NSError **)error;
// "blizzard", background thread only: the build the version server offers now
// for this download's region, @{@"build", @"version"}. Fetches nothing else.
// Running the download again with the same region and language updates an
// install: only application files that changed are fetched, .build.info names
// the new build and saved settings stay; the game fetches its new data itself.
- (nullable NSDictionary<NSString *, NSString *> *)currentBuild:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
