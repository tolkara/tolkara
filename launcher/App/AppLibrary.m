#import "AppLibrary.h"
#import "GuestImage.h"
#import "GuestModule.h"
#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const TKModulesDirectory=@"GuestModules";

static BOOL library_error(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"TKAppLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *real_path(NSString *path) {
    char buffer[PATH_MAX];
    return realpath(path.fileSystemRepresentation,buffer) ? @(buffer) : nil;
}
// Relative to Documents, without escapes. An empty string is Documents itself.
static BOOL valid_relative(id path, BOOL allowEmpty) {
    if (![path isKindOfClass:NSString.class] || [path length]>4096) return NO;
    if (![path length]) return allowEmpty;
    if ([path hasPrefix:@"/"] || [path hasSuffix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static BOOL valid_hash(id hash) {
    if (![hash isKindOfClass:NSString.class] || [hash length]!=64) return NO;
    return [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static NSString *join(NSString *directory, NSString *relative) {
    return relative.length ? [directory stringByAppendingPathComponent:relative] : directory;
}
// caseAliases, as tools/check_profile.py checks them: each alias a relative
// path, each target a name that differs from the alias's last component only in case.
static BOOL valid_case_aliases(id aliases) {
    if (!aliases) return YES;
    if (![aliases isKindOfClass:NSDictionary.class]) return NO;
    for (id alias in aliases) {
        id target=aliases[alias];
        if (!valid_relative(alias,NO) || !valid_relative(target,NO) || [target containsString:@"/"]) return NO;
        NSString *leaf=[alias lastPathComponent];
        if ([target isEqualToString:leaf] || [target caseInsensitiveCompare:leaf]!=NSOrderedSame) return NO;
    }
    return YES;
}
static BOOL inside_folder(NSString *path, NSString *root) {
    return path && ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]);
}
// A compatibility runtime's command line is plain strings, bounded like
// tools/check_profile.py: at most 64 arguments or variables of 4096 bytes.
static BOOL valid_arguments(id arguments) {
    if (![arguments isKindOfClass:NSArray.class] || [arguments count]>64) return NO;
    for (id argument in arguments) if (![argument isKindOfClass:NSString.class] || [argument length]>4096) return NO;
    return YES;
}
static BOOL valid_environment(id environment) {
    if (![environment isKindOfClass:NSDictionary.class] || [environment count]>64) return NO;
    NSCharacterSet *word=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"];
    for (id name in environment) {
        if (![name isKindOfClass:NSString.class] || ![name length] || [name length]>256 || isdigit([name characterAtIndex:0])) return NO;
        if ([name rangeOfCharacterFromSet:word.invertedSet].location!=NSNotFound) return NO;
        if (![environment[name] isKindOfClass:NSString.class] || [environment[name] length]>4096) return NO;
    }
    return YES;
}
// libraries, as tools/check_profile.py checks them: at most 64 paths inside
// the runtime's folder, so only with a runtime.
static BOOL valid_libraries(id libraries) {
    if (![libraries isKindOfClass:NSArray.class] || [libraries count]>64) return NO;
    for (id library in libraries) if (!valid_relative(library,NO)) return NO;
    return YES;
}
// codePool, as tools/check_profile.py checks it: 1 to 1024 megabytes, only with a runtime.
static BOOL valid_code_pool(id size) {
    return [size isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)size)!=CFBooleanGetTypeID() &&
           [size doubleValue]==[size integerValue] &&
           [size integerValue]>=1 && [size integerValue]<=1024;
}
static NSString *clean_name(id name) {
    if (![name isKindOfClass:NSString.class]) return nil;
    NSString *trimmed=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    return trimmed.length>100 ? [trimmed substringToIndex:100] : trimmed;
}

@interface TKApp ()
@property(nonatomic, copy) NSDictionary *record;
// The profile the record came from, for its command line; nil for a plain app.
@property(nonatomic, copy, nullable) NSDictionary *launchProfile;
@end
@implementation TKApp
+ (instancetype)appWithRecord:(NSDictionary *)record {
    NSString *source=record[@"source"];
    if (![record[@"id"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:record[@"id"]]) return nil;
    if (!clean_name(record[@"name"]) || !valid_relative(record[@"executable"],NO) || !valid_relative(record[@"workingDirectory"],YES)) return nil;
    if (![source isEqual:@"documents"] && !([source isEqual:@"copy"] && valid_hash(record[@"sha256"]))) return nil;
    if (record[@"sha256"] && !valid_hash(record[@"sha256"])) return nil;
    if (record[@"profile"] && ![record[@"profile"] isKindOfClass:NSString.class]) return nil;
    if (![record[@"added"] isKindOfClass:NSNumber.class]) return nil;
    if (record[@"lastLaunched"] && ![record[@"lastLaunched"] isKindOfClass:NSNumber.class]) return nil;
    TKApp *app=[TKApp new]; app.record=record; return app;
}
- (NSString *)identifier { return self.record[@"id"]; }
- (NSString *)name { return self.record[@"name"]; }
- (TKAppSource)source { return [self.record[@"source"] isEqual:@"copy"] ? TKAppSourceCopy : TKAppSourceDocuments; }
- (NSString *)executable { return self.record[@"executable"]; }
- (NSString *)workingDirectory { return self.record[@"workingDirectory"]; }
- (NSString *)sha256 { return self.record[@"sha256"]?:@""; }
- (NSString *)profile { return self.record[@"profile"]; }
- (NSArray<NSString *> *)arguments { return self.launchProfile[@"arguments"]?:@[]; }
- (NSDictionary<NSString *, NSString *> *)environment { return self.launchProfile[@"environment"]?:@{}; }
- (NSString *)runtime { return self.launchProfile[@"runtime"]; }
- (NSArray<NSString *> *)libraries { return self.launchProfile[@"libraries"]?:@[]; }
- (NSUInteger)codePool { return [self.launchProfile[@"codePool"] unsignedIntegerValue]; }
- (NSDate *)added { return [NSDate dateWithTimeIntervalSince1970:[self.record[@"added"] doubleValue]]; }
- (NSDate *)lastLaunched {
    NSNumber *value=self.record[@"lastLaunched"];
    return value ? [NSDate dateWithTimeIntervalSince1970:value.doubleValue] : nil;
}
- (NSString *)description { return [NSString stringWithFormat:@"<TKApp %@ %@>",self.name,self.executable]; }
@end

@implementation TKAppLibrary {
    NSString *_documents, *_storage, *_loadWarning;
    NSArray<NSDictionary *> *_profiles;
    NSMutableArray<NSDictionary *> *_records;
    NSMutableSet<NSString *> *_dismissedProfiles;
    BOOL _legacyImported;
}

+ (NSArray<NSDictionary *> *)profilesInDirectory:(NSString *)directory {
    NSMutableArray *profiles=[NSMutableArray new];
    NSMutableSet *seen=[NSMutableSet new];
    NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name.pathExtension isEqual:@"json"]) continue;
        NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        id profile=data.length && data.length<=65536 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        // Same rules as tools/check_profile.py: data only, paths inside Documents.
        if (![profile isKindOfClass:NSDictionary.class] || !clean_name(profile[@"name"]) ||
            ![profile[@"id"] isKindOfClass:NSString.class] || ![profile[@"id"] length] || [seen containsObject:profile[@"id"]] ||
            !valid_relative(profile[@"workingDirectory"],NO) || !valid_relative(profile[@"executable"],NO) ||
            !valid_case_aliases(profile[@"caseAliases"])) continue;
        if ((profile[@"runtime"] && !valid_relative(profile[@"runtime"],NO)) ||
            (profile[@"arguments"] && !valid_arguments(profile[@"arguments"])) ||
            (profile[@"environment"] && !valid_environment(profile[@"environment"])) ||
            (profile[@"libraries"] && (!profile[@"runtime"] || !valid_libraries(profile[@"libraries"]))) ||
            (profile[@"codePool"] && (!profile[@"runtime"] || !valid_code_pool(profile[@"codePool"])))) continue;
        [seen addObject:profile[@"id"]];
        [profiles addObject:profile];
    }
    return profiles;
}
+ (NSString *)executableOfProfile:(NSDictionary *)profile {
    return join(profile[@"runtime"]?:profile[@"workingDirectory"],profile[@"executable"]);
}
// TKApp for a stored record, carrying its profile's command line.
- (TKApp *)appForRecord:(NSDictionary *)record {
    TKApp *app=[TKApp appWithRecord:record];
    if (app && record[@"profile"])
        for (NSDictionary *profile in _profiles) if ([profile[@"id"] isEqual:record[@"profile"]]) { app.launchProfile=profile; break; }
    return app;
}

