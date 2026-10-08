#import "SteamCloudCoordinator.h"
#import "SteamCloudSync.h"
#import <Security/Security.h>
#include <sys/stat.h>

static BOOL profileName(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length || name.length > 80) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
static NSError *coordinatorError(NSInteger code) { return [NSError errorWithDomain:@"TolkaraSteamCloudSetup" code:code userInfo:nil]; }
@implementation TKSteamCloudCoordinator {
    NSString *_profile, *_documents, *_directory;
    TKSteamCloudSync *_sync;
    NSDictionary *_credentials;
    BOOL _allowUpload;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
}
+ (BOOL)configuredProfile:(NSString *)profile documents:(NSString *)documents {
    if (!profileName(profile)) return NO;
    NSString *path = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"SteamCloud/%@/config.json",profile]];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}
- (instancetype)initWithProfile:(NSString *)profile documents:(NSString *)documents {
    if (!profileName(profile)) return nil;
    if ((self = [super init])) {
        _profile = profile; _documents = documents.stringByResolvingSymlinksInPath;
        _directory = [_documents stringByAppendingPathComponent:[NSString stringWithFormat:@"SteamCloud/%@",profile]];
        _queue = dispatch_queue_create("local.tolkara.steam-cloud",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)record:(NSString *)report error:(NSError *)error {
    NSString *message = report ?: [NSString stringWithFormat:@"Steam Cloud sync failed (%@:%ld). Saves preserved.",error.domain ?: @"unknown",(long)error.code];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",NSDate.date,message];
    NSString *path = [_directory stringByAppendingPathComponent:@"sync.log"];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (file) { @try { [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile]; } @catch (__unused NSException *exception) {} }
    else [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (NSDictionary *)loadCredentials:(NSError **)error {
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"local.tolkara.steam-cloud",(__bridge id)kSecAttrAccount:_profile};
    NSString *import = [_directory stringByAppendingPathComponent:@"approved-login.json"];
    struct stat st;
    if (!lstat(import.fileSystemRepresentation,&st)) {
        if (!S_ISREG(st.st_mode) || st.st_size > 16384) { if (error) *error = coordinatorError(1); return nil; }
        NSData *data = [NSData dataWithContentsOfFile:import];
        NSDictionary *credentials = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![credentials isKindOfClass:NSDictionary.class] || ![credentials[@"username"] isKindOfClass:NSString.class] || ![credentials[@"refreshToken"] isKindOfClass:NSString.class]) { if (error) *error = coordinatorError(2); return nil; }
        NSDictionary *attributes = @{(__bridge id)kSecValueData:data,
            (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) { NSMutableDictionary *add=[query mutableCopy];[add addEntriesFromDictionary:attributes];status=SecItemAdd((__bridge CFDictionaryRef)add,NULL); }
        if (status != errSecSuccess) { if (error) *error = coordinatorError(3); return nil; }
        if (![NSFileManager.defaultManager removeItemAtPath:import error:error]) return nil;
    }
    NSMutableDictionary *read=[query mutableCopy];read[(__bridge id)kSecReturnData]=@YES;read[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)read,&result);
    NSData *data=CFBridgingRelease(result);
    if(status!=errSecSuccess || ![data isKindOfClass:NSData.class]) { if(error)*error=coordinatorError(4);return nil; }
    NSDictionary *credentials=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![credentials isKindOfClass:NSDictionary.class] || ![credentials[@"username"] isKindOfClass:NSString.class] || ![credentials[@"refreshToken"] isKindOfClass:NSString.class]) { if(error)*error=coordinatorError(5);return nil; }
    return credentials;
}
- (BOOL)prepareWithReport:(NSString **)report error:(NSError **)error {
    NSString *path=[_directory stringByAppendingPathComponent:@"config.json"];
    NSString *rootPrefix=[_documents stringByAppendingString:@"/"];
    if (![_directory.stringByResolvingSymlinksInPath hasPrefix:rootPrefix]) { if(error)*error=coordinatorError(6);return NO; }
    NSData *data=[NSData dataWithContentsOfFile:path];
    NSDictionary *config=data.length && data.length<=65536 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![config isKindOfClass:NSDictionary.class] || ![config[@"appID"] isKindOfClass:NSNumber.class] || ![config[@"remoteDirectory"] isKindOfClass:NSString.class] || ![config[@"localDirectory"] isKindOfClass:NSString.class] || ![config[@"fileNames"] isKindOfClass:NSArray.class]) { if(error)*error=coordinatorError(7);return NO; }
    NSString *relative=config[@"localDirectory"];
    NSString *local=[_documents stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath;
    if(relative.isAbsolutePath || [relative.pathComponents containsObject:@".."] || ![local hasPrefix:rootPrefix] || ![config[@"appID"] unsignedIntValue]) { if(error)*error=coordinatorError(8);return NO; }
    for(id name in config[@"fileNames"]) if(![name isKindOfClass:NSString.class]) { if(error)*error=coordinatorError(9);return NO; }
    if(![config[@"fileNames"] count] || [config[@"fileNames"] count]>64 || [NSSet setWithArray:config[@"fileNames"]].count!=[config[@"fileNames"] count]) { if(error)*error=coordinatorError(10);return NO; }
    _allowUpload=[config[@"uploadsEnabled"] isKindOfClass:NSNumber.class] && [config[@"uploadsEnabled"] boolValue];
    _credentials=[self loadCredentials:error];if(!_credentials)return NO;
    _sync=[[TKSteamCloudSync alloc] initWithAppID:[config[@"appID"] unsignedIntValue] remoteDirectory:config[@"remoteDirectory"] localDirectory:local stateDirectory:[_directory stringByAppendingPathComponent:@"state"] fileNames:config[@"fileNames"]];
    BOOL success=[_sync syncUsername:_credentials[@"username"] token:_credentials[@"refreshToken"] allowUpload:_allowUpload report:report error:error];
    [self record:report?*report:nil error:error?*error:nil];return success;
}
- (void)syncNow {
    if(!_sync || !_credentials)return;
    NSError *error=nil;NSString *report=nil;
    NSData *data=[NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:@"config.json"]];
    NSDictionary *config=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    _allowUpload=[config isKindOfClass:NSDictionary.class] && [config[@"uploadsEnabled"] isKindOfClass:NSNumber.class] && [config[@"uploadsEnabled"] boolValue];
    [_sync syncUsername:_credentials[@"username"] token:_credentials[@"refreshToken"] allowUpload:_allowUpload report:&report error:&error];
    [self record:report error:error];
}
- (void)startPeriodicSync {
    if(_timer)return;
    _sync.localGameRunning=YES;
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),60*NSEC_PER_SEC,5*NSEC_PER_SEC);
    __weak TKSteamCloudCoordinator *weakSelf=self;
    dispatch_source_set_event_handler(_timer,^{[weakSelf syncNow];});dispatch_resume(_timer);
}
- (void)flush {
    void (^sync)(void)=^{
        [self record:@"Steam Cloud final synchronization started." error:nil];
        [self syncNow];
        [self record:@"Steam Cloud final synchronization finished." error:nil];
    };
    if (!NSThread.isMainThread) { dispatch_sync(_queue,sync); return; }
    // Guest exit can run on UIKit's main thread. Keep its run loop alive for
    // URL-session work and UIKit teardown while the final sync drains.
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(_queue,^{ sync(); dispatch_semaphore_signal(done); });
    while (dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)) {
        @autoreleasepool {
            if (![NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]])
                [NSThread sleepForTimeInterval:0.001];
        }
    }
}
- (void)dealloc { if(_timer)dispatch_source_cancel(_timer); }
@end
