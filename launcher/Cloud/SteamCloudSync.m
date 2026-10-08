#import "SteamCloudSync.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>

static NSError *syncError(NSInteger code) { return [NSError errorWithDomain:@"TolkaraSteamCloudSync" code:code userInfo:nil]; }
static NSString *text(NSData *bytes) { return [bytes isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil; }
static NSString *sha1(NSData *bytes) {
    unsigned char hash[CC_SHA1_DIGEST_LENGTH]; CC_SHA1(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSMutableString *result = [NSMutableString new]; for (unsigned i = 0; i < sizeof hash; i++) [result appendFormat:@"%02x",hash[i]]; return result;
}
@interface TKSteamCloudSync () <NSURLSessionTaskDelegate> {
    uint32_t _appID;
    NSString *_remoteDirectory, *_localDirectory, *_stateDirectory;
    NSArray<NSString *> *_fileNames;
    NSURLSession *_http;
    uint64_t _changeNumber;
}
@end
@implementation TKSteamCloudSync
- (instancetype)initWithAppID:(uint32_t)appID remoteDirectory:(NSString *)remoteDirectory localDirectory:(NSString *)localDirectory stateDirectory:(NSString *)stateDirectory fileNames:(NSArray<NSString *> *)fileNames {
    if ((self = [super init])) { _appID = appID; _remoteDirectory = remoteDirectory; _localDirectory = localDirectory; _stateDirectory = stateDirectory; _fileNames = [fileNames copy]; }
    return self;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response; (void)request; completionHandler(nil);
}
- (NSData *)transfer:(NSDictionary *)metadata host:(unsigned)hostField path:(unsigned)pathField tls:(unsigned)tlsField headers:(unsigned)headersField data:(NSData *)upload error:(NSError **)error {
    NSString *host = text(TKCloudBytes(metadata,hostField)), *path = text(TKCloudBytes(metadata,pathField));
    NSURL *url = host && path ? [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@",host,path]] : nil;
    if (!TKCloudNumber(metadata,tlsField) || !url.host.length || url.user || url.password || ![url.scheme isEqual:@"https"]) { if (error) *error = syncError(10); return nil; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.HTTPMethod = upload ? (hostField==1 && TKCloudNumber(metadata,4)==3 ? @"POST" : @"PUT") : @"GET"; request.HTTPBody = upload;
    for (NSData *headerBytes in metadata[@(headersField)]) {
        NSDictionary *header = TKCloudParse(headerBytes); NSString *name = text(TKCloudBytes(header,1)), *value = text(TKCloudBytes(header,2));
        if (!name.length || !value || [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound || [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) { if (error) *error = syncError(11); return nil; }
        [request setValue:value forHTTPHeaderField:name];
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSData *bytes; __block NSInteger status;
    [[_http dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        if (!failure) { bytes = data; status = [(NSHTTPURLResponse *)response statusCode]; } dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC)) || status < 200 || status >= 300 || bytes.length > 16*1024*1024) { if (error) *error = syncError(12); return nil; }
    return bytes ?: NSData.data;
}
- (NSDictionary *)listing:(TKSteamCloudConnection *)client remote:(NSString *)remote error:(NSError **)error {
    NSDictionary *response = [client call:@"Cloud.GetAppFileChangelist#1" fields:@{@1:@(_appID),@2:@0} error:error];
    if (!response) return nil;
    if (TKCloudNumber(response,3)) { if (error) *error = syncError(20); return nil; }
    _changeNumber = TKCloudNumber(response,1);
    NSArray *prefixes = response[@4] ?: @[]; NSMutableDictionary *files = [NSMutableDictionary new];
    for (NSData *bytes in response[@2]) {
        NSDictionary *info = TKCloudParse(bytes); NSString *name = text(TKCloudBytes(info,1));
        uint64_t prefixIndex = TKCloudNumber(info,7);
        NSString *prefix = prefixIndex < prefixes.count ? text(prefixes[(NSUInteger)prefixIndex]) : @"";
        NSString *fullName = name && prefix ? [prefix stringByAppendingString:name] : nil;
        if (![fullName hasPrefix:remote]) continue;
        NSString *relative = [fullName substringFromIndex:remote.length];
        if (![_fileNames containsObject:relative]) continue;
        NSData *hash = TKCloudBytes(info,2);
        if (files[relative] || hash.length != 20 || TKCloudNumber(info,4) > 16*1024*1024 || TKCloudNumber(info,5) != 0) { if (error) *error = syncError(21); return nil; }
        NSMutableString *hex = [NSMutableString new]; const unsigned char *h = hash.bytes;
        for (unsigned i=0;i<20;i++) [hex appendFormat:@"%02x",h[i]];
        files[relative] = @{@"remoteName":fullName,@"sha1":hex,@"size":@(TKCloudNumber(info,4)),@"timestamp":@(TKCloudNumber(info,3))};
    }
    return files;
}
- (TKSteamCloudConnection *)newConnection { return [TKSteamCloudConnection new]; }
- (BOOL)syncUsername:(NSString *)username token:(NSString *)token allowUpload:(BOOL)allowUpload report:(NSString **)report error:(NSError **)error {
    if(error)*error=nil;if(report)*report=nil;
    for (NSString *name in _fileNames) if (![name isKindOfClass:NSString.class] || ![name isEqual:name.lastPathComponent] || [name isEqual:@"."] || [name isEqual:@".."] || !name.length) { if (error) *error = syncError(30); return NO; }
    TKSteamCloudConnection *client = [self newConnection];
    if (![client connectWithUsername:username token:token error:error]) return NO;
    @try {
        NSString *remote = [_remoteDirectory stringByReplacingOccurrencesOfString:@"${SteamID}" withString:[NSString stringWithFormat:@"%llu",(unsigned long long)client.steamID]];
        NSDictionary *listing = [self listing:client remote:remote error:error]; if (!listing) return NO;
        NSString *baselinePath = [_stateDirectory stringByAppendingPathComponent:@"baseline.json"];
        NSData *baselineBytes = [NSData dataWithContentsOfFile:baselinePath];
        NSDictionary *baseline = baselineBytes ? [NSJSONSerialization JSONObjectWithData:baselineBytes options:0 error:nil] : nil;
        if (baselineBytes && (![baseline isKindOfClass:NSDictionary.class] || ![baseline[@"appID"] isKindOfClass:NSNumber.class] || ![baseline[@"files"] isKindOfClass:NSDictionary.class] || [baseline[@"appID"] unsignedIntValue] != _appID || ![baseline[@"steamID"] isEqual:@(client.steamID)])) { if (error) *error = syncError(31); return NO; }
        NSMutableDictionary *local = [NSMutableDictionary new], *pull = [NSMutableDictionary new], *push = [NSMutableDictionary new];
        NSDictionary *previous = baseline[@"files"];
        for(id name in previous) if(![name isKindOfClass:NSString.class] || ![previous[name] isKindOfClass:NSString.class] || [previous[name] length]!=40 || [previous[name] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound) { if(error)*error=syncError(31);return NO; }
        for (NSString *name in _fileNames) {
            NSString *path = [_localDirectory stringByAppendingPathComponent:name]; struct stat st;
            if (!lstat(path.fileSystemRepresentation,&st) && (!S_ISREG(st.st_mode) || st.st_size > 16*1024*1024)) { if (error) *error = syncError(32); return NO; }
            NSData *bytes = [NSData dataWithContentsOfFile:path]; if (bytes) local[name] = bytes;
            NSString *localHash = bytes ? sha1(bytes) : nil, *remoteHash = listing[name][@"sha1"], *oldHash = previous[name];
            if (!baseline) { if (remoteHash) pull[name] = listing[name]; continue; }
            if (!oldHash || !remoteHash || !localHash) { if (error) *error = syncError(33); return NO; }
            BOOL localChanged = ![localHash isEqual:oldHash], remoteChanged = ![remoteHash isEqual:oldHash];
            if (localChanged && remoteChanged && ![localHash isEqual:remoteHash]) { if (error) *error = syncError(34); if (report) *report = @"Steam Cloud conflict: both copies changed. No saves were overwritten."; return NO; }
            if (remoteChanged && ![localHash isEqual:remoteHash]) pull[name] = listing[name];
            else if (localChanged && ![localHash isEqual:remoteHash]) push[name] = bytes;
        }
        if (listing.count != _fileNames.count) { if (error) *error = syncError(35); return NO; }
        if (push.count && !allowUpload) { if (error) *error = syncError(36); if (report) *report = @"Local changes need an upload; this run permits downloads only."; return NO; }
        if (pull.count && self.localGameRunning) { if (error) *error = syncError(49); if (report) *report = @"Remote saves changed while the game is running. Reopen the game to load them; local saves preserved."; return NO; }
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration; configuration.timeoutIntervalForRequest=45;configuration.timeoutIntervalForResource=90;
        _http = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
        NSMutableDictionary *downloads = [NSMutableDictionary new];
        for (NSString *name in pull) {
            NSDictionary *info = pull[name];
            NSDictionary *metadata = [client call:@"Cloud.ClientFileDownload#1" fields:@{@1:@(_appID),@2:info[@"remoteName"]} error:error];
            if (!metadata || TKCloudNumber(metadata,6) || TKCloudNumber(metadata,11)) { if (error && !*error) *error = syncError(40); return NO; }
            NSData *bytes = [self transfer:metadata host:7 path:8 tls:9 headers:10 data:nil error:error];
            if (!bytes || bytes.length != [info[@"size"] unsignedLongLongValue] || ![sha1(bytes) isEqual:info[@"sha1"]]) { if (error && !*error) *error = syncError(41); return NO; }
            downloads[name] = bytes;
        }
        NSFileManager *manager = NSFileManager.defaultManager;
        if (![manager createDirectoryAtPath:_stateDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] || ![manager createDirectoryAtPath:_localDirectory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        if (pull.count || push.count) {
            NSString *backup = [_stateDirectory stringByAppendingPathComponent:[@"backup-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if (![manager createDirectoryAtPath:backup withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
            for (NSString *name in local) if (![local[name] writeToFile:[backup stringByAppendingPathComponent:[@"local-" stringByAppendingString:name]] options:NSDataWritingAtomic error:error]) return NO;
            for (NSString *name in downloads) if (![downloads[name] writeToFile:[backup stringByAppendingPathComponent:[@"remote-" stringByAppendingString:name]] options:NSDataWritingAtomic error:error]) return NO;
        }
        uint64_t batchID = 0;
        if (push.count) {
            // Saves must remain byte-for-byte stable across a short interval.
            // A partially written file never becomes a Cloud upload snapshot.
            usleep(2000000);
            for (NSString *name in push) if (![[NSData dataWithContentsOfFile:[_localDirectory stringByAppendingPathComponent:name]] isEqual:push[name]]) { if (error) *error = syncError(44); return NO; }
            NSDictionary *current = [self listing:client remote:remote error:error];
            if (!current || ![current isEqual:listing]) { if (error && !*error) *error = syncError(45); return NO; }
            uint64_t expectedChange = _changeNumber;
            NSMutableArray *names = [NSMutableArray new]; for (NSString *name in push) [names addObject:listing[name][@"remoteName"]];
            NSDictionary *batch = [client call:@"Cloud.BeginAppUploadBatch#1" fields:@{@1:@(_appID),@2:@"Tolkara",@3:names,@5:@(client.clientID)} error:error];
            batchID = TKCloudNumber(batch,1);
            if (!batchID) { if (error && !*error) *error = syncError(46); return NO; }
            if (TKCloudNumber(batch,4) != expectedChange + 1) {
                [client call:@"Cloud.CompleteAppUploadBatchBlocking#1" fields:@{@1:@(_appID),@2:@(batchID),@3:@2} error:nil];
                if (error) *error = syncError(47); return NO;
            }
        }
        BOOL completed = NO;
        @try { for (NSString *name in push) {
            NSData *bytes = push[name]; NSString *fullName = listing[name][@"remoteName"];
            unsigned char digest[20];CC_SHA1(bytes.bytes,(CC_LONG)bytes.length,digest);
            NSData *binaryHash=[NSData dataWithBytes:digest length:20];
            NSDictionary *metadata = [client call:@"Cloud.ClientBeginFileUpload#1" fields:@{@1:@(_appID),@2:@(bytes.length),@3:@(bytes.length),@4:binaryHash,@5:@((uint64_t)NSDate.date.timeIntervalSince1970),@6:fullName,@7:@UINT32_MAX,@10:@NO,@13:@(batchID)} error:error];
            if(!metadata || TKCloudNumber(metadata,1))return NO;
            NSMutableIndexSet *coverage=[NSMutableIndexSet new];
            for(NSData *blockBytes in metadata[@2]) {
                NSDictionary *block=TKCloudParse(blockBytes);
                uint64_t offset=TKCloudNumber(block,6),length=TKCloudNumber(block,7),method=TKCloudNumber(block,4);
                NSData *explicitBody=TKCloudBytes(block,8);
                if(!block || (method!=3 && method!=4) || offset>bytes.length || length>bytes.length-offset) { if(error)*error=syncError(50);return NO; }
                NSData *payload=explicitBody ?: [bytes subdataWithRange:NSMakeRange((NSUInteger)offset,(NSUInteger)length)];
                if(!explicitBody)[coverage addIndexesInRange:NSMakeRange((NSUInteger)offset,(NSUInteger)length)];
                if(![self transfer:block host:1 path:2 tls:3 headers:5 data:payload error:error])return NO;
            }
            if([metadata[@2] count] && ![coverage containsIndexesInRange:NSMakeRange(0,bytes.length)]) {if(error)*error=syncError(51);return NO;}
            NSDictionary *commit = [client call:@"Cloud.ClientCommitFileUpload#1" fields:@{@1:@YES,@2:@(_appID),@3:binaryHash,@4:fullName} error:error];
            if (!commit || !TKCloudNumber(commit,1)) { if (error && !*error) *error = syncError(42); return NO; }
        }
            if (batchID && ![client call:@"Cloud.CompleteAppUploadBatchBlocking#1" fields:@{@1:@(_appID),@2:@(batchID),@3:@1} error:error]) return NO;
            completed = YES;
        } @finally {
            if (batchID && !completed) [client call:@"Cloud.CompleteAppUploadBatchBlocking#1" fields:@{@1:@(_appID),@2:@(batchID),@3:@2} error:nil];
        }
        if (push.count) {
            NSDictionary *verified = [self listing:client remote:remote error:error]; if (!verified) return NO;
            for (NSString *name in push) if (![verified[name][@"sha1"] isEqual:sha1(push[name])]) { if (error) *error = syncError(43); return NO; }
        }
        // Re-read before replacing to preserve a save written during the network operation.
        for (NSString *name in downloads) {
            NSData *now = [NSData dataWithContentsOfFile:[_localDirectory stringByAppendingPathComponent:name]];
            NSData *before = local[name];
            if ((now || before) && ![now isEqual:before]) { if (error) *error = syncError(44); return NO; }
        }
        for (NSString *name in downloads) if (![downloads[name] writeToFile:[_localDirectory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) return NO;
        NSMutableDictionary *hashes = [NSMutableDictionary new];
        // The baseline is what both sides now hold: an uploaded file's bytes, and
        // otherwise the listing synchronized against. A file another device
        // changed during the upload stays a remote change for the next sync.
        for (NSString *name in listing) hashes[name] = push[name] ? sha1(push[name]) : listing[name][@"sha1"];
        NSData *state = [NSJSONSerialization dataWithJSONObject:@{@"appID":@(_appID),@"steamID":@(client.steamID),@"files":hashes} options:NSJSONWritingPrettyPrinted error:error];
        if (!state || ![state writeToFile:baselinePath options:NSDataWritingAtomic error:error]) return NO;
        chmod(baselinePath.fileSystemRepresentation,0600);
        if (report) *report = [NSString stringWithFormat:@"Steam Cloud synchronized: %lu downloaded, %lu uploaded, %lu verified files.",(unsigned long)pull.count,(unsigned long)push.count,(unsigned long)listing.count];
        return YES;
    } @finally { [client disconnect]; [_http invalidateAndCancel]; _http = nil; }
}
@end