- (instancetype)initWithDocuments:(NSString *)documents storage:(NSString *)storage profiles:(NSArray<NSDictionary *> *)profiles {
    if (!(self=[super init])) return nil;
    _documents=documents.copy; _storage=storage.copy; _profiles=profiles.copy;
    _records=[NSMutableArray new]; _dismissedProfiles=[NSMutableSet new];
    NSString *path=[self libraryPath];
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!data) return self;
    id value=data.length<=4*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"format"] isEqual:@1] || ![value[@"apps"] isKindOfClass:NSArray.class]) {
        // Keep the damaged file for inspection rather than overwrite it.
        NSString *aside=[path stringByAppendingFormat:@".damaged-%@",NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:aside error:NULL];
        _loadWarning=[NSString stringWithFormat:@"The app library could not be read and was reset. The old file was kept as %@.",aside.lastPathComponent];
        return self;
    }
    NSMutableSet *identifiers=[NSMutableSet new];
    for (id record in value[@"apps"]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        TKApp *app=[TKApp appWithRecord:record];
        if (!app || [identifiers containsObject:app.identifier]) continue;
        [identifiers addObject:app.identifier];
        [_records addObject:record];
    }
    for (id profile in value[@"dismissedProfiles"]) if ([profile isKindOfClass:NSString.class]) [_dismissedProfiles addObject:profile];
    _legacyImported=[value[@"legacyImported"] isEqual:@YES];
    return self;
}

