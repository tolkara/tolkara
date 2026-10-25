#import "SteamCloudSync.h"
#import "SteamCloudCoordinator.h"
#include <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <unistd.h>
#include <zlib.h>
#include <libkern/OSByteOrder.h>

static NSData *bytes(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static NSData *hash(NSData *data) { unsigned char h[20];CC_SHA1(data.bytes,(CC_LONG)data.length,h);return [NSData dataWithBytes:h length:20]; }
// A one-entry deflated zip, the form Steam's own client uploads.
static NSData *zipped(NSData *data) {
    uint8_t out[512];z_stream s={0};assert(deflateInit2(&s,9,Z_DEFLATED,-15,8,Z_DEFAULT_STRATEGY)==Z_OK);
    s.next_in=(Bytef *)data.bytes;s.avail_in=(uInt)data.length;s.next_out=out;s.avail_out=sizeof out;assert(deflate(&s,Z_FINISH)==Z_STREAM_END);deflateEnd(&s);
    uint8_t header[31]={0x50,0x4b,0x03,0x04,20,0,0,0,8,0};header[26]=1;header[30]='Z';
    OSWriteLittleInt32(header,14,(uint32_t)crc32(0,data.bytes,(uInt)data.length));OSWriteLittleInt32(header,18,(uint32_t)s.total_out);OSWriteLittleInt32(header,22,(uint32_t)data.length);
    NSMutableData *zip=[NSMutableData dataWithBytes:header length:sizeof header];[zip appendBytes:out length:s.total_out];return zip;
}
@interface FixtureConnection : TKSteamCloudConnection
@property(nonatomic,strong) NSData *remote;   // save.json
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSData *> *files;
@property(nonatomic,copy) NSString *uploading;
@property(nonatomic,strong) NSDictionary<NSString *,NSData *> *changeAfterBatch;   // another device's write
@property(nonatomic) BOOL corruptDownload, zipDownload;
@property(nonatomic) unsigned uploads;
@end
@implementation FixtureConnection
- (NSMutableDictionary *)files { if(!_files)_files=[NSMutableDictionary new];return _files; }
- (NSData *)remote { return self.files[@"save.json"]; }
- (void)setRemote:(NSData *)remote { self.files[@"save.json"]=remote; }
- (uint64_t)steamID { return 123; } // Synthetic test account; never connected to Steam.
- (BOOL)connectWithUsername:(NSString *)username token:(NSString *)token error:(NSError **)error { (void)username;(void)token;(void)error;return YES; }
- (void)disconnect {}
- (NSDictionary *)call:(NSString *)method fields:(NSDictionary *)fields error:(NSError **)error {
    (void)fields;(void)error;
    if([method isEqual:@"Cloud.GetAppFileChangelist#1"]) {
        NSMutableArray *listed=[NSMutableArray new];
        for(NSString *name in [self.files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSData *data=self.files[name];
            [listed addObject:TKCloudProto(@{@1:name,@2:hash(data),@3:@1234,@4:@(data.length),@5:@0,@7:@0})];
        }
        return TKCloudParse(TKCloudProto(@{@1:@12,@2:listed,@4:@[bytes(@"fixture/")]}));
    }
    if([method isEqual:@"Cloud.ClientFileDownload#1"]) {
        NSString *name=[fields[@2] substringFromIndex:@"fixture/".length];
        NSData *raw=self.files[name],*sent=self.zipDownload?zipped(raw):raw;
        return TKCloudParse(TKCloudProto(@{@2:@(sent.length),@3:@(raw.length),@999:self.corruptDownload?bytes(@"bad download"):sent}));
    }
    if([method isEqual:@"Cloud.BeginAppUploadBatch#1"])return TKCloudParse(TKCloudProto(@{@1:@77,@4:@13}));
    if([method isEqual:@"Cloud.CompleteAppUploadBatchBlocking#1"]) {
        if([fields[@3] unsignedIntValue]==1 && self.changeAfterBatch) { [self.files addEntriesFromDictionary:self.changeAfterBatch];self.changeAfterBatch=nil; }
        return @{};
    }
    if([method isEqual:@"Cloud.ClientBeginFileUpload#1"]) self.uploading=[fields[@6] substringFromIndex:@"fixture/".length];
    if([method isEqual:@"Cloud.ClientBeginFileUpload#1"])return TKCloudParse(TKCloudProto(@{@2:@[TKCloudProto(@{@4:@4,@6:@0,@7:@([fields[@2] unsignedLongLongValue])})]}));
    if([method isEqual:@"Cloud.ClientCommitFileUpload#1"])return TKCloudParse(TKCloudProto(@{@1:@YES}));
    assert(!"unexpected synthetic service call");return nil;
}
@end
@interface TKSteamCloudSync (Fixture)
- (TKSteamCloudConnection *)newConnection;
- (NSData *)transfer:(NSDictionary *)metadata host:(unsigned)host path:(unsigned)path tls:(unsigned)tls headers:(unsigned)headers data:(NSData *)data error:(NSError **)error;
@end
@interface FixtureSync : TKSteamCloudSync
@property(nonatomic,strong) FixtureConnection *fixture;
@end
@implementation FixtureSync
- (TKSteamCloudConnection *)newConnection { return self.fixture; }
- (NSData *)transfer:(NSDictionary *)metadata host:(unsigned)host path:(unsigned)path tls:(unsigned)tls headers:(unsigned)headers data:(NSData *)data error:(NSError **)error {
    (void)host;(void)path;(void)tls;(void)headers;(void)error;
    if(data) { self.fixture.files[self.fixture.uploading]=data;self.fixture.uploads++;return NSData.data; }
    return TKCloudBytes(metadata,999);
}
@end
@interface TKSteamCloudCoordinator (Fixture)
- (void)syncNow;
@end
@interface FixtureCoordinator : TKSteamCloudCoordinator
@property(nonatomic) BOOL callbackRan;
@end
@implementation FixtureCoordinator
- (void)record:(NSString *)report error:(NSError *)error { (void)report;(void)error; }
- (void)syncNow {
    dispatch_semaphore_t callback=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(),^{ self.callbackRan=YES;dispatch_semaphore_signal(callback); });
    assert(!dispatch_semaphore_wait(callback,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
}
@end
static FixtureSync *makeSync(NSString *local,NSString *state,FixtureConnection *connection) {
    FixtureSync *sync=[[FixtureSync alloc] initWithAppID:42 remoteDirectory:@"fixture/" localDirectory:local stateDirectory:state fileNames:@[@"save.json"]];sync.fixture=connection;return sync;
}
int main(void) { @autoreleasepool {
    NSDictionary *fields=@{@1:@UINT64_MAX,@2:bytes(@"hello"),@3:@[@7,@9]};
    NSDictionary *parsed=TKCloudParse(TKCloudProto(fields));assert(TKCloudNumber(parsed,1)==UINT64_MAX);assert([TKCloudBytes(parsed,2) isEqual:bytes(@"hello")]);assert([parsed[@3] count]==2);
    const uint8_t invalid[][12]={{0},{0x12,0x02,0x01},{0x08,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x02},{0x0b},{0x09,0x01}};
    const NSUInteger sizes[]={1,3,11,1,2};
    for(unsigned i=0;i<5;i++)assert(!TKCloudParse([NSData dataWithBytes:invalid[i] length:sizes[i]]));
    uint32_t seed=12345;
    for(unsigned n=0;n<2000;n++) { uint8_t fuzz[64];for(unsigned i=0;i<sizeof fuzz;i++){seed=seed*1664525+1013904223;fuzz[i]=(uint8_t)(seed>>24);} (void)TKCloudParse([NSData dataWithBytes:fuzz length:n%sizeof fuzz]); }
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *local=[root stringByAppendingPathComponent:@"local"],*state=[root stringByAppendingPathComponent:@"state"],*save=[local stringByAppendingPathComponent:@"save.json"];
    assert([NSFileManager.defaultManager createDirectoryAtPath:local withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([bytes(@"local-before-import") writeToFile:save atomically:YES]);
    FixtureConnection *connection=[FixtureConnection new];connection.remote=bytes(@"remote-v1");
    FixtureSync *sync=makeSync(local,state,connection);NSError *error=nil;NSString *report=nil;
    assert([sync syncUsername:@"fixture" token:@"fixture" allowUpload:NO report:&report error:&error]);
    assert([[NSData dataWithContentsOfFile:save] isEqual:connection.remote]);assert(connection.uploads==0);
    NSArray *backups=[NSFileManager.defaultManager contentsOfDirectoryAtPath:state error:nil];BOOL found=NO;
    for(NSString *folder in backups)if([folder hasPrefix:@"backup-"]) { NSData *old=[NSData dataWithContentsOfFile:[[state stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"local-save.json"]];found=[old isEqual:bytes(@"local-before-import")]; }assert(found);
    assert([sync syncUsername:@"fixture" token:@"fixture" allowUpload:NO report:&report error:&error]);assert(connection.uploads==0);
    assert([bytes(@"local-v2") writeToFile:save atomically:YES]);error=nil;
    assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:NO report:&report error:&error]);assert(error.code==36);assert([connection.remote isEqual:bytes(@"remote-v1")]);
    error=nil;assert([sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert([connection.remote isEqual:bytes(@"local-v2")]);assert(connection.uploads==1);
    connection.remote=bytes(@"remote-v3");sync.localGameRunning=YES;error=nil;assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert(error.code==49);assert([[NSData dataWithContentsOfFile:save] isEqual:bytes(@"local-v2")]);sync.localGameRunning=NO;assert([sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert([[NSData dataWithContentsOfFile:save] isEqual:connection.remote]);
    connection.remote=bytes(@"remote-conflict");assert([bytes(@"local-conflict") writeToFile:save atomically:YES]);error=nil;
    assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert(error.code==34);assert(connection.uploads==1);assert([[NSData dataWithContentsOfFile:save] isEqual:bytes(@"local-conflict")]);
    NSString *badLocal=[root stringByAppendingPathComponent:@"bad-local"],*badState=[root stringByAppendingPathComponent:@"bad-state"];
    connection.corruptDownload=YES;sync=makeSync(badLocal,badState,connection);error=nil;
    assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:NO report:&report error:&error]);assert(error.code==41);assert(![NSFileManager.defaultManager fileExistsAtPath:badLocal]);
    NSString *zipLocal=[root stringByAppendingPathComponent:@"zip-local"],*zipState=[root stringByAppendingPathComponent:@"zip-state"];
    connection.corruptDownload=NO;connection.zipDownload=YES;sync=makeSync(zipLocal,zipState,connection);error=nil;
    assert([sync syncUsername:@"fixture" token:@"fixture" allowUpload:NO report:&report error:&error]);
    assert([[NSData dataWithContentsOfFile:[zipLocal stringByAppendingPathComponent:@"save.json"]] isEqual:connection.remote]);
    connection.zipDownload=NO;unlink(save.fileSystemRepresentation);assert(!symlink("/tmp",save.fileSystemRepresentation));sync=makeSync(local,state,connection);error=nil;
    assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert(error.code==32);
    NSData *broken=[NSJSONSerialization dataWithJSONObject:@{@"appID":@42,@"steamID":@123,@"files":@42} options:0 error:nil];assert([broken writeToFile:[state stringByAppendingPathComponent:@"baseline.json"] atomically:YES]);error=nil;
    assert(![sync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);assert(error.code==31);
    // Another device changes b.json after our upload of a.json completes. The
    // baseline keeps b.json's synchronized hash, so the next sync downloads the
    // newer b.json instead of uploading the stale local copy over it.
    NSString *pairLocal=[root stringByAppendingPathComponent:@"pair-local"],*pairState=[root stringByAppendingPathComponent:@"pair-state"];
    FixtureConnection *pair=[FixtureConnection new];pair.files[@"a.json"]=bytes(@"a-1");pair.files[@"b.json"]=bytes(@"b-1");
    FixtureSync *pairSync=[[FixtureSync alloc] initWithAppID:42 remoteDirectory:@"fixture/" localDirectory:pairLocal stateDirectory:pairState fileNames:@[@"a.json",@"b.json"]];pairSync.fixture=pair;
    error=nil;assert([pairSync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);
    assert([bytes(@"a-2") writeToFile:[pairLocal stringByAppendingPathComponent:@"a.json"] atomically:YES]);
    pair.changeAfterBatch=@{@"b.json":bytes(@"b-2")};
    assert([pairSync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);
    assert(pair.uploads==1 && [pair.files[@"a.json"] isEqual:bytes(@"a-2")] && [pair.files[@"b.json"] isEqual:bytes(@"b-2")]);
    assert([pairSync syncUsername:@"fixture" token:@"fixture" allowUpload:YES report:&report error:&error]);
    assert(pair.uploads==1 && [pair.files[@"b.json"] isEqual:bytes(@"b-2")]);
    assert([[NSData dataWithContentsOfFile:[pairLocal stringByAppendingPathComponent:@"b.json"]] isEqual:bytes(@"b-2")]);
    assert([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    FixtureCoordinator *coordinator=[[FixtureCoordinator alloc] initWithProfile:@"fixture" documents:NSTemporaryDirectory() configuration:nil];
    assert(NSThread.isMainThread);[coordinator flush];assert(coordinator.callbackRan);
    // The profile's steamCloud block configures sync with no config.json in
    // Documents. Without a sign-in, a required one refuses to start and an
    // optional one starts unsynchronized; neither touches the local saves.
    NSString *documents=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString].stringByResolvingSymlinksInPath;
    NSString *profile=[@"fixture-" stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:8]];
    NSString *saves=[documents stringByAppendingPathComponent:@"Game/saves"];
    assert([NSFileManager.defaultManager createDirectoryAtPath:saves withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([bytes(@"local-only") writeToFile:[saves stringByAppendingPathComponent:@"save.json"] atomically:YES]);
    NSDictionary *cloud=@{@"appID":@42,@"remoteDirectory":@"fixture/",@"localDirectory":@"Game/saves",@"fileNames":@[@"save.json"],@"required":@YES};
    assert(![TKSteamCloudCoordinator configuredProfile:profile documents:documents configuration:nil]);
    assert([TKSteamCloudCoordinator configuredProfile:profile documents:documents configuration:cloud]);
    TKSteamCloudCoordinator *required=[[TKSteamCloudCoordinator alloc] initWithProfile:profile documents:documents configuration:cloud];
    error=nil;report=nil;assert(![required prepareWithReport:&report error:&error]);assert(error.code==11 && [report containsString:@"not signed in"]);
    NSMutableDictionary *optional=[cloud mutableCopy];optional[@"required"]=@NO;
    TKSteamCloudCoordinator *unsynced=[[TKSteamCloudCoordinator alloc] initWithProfile:profile documents:documents configuration:optional];
    error=nil;report=nil;assert([unsynced prepareWithReport:&report error:&error]);assert(!error && [report containsString:@"without synchronization"]);
    assert([[NSData dataWithContentsOfFile:[saves stringByAppendingPathComponent:@"save.json"]] isEqual:bytes(@"local-only")]);
    NSString *log=[NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:[NSString stringWithFormat:@"SteamCloud/%@/sync.log",profile]] encoding:NSUTF8StringEncoding error:nil];
    assert([log containsString:@"not signed in"]);
    assert([NSFileManager.defaultManager removeItemAtPath:documents error:nil]);
    puts("Steam Cloud: a profile's configuration without config.json; a required sign-in stops the start, an optional one starts unsynchronized PASS");
    puts("Steam Cloud: final flush keeps main-thread callbacks responsive PASS");
    puts("Steam Cloud: bounded protobuf, malformed input, first pull, zipped downloads, backups, uploads, remote changes, conflicts, a remote change during upload and symlink rejection PASS");
} return 0; }