- (NSString *)libraryPath { return [_storage stringByAppendingPathComponent:@"apps.json"]; }
- (NSString *)modulesRoot { return [_documents stringByAppendingPathComponent:TKModulesDirectory]; }
- (NSString *)loadWarning { @synchronized (self) { return _loadWarning; } }

// Caller holds the lock.
- (BOOL)saveRecords:(NSArray *)records dismissed:(NSSet *)dismissed legacy:(BOOL)legacy error:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtPath:_storage withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSDictionary *value=@{@"format":@1,@"apps":records,
        @"dismissedProfiles":[dismissed.allObjects sortedArrayUsingSelector:@selector(compare:)],@"legacyImported":@(legacy)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if (!data || ![data writeToFile:[self libraryPath] options:NSDataWritingAtomic error:error]) return NO;
    _records=[records mutableCopy]; _dismissedProfiles=[dismissed mutableCopy]; _legacyImported=legacy;
    return YES;
}

- (NSArray<TKApp *> *)apps {
    NSMutableArray *apps=[NSMutableArray new];
    @synchronized (self) { for (NSDictionary *record in _records) [apps addObject:[self appForRecord:record]]; }
    [apps sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(TKApp *a, TKApp *b) {
        if (a.lastLaunched || b.lastLaunched) {
            if (!b.lastLaunched) return NSOrderedAscending;
            if (!a.lastLaunched) return NSOrderedDescending;
            return [b.lastLaunched compare:a.lastLaunched];
        }
        return [a.added compare:b.added];
    }];
    return apps;
}
- (TKApp *)appWithIdentifier:(NSString *)identifier {
    for (TKApp *app in self.apps) if ([app.identifier isEqual:identifier]) return app;
    return nil;
}
- (TKApp *)defaultApp {
    NSArray<TKApp *> *apps=self.apps;
    if (apps.firstObject.lastLaunched) return apps.firstObject;
    // An app with its resources beats a bare executable copy.
    for (TKApp *app in apps) if (app.source==TKAppSourceDocuments) return app;
    return apps.firstObject;
}

// Documents-relative path of an existing path inside Documents, or nil.
- (NSString *)relativeInDocuments:(NSString *)path {
    NSString *root=real_path(_documents), *real=real_path(path);
    if (!root || !real || ![real hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    return [real substringFromIndex:root.length+1];
}
// Name and working directory for .../Name.app/Contents/MacOS/executable, so the
// application finds its bundle resources next to the executable.
- (NSDictionary *)describeExecutable:(NSString *)relative {
    for (NSDictionary *profile in _profiles)
        if ([[TKAppLibrary executableOfProfile:profile].stringByStandardizingPath isEqual:relative])
            return @{@"name":clean_name(profile[@"name"]),@"workingDirectory":profile[@"workingDirectory"],@"profile":profile[@"id"]};
    NSArray<NSString *> *parts=relative.pathComponents;
    NSUInteger n=parts.count;
    if (n>=4 && [parts[n-2] isEqual:@"MacOS"] && [parts[n-3] isEqual:@"Contents"] && [parts[n-4].pathExtension isEqual:@"app"]) {
        NSString *bundle=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,n-3)]];
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[join(_documents,bundle) stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *name=clean_name(info[@"CFBundleDisplayName"])?:clean_name(info[@"CFBundleName"])?:clean_name(parts[n-4].stringByDeletingPathExtension);
        NSString *directory=n>4 ? [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,n-4)]] : @"";
        return @{@"name":name?:parts[n-1],@"workingDirectory":directory};
    }
    return @{@"name":parts[n-1],@"workingDirectory":n>1 ? relative.stringByDeletingLastPathComponent : @""};
}
- (NSString *)nameForCopiedSource:(NSString *)source {
    NSArray<NSString *> *parts=source.pathComponents;
    NSUInteger n=parts.count;
    if (n>=4 && [parts[n-2] isEqual:@"MacOS"] && [parts[n-3] isEqual:@"Contents"] && [parts[n-4].pathExtension isEqual:@"app"])
        return clean_name(parts[n-4].stringByDeletingPathExtension)?:parts[n-1];
    return clean_name(source.lastPathComponent)?:@"Imported app";
}

- (TKApp *)addRecord:(NSDictionary *)record error:(NSError **)error {
    @synchronized (self) {
        // An entry for the same file (or copy) already exists: refresh its hash.
        // A profile's entry follows the profile when a newer one names another
        // executable (its id, name and launch history stay).
        for (NSUInteger i=0;i<_records.count;i++) {
            NSDictionary *existing=_records[i];
            BOOL documents=[record[@"source"] isEqual:@"documents"] && [existing[@"source"] isEqual:@"documents"];
            BOOL profiled=documents && record[@"profile"] && [existing[@"profile"] isEqual:record[@"profile"]];
            BOOL same=profiled || ([existing[@"source"] isEqual:record[@"source"]] &&
                ([record[@"source"] isEqual:@"copy"] ? [existing[@"sha256"] isEqual:record[@"sha256"]] : [existing[@"executable"] isEqual:record[@"executable"]]));
            if (!same) continue;
            NSMutableArray *records=[_records mutableCopy];
            NSMutableDictionary *updated=[existing mutableCopy];
            if (record[@"sha256"]) updated[@"sha256"]=record[@"sha256"];
            if (profiled) { updated[@"executable"]=record[@"executable"]; updated[@"workingDirectory"]=record[@"workingDirectory"]; }
            records[i]=updated;
            NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
            if (updated[@"profile"]) [dismissed removeObject:updated[@"profile"]];
            return [self saveRecords:records dismissed:dismissed legacy:_legacyImported error:error] ? [self appForRecord:updated] : nil;
        }
        NSMutableDictionary *added=[record mutableCopy];
        added[@"id"]=NSUUID.UUID.UUIDString;
        added[@"added"]=@(NSDate.date.timeIntervalSince1970);
        TKApp *app=[self appForRecord:added];
        if (!app) { library_error(error,@"The app entry is invalid."); return nil; }
        NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
        if (added[@"profile"]) [dismissed removeObject:added[@"profile"]];
        return [self saveRecords:[_records arrayByAddingObject:added] dismissed:dismissed legacy:_legacyImported error:error] ? app : nil;
    }
}

// An application bundle stands for the executable its Info.plist names.
static NSString *bundle_executable(NSString *path, NSError **error) {
    BOOL directory=NO;
    if (![path.pathExtension isEqual:@"app"] || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) return path;
    NSString *name=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleExecutable"];
    if (![name isKindOfClass:NSString.class] || !name.length || [name containsString:@"/"] || [name isEqual:@".."]) {
        library_error(error,@"This application bundle does not name a macOS executable."); return nil;
    }
    return [path stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:name]];
}

- (TKApp *)importExecutable:(NSString *)path copy:(BOOL)copy error:(NSError **)error {
    path=bundle_executable(path,error);
    if (!path) return nil;
    NSString *relative=copy ? nil : [self relativeInDocuments:path];
    NSString *modules=[TKModulesDirectory stringByAppendingString:@"/"];
    if (relative && ![relative hasPrefix:modules]) {
        uint64_t size=0;
        NSString *hash=guest_module_hash(join(_documents,relative),&size,error);
        if (!hash) return nil;
        GuestImage image={0}; char reason[2048];
        if (!gi_load(join(_documents,relative).fileSystemRepresentation,&image,reason,sizeof reason)) {
            library_error(error,[NSString stringWithFormat:@"Unsupported executable: %s",reason]); return nil;
        }
        gi_destroy(&image);
        NSDictionary *described=[self describeExecutable:relative];
        NSMutableDictionary *record=[@{@"source":@"documents",@"executable":relative,@"sha256":hash} mutableCopy];
        [record addEntriesFromDictionary:described];
        return [self addRecord:record error:error];
    }
    // Outside Documents only the picked file is accessible: keep a verified copy.
    NSString *hash=guest_module_import_hash(path,[self modulesRoot],error);
    if (!hash) return nil;
    NSString *directory=[TKModulesDirectory stringByAppendingPathComponent:hash];
    return [self addRecord:@{@"source":@"copy",@"name":[self nameForCopiedSource:path],@"sha256":hash,
        @"executable":[directory stringByAppendingPathComponent:@"OriginalExecutable.bin"],@"workingDirectory":directory} error:error];
}

- (NSArray<TKApp *> *)discover {
    NSMutableArray *found=[NSMutableArray new];
    NSMutableSet *known=[NSMutableSet new], *dismissed;
    BOOL legacyImported;
    @synchronized (self) {
        for (NSDictionary *record in _records) {
            [known addObject:record[@"executable"]];
            if (record[@"sha256"]) [known addObject:record[@"sha256"]];
        }
        dismissed=[_dismissedProfiles copy]; legacyImported=_legacyImported;
    }
    for (NSDictionary *profile in _profiles) {
        NSString *relative=[TKAppLibrary executableOfProfile:profile];
        if ([dismissed containsObject:profile[@"id"]] || [known containsObject:relative]) continue;
        // Recorded by its real location, as an import from the picker would be.
        NSString *real=[self relativeInDocuments:join(_documents,relative)];
        if (!real || [known containsObject:real]) continue;
        struct stat st;
        if (lstat(join(_documents,real).fileSystemRepresentation,&st) || !S_ISREG(st.st_mode)) continue;
        // A runtime is only listed with the application's folder it would start in.
        BOOL directory=NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:join(_documents,profile[@"workingDirectory"]) isDirectory:&directory] || !directory) continue;
        NSString *hash=guest_module_hash(join(_documents,real),NULL,NULL);
        if (!hash) continue;
        NSMutableDictionary *record=[@{@"source":@"documents",@"executable":real,@"sha256":hash} mutableCopy];
        [record addEntriesFromDictionary:[self describeExecutable:real]];
        TKApp *app=[self addRecord:record error:NULL];
        if (app) { [found addObject:app]; [known addObject:real]; [known addObject:hash]; }
    }
    if (!legacyImported) {
        // An older launcher kept a single imported module selected in current.json.
        NSString *path=guest_module_selected([self modulesRoot],NULL);
        NSString *hash=path.stringByDeletingLastPathComponent.lastPathComponent;
        if (path && valid_hash(hash) && ![known containsObject:hash]) {
            NSData *data=[NSData dataWithContentsOfFile:[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"manifest.json"]];
            NSDictionary *manifest=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            NSString *name=[manifest isKindOfClass:NSDictionary.class] ? clean_name(manifest[@"source_name"]) : nil;
            NSString *directory=[TKModulesDirectory stringByAppendingPathComponent:hash];
            TKApp *app=[self addRecord:@{@"source":@"copy",@"name":name?:@"Imported app",@"sha256":hash,
                @"executable":[directory stringByAppendingPathComponent:@"OriginalExecutable.bin"],@"workingDirectory":directory} error:NULL];
            if (app) [found addObject:app];
        }
        @synchronized (self) { [self saveRecords:_records dismissed:_dismissedProfiles legacy:YES error:NULL]; }
    }
    return found;
}

- (BOOL)updateApp:(TKApp *)app error:(NSError **)error change:(void (^)(NSMutableDictionary *record))change {
    @synchronized (self) {
        for (NSUInteger i=0;i<_records.count;i++) {
            if (![_records[i][@"id"] isEqual:app.identifier]) continue;
            NSMutableArray *records=[_records mutableCopy];
            NSMutableDictionary *record=[_records[i] mutableCopy];
            change(record);
            records[i]=record;
            return [self saveRecords:records dismissed:_dismissedProfiles legacy:_legacyImported error:error];
        }
    }
    return library_error(error,@"The app is no longer in the library.");
}
- (BOOL)renameApp:(TKApp *)app to:(NSString *)name error:(NSError **)error {
    NSString *clean=clean_name(name);
    if (!clean) return library_error(error,@"Enter a name.");
    return [self updateApp:app error:error change:^(NSMutableDictionary *record) { record[@"name"]=clean; }];
}
- (BOOL)recordLaunchOfApp:(TKApp *)app error:(NSError **)error {
    return [self updateApp:app error:error change:^(NSMutableDictionary *record) {
        record[@"lastLaunched"]=@(NSDate.date.timeIntervalSince1970);
    }];
}
static BOOL path_inside(id path, NSString *folder) {
    return [path isKindOfClass:NSString.class] && ([path isEqual:folder] || [path hasPrefix:[folder stringByAppendingString:@"/"]]);
}
- (NSArray<NSString *> *)removeApplicationFolder:(NSString *)folder error:(NSError **)error {
    NSString *first=[folder isKindOfClass:NSString.class] ? [folder componentsSeparatedByString:@"/"].firstObject : nil;
    if (!valid_relative(folder,NO) || [first hasPrefix:@"."] ||
        [@[TKModulesDirectory,@"GuestCompatibility",@"LocalSigning"] containsObject:first]) {
        library_error(error,@"Only an application's folder inside Documents can be removed.");
        return nil;
    }
    NSString *path=[_documents stringByAppendingPathComponent:folder], *root=real_path(_documents), *real=real_path(path);
    struct stat info;
    if (lstat(path.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) || !root || !real || !path_inside(real,root) || [real isEqual:root]) {
        library_error(error,@"The folder is not in Documents.");
        return nil;
    }
    NSMutableArray<NSString *> *names=[NSMutableArray new];
    @synchronized (self) {
        NSMutableArray *records=[NSMutableArray new];
        NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
        for (NSDictionary *record in _records) {
            if (path_inside(record[@"executable"],folder) || path_inside(record[@"workingDirectory"],folder)) {
                [names addObject:record[@"name"]?:folder];
                if (record[@"profile"]) [dismissed removeObject:record[@"profile"]];
            } else [records addObject:record];
        }
        for (NSDictionary *profile in _profiles)
            if (path_inside([TKAppLibrary executableOfProfile:profile],folder) || path_inside(profile[@"workingDirectory"],folder)) {
                if (![names containsObject:profile[@"name"]]) [names addObject:profile[@"name"]];
                [dismissed removeObject:profile[@"id"]];
            }
        // Only a folder that holds an application: nothing else of the user's in Documents.
        if (!names.count) { library_error(error,@"The folder holds no application."); return nil; }
        if (![self saveRecords:records dismissed:dismissed legacy:_legacyImported error:error]) return nil;
    }
    if (![NSFileManager.defaultManager removeItemAtPath:path error:error]) return nil;
    return names;
}
- (BOOL)removeApp:(TKApp *)app error:(NSError **)error {
    NSString *unusedCopy=nil;
    @synchronized (self) {
        NSMutableArray *records=[NSMutableArray new];
        NSDictionary *removed=nil;
        for (NSDictionary *record in _records) {
            if ([record[@"id"] isEqual:app.identifier]) removed=record; else [records addObject:record];
        }
        if (!removed) return library_error(error,@"The app is no longer in the library.");
        NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
        // Do not let discovery add a removed profile app back.
        if (removed[@"profile"]) [dismissed addObject:removed[@"profile"]];
        if (!removed[@"profile"])
            for (NSDictionary *profile in _profiles)
                if ([[TKAppLibrary executableOfProfile:profile].stringByStandardizingPath isEqual:removed[@"executable"]])
                    [dismissed addObject:profile[@"id"]];
        if (![self saveRecords:records dismissed:dismissed legacy:_legacyImported error:error]) return NO;
        if ([removed[@"source"] isEqual:@"copy"]) {
            unusedCopy=removed[@"sha256"];
            for (NSDictionary *record in records) if ([record[@"sha256"] isEqual:unusedCopy] && [record[@"source"] isEqual:@"copy"]) unusedCopy=nil;
        }
    }
    if (valid_hash(unusedCopy)) {
        NSString *root=[self modulesRoot], *current=[root stringByAppendingPathComponent:@"current.json"];
        NSData *data=[NSData dataWithContentsOfFile:current];
        NSDictionary *selected=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([selected isKindOfClass:NSDictionary.class] && [selected[@"sha256"] isEqual:unusedCopy])
            [NSFileManager.defaultManager removeItemAtPath:current error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:unusedCopy] error:NULL];
    }
    return YES;
}

- (NSString *)executablePathForApp:(TKApp *)app error:(NSError **)error {
    if (app.source==TKAppSourceCopy) return guest_module_path([self modulesRoot],app.sha256,error);
    NSString *path=join(_documents,app.executable);
    struct stat st;
    if (lstat(path.fileSystemRepresentation,&st)) {
        library_error(error,[NSString stringWithFormat:@"%@ is missing from Documents/%@. Copy it back or import it again.",app.name,app.executable]);
        return nil;
    }
    // Recorded by real path, so a symbolic link here was added afterwards.
    if (!S_ISREG(st.st_mode) || ![[self relativeInDocuments:path] isEqual:app.executable]) {
        library_error(error,@"The executable must be a regular file inside Documents."); return nil;
    }
    return path;
}
- (NSString *)currentSHA256OfApp:(TKApp *)app error:(NSError **)error {
    NSString *path=[self executablePathForApp:app error:error];
    NSString *hash=path ? guest_module_hash(path,NULL,error) : nil;
    if (hash && ![hash isEqual:app.sha256] && app.source==TKAppSourceDocuments)
        [self updateApp:app error:NULL change:^(NSMutableDictionary *record) { record[@"sha256"]=hash; }];
    return hash;
}
- (NSDictionary<NSString *,NSString *> *)caseAliasesForApp:(TKApp *)app {
    if (app.profile) for (NSDictionary *profile in _profiles)
        if ([profile[@"id"] isEqual:app.profile]) return profile[@"caseAliases"]?:@{};
    return @{};
}
- (NSArray<NSString *> *)linkCaseAliasesForApp:(TKApp *)app {
    NSDictionary<NSString *,NSString *> *aliases=[self caseAliasesForApp:app];
    NSMutableArray<NSString *> *report=[NSMutableArray new];
    if (!aliases.count) return report;
    NSString *directory=[self workingDirectoryForApp:app error:NULL], *root=directory ? real_path(directory) : nil;
    if (!root) { [report addObject:@"case aliases skipped: the working directory is missing"]; return report; }
    for (NSString *alias in [aliases.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *target=aliases[alias], *shown=[NSString stringWithFormat:@"case alias %@ -> %@: ",alias,target];
        // Checked where it resolves, then created there: a link in the path cannot lead outside.
        NSString *folder=real_path([root stringByAppendingPathComponent:alias].stringByDeletingLastPathComponent);
        NSString *link=[folder stringByAppendingPathComponent:alias.lastPathComponent];
        struct stat st;
        if (!inside_folder(folder,root)) [report addObject:[shown stringByAppendingString:@"its folder is missing or outside the working directory"]];
        else if (!lstat(link.fileSystemRepresentation,&st)) [report addObject:[shown stringByAppendingString:@"present"]];
        else if (!inside_folder(real_path([folder stringByAppendingPathComponent:target]),root))
            [report addObject:[shown stringByAppendingString:@"the target is missing"]];
        else if (symlink(target.fileSystemRepresentation,link.fileSystemRepresentation))
            [report addObject:[shown stringByAppendingFormat:@"failed: %s",strerror(errno)]];
        else [report addObject:[shown stringByAppendingString:@"linked"]];
    }
    return report;
}
- (NSString *)workingDirectoryForApp:(TKApp *)app error:(NSError **)error {
    NSString *path=join(_documents,app.workingDirectory);
    NSString *relative=app.workingDirectory.length ? [self relativeInDocuments:path] : @"";
    BOOL directory=NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory || ![relative isEqual:app.workingDirectory]) {
        library_error(error,[NSString stringWithFormat:@"The folder Documents/%@ is missing.",app.workingDirectory]); return nil;
    }
    return path;
}
@end
