#import "GameDownload.h"
#import "BlizzardContent.h"
#import "ZipArchive.h"
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
#import <sys/clonefile.h>
#import <sys/stat.h>

NSString *const TKGameDownloadErrorDomain = @"TKGameDownload";

static NSError *download_error(NSString *message) {
    return [NSError errorWithDomain:TKGameDownloadErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL matches(NSString *text, NSString *pattern) {
    return [text isKindOfClass:NSString.class] &&
        [text rangeOfString:pattern options:NSRegularExpressionSearch].location == 0 &&
        [text rangeOfString:pattern options:NSRegularExpressionSearch].length == text.length;
}
// A relative path of plain components: no "..", no leading "/", no backslash.
static BOOL plain_relative(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || path.length > 512 || [path hasPrefix:@"/"] ||
        [path containsString:@"\\"] || [path containsString:@"//"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static NSString *hex_of(const uint8_t *bytes, int count) {
    NSMutableString *text = [NSMutableString stringWithCapacity:(NSUInteger)count * 2];
    for (int i = 0; i < count; i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}
static NSString *hex(const uint8_t *bytes) { return hex_of(bytes, 16); }
static BOOL under(NSString *path, NSString *folder) { return [path hasPrefix:[folder stringByAppendingString:@"/"]]; }
static BOOL whole_number(id value, uint64_t low, uint64_t high) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [value doubleValue] == (double)[value unsignedLongLongValue] && [value doubleValue] >= (double)low && [value doubleValue] <= (double)high;
}
// "name!TYPE:n|…" header, "## …" comments, then one row per line.
static NSArray<NSDictionary<NSString *, NSString *> *> *table(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray *rows = [NSMutableArray new];
    NSArray<NSString *> *names = nil;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *cells = [line componentsSeparatedByString:@"|"];
        if (!names) {
            NSMutableArray *header = [NSMutableArray new];
            for (NSString *cell in cells) [header addObject:[cell componentsSeparatedByString:@"!"].firstObject];
            names = header; continue;
        }
        if (cells.count != names.count) continue;
        [rows addObject:[NSDictionary dictionaryWithObjects:cells forKeys:names]];
    }
    return rows;
}
// "key = value value" lines.
static NSDictionary<NSString *, NSArray<NSString *> *> *settings(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableDictionary *out = [NSMutableDictionary new];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange equals = [line rangeOfString:@" = "];
        if (equals.location == NSNotFound) continue;
        out[[line substringToIndex:equals.location]] =
            [[line substringFromIndex:NSMaxRange(equals)] componentsSeparatedByString:@" "];
    }
    return out;
}
static BOOL is_key(NSString *key) { return matches(key, @"[0-9a-f]{32}"); }
// JSON true: a boolean, not the number 1.
static BOOL is_true(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && [value boolValue];
}

static bool append_sink(void *context, const uint8_t *bytes, size_t length) {
    [(__bridge NSMutableData *)context appendBytes:bytes length:length];
    return true;
}
static NSData *blte(NSData *data) {
    NSMutableData *out = [NSMutableData new];
    return bc_blte_decode(data.bytes, data.length, append_sink, (__bridge void *)out) ? out : nil;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // MD5 is the content key, not a security measure of ours
static NSString *md5_of_file(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_MD5_CTX context; CC_MD5_Init(&context);
    uint8_t *buffer = malloc(1 << 16);
    NSInteger got;
    while ((got = [stream read:buffer maxLength:1 << 16]) > 0) CC_MD5_Update(&context, buffer, (CC_LONG)got);
    free(buffer); [stream close];
    if (got < 0) return nil;
    uint8_t digest[16]; CC_MD5_Final(digest, &context);
    return hex(digest);
}
typedef struct { NSOutputStream *__unsafe_unretained stream; CC_MD5_CTX md5; uint64_t written; } FileSink;
static bool file_sink(void *context, const uint8_t *bytes, size_t length) {
    FileSink *sink = context;
    CC_MD5_Update(&sink->md5, bytes, (CC_LONG)length);
    while (length) {
        NSInteger wrote = [sink->stream write:bytes maxLength:length];
        if (wrote <= 0) return false;
        bytes += wrote; length -= (size_t)wrote; sink->written += (uint64_t)wrote;
    }
    return true;
}
#pragma clang diagnostic pop

typedef struct { const uint8_t *wanted; size_t count; bool *located; uint32_t *sizes, *offsets; unsigned hits; } IndexSearch;
static void index_visit(void *context, const uint8_t *ekey, uint32_t size, uint32_t offset) {
    IndexSearch *search = context;
    for (size_t i = 0; i < search->count; i++) {
        if (search->located[i] || memcmp(search->wanted + i * 16, ekey, 16)) continue;
        search->located[i] = true; search->sizes[i] = size; search->offsets[i] = offset; search->hits++;
    }
}

#pragma mark Steam's file list

// Valve's text format: "key" "value" pairs and "key" { … } blocks, as
// [[key, value]] with a string or a block's own list for value. Strict:
// quoted strings only, bounded depth, length and count.
typedef struct { const char *at, *end; unsigned left; } VDFText;
// '"' with the string in *text, '{', '}', 0 at the end, -1 for anything else.
static int vdf_token(VDFText *in, NSString **text) {
    for (;;) {
        while (in->at < in->end && (*in->at == ' ' || *in->at == '\t' || *in->at == '\r' || *in->at == '\n')) in->at++;
        if (in->end - in->at >= 2 && in->at[0] == '/' && in->at[1] == '/') { while (in->at < in->end && *in->at != '\n') in->at++; continue; }
        break;
    }
    if (in->at == in->end) return 0;
    char c = *in->at++;
    if (c == '{' || c == '}') return c;
    if (c != '"') return -1;
    NSMutableData *bytes = [NSMutableData new];
    for (;;) {
        if (in->at == in->end || bytes.length > 1024) return -1;
        c = *in->at++;
        if (c == '"') break;
        if (c == '\\') { if (in->at == in->end) return -1; c = *in->at++; }
        if (!c) return -1;
        [bytes appendBytes:&c length:1];
    }
    *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    return *text ? '"' : -1;
}
static NSArray *vdf_block(VDFText *in, int depth) {
    NSMutableArray *items = [NSMutableArray new];
    for (;;) {
        NSString *key = nil, *value = nil;
        int token = vdf_token(in, &key);
        if (token == (depth ? '}' : 0)) return items;
        if (token != '"' || !in->left) return nil;
        in->left--;
        token = vdf_token(in, &value);
        if (token == '"') { [items addObject:@[key, value]]; continue; }
        NSArray *inner = token == '{' && depth < 4 ? vdf_block(in, depth + 1) : nil;
        if (!inner) return nil;
        [items addObject:@[key, inner]];
    }
}
// A file of the server's by its name there, its size (1 byte to 4 GiB) and its SHA-256.
static BOOL package_file(NSString *name, NSString *size, NSString *hash) {
    if (!matches(name, @"[A-Za-z0-9._-]{1,200}") || !plain_relative(name) || !matches(size, @"[0-9]{1,10}") || !matches(hash, @"[0-9a-fA-F]{64}")) return NO;
    unsigned long long bytes = strtoull(size.UTF8String, NULL, 10);
    return bytes && bytes <= 1ull << 32;
}
// The packages of the first block of Valve's list, in its order: each
// {name, bootstrapper, fetch, size, sha256} where fetch is the file to ask
// the server for (the smaller "zipvz" form when the package has one) and
// bootstrapper says the package is an installer, which is always fetched as
// a plain ZIP. Blocks inside a package (other regions' variants of it) are
// not packages. nil for a list that is not understood.
static NSArray<NSDictionary *> *steam_packages(NSData *manifest) {
    if (!manifest.length || manifest.length > 1 << 20) return nil;
    VDFText in = {manifest.bytes, (const char *)manifest.bytes + manifest.length, 4096};
    NSArray *top = vdf_block(&in, 0);
    if (!top.count || ![top[0][1] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *packages = [NSMutableArray new];
    NSMutableSet<NSString *> *names = [NSMutableSet new];
    for (NSArray *item in top[0][1]) {
        if (![item[1] isKindOfClass:NSArray.class]) continue;   // "version", "ostype"
        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary new];
        for (NSArray *field in item[1]) {
            if (![field[1] isKindOfClass:NSString.class]) continue;
            if (fields[field[0]]) return nil;
            fields[field[0]] = field[1];
        }
        BOOL bootstrapper = [fields[@"IsBootstrapperPackage"] isEqual:@"1"];
        NSString *file = fields[@"file"], *size = fields[@"size"], *hash = fields[@"sha2"], *packed = fields[@"zipvz"];
        // Each form a package comes in is checked, also the one that is not fetched.
        if (packages.count == 64 || !matches(item[0], @"[A-Za-z0-9_]{1,64}") || !package_file(file, size, hash)) return nil;
        if (packed) {
            // "name.zip.vz.<hash>_<size>": the size is in the name.
            NSRange underscore = [packed rangeOfString:@"_" options:NSBackwardsSearch];
            NSString *packedSize = underscore.location == NSNotFound ? nil : [packed substringFromIndex:NSMaxRange(underscore)];
            if (!package_file(packed, packedSize, fields[@"sha2vz"])) return nil;
            if (!bootstrapper) { file = packed; size = packedSize; hash = fields[@"sha2vz"]; }
        }
        if ([names containsObject:file]) return nil;
        [names addObject:file];
        unsigned long long bytes = strtoull(size.UTF8String, NULL, 10);
        [packages addObject:@{@"name": item[0], @"bootstrapper": @(bootstrapper), @"fetch": file, @"size": @(bytes), @"sha256": hash.lowercaseString}];
    }
    return packages.count ? packages : nil;
}

#pragma mark Archives

// An archive entry's name as a path of plain components ("\" is Valve's
// separator in places), or nil: an absolute path, "..", a link or a device.
static NSString *entry_path(const ZAEntry *entry, BOOL *directory) {
    NSString *name = [[NSString alloc] initWithBytes:entry->name length:entry->name_length encoding:NSUTF8StringEncoding];
    name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    mode_t kind = entry->mode & S_IFMT;
    *directory = [name hasSuffix:@"/"] || kind == S_IFDIR;
    if ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
    if ((kind && kind != S_IFREG && kind != S_IFDIR) || (*directory && entry->size)) return nil;
    return plain_relative(name) ? name : nil;
}
typedef struct { int fd; atomic_bool *cancelled; NSMutableData *__unsafe_unretained data; } EntrySink;
static bool entry_sink(void *context, const uint8_t *bytes, size_t length) {
    EntrySink *sink = context;
    if (atomic_load(sink->cancelled)) return false;
    if (sink->data) { [sink->data appendBytes:bytes length:length]; return true; }
    while (length) {
        ssize_t wrote = write(sink->fd, bytes, length);
        if (wrote <= 0) return false;
        bytes += wrote; length -= (size_t)wrote;
    }
    return true;
}

@implementation TKGameDownload {
    NSDictionary *_configuration;
    NSString *_root, *_working, *_region, *_locale, *_runtime;
    atomic_bool _cancelled;
    NSURLSession *_session;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)regionsOfConfiguration:(NSDictionary *)configuration { return configuration[@"regions"] ?: @[]; }
+ (NSArray<NSString *> *)localesOfConfiguration:(NSDictionary *)configuration { return configuration[@"locales"] ?: @[]; }

+ (BOOL)profileIsInPlace:(NSDictionary *)profile documents:(NSString *)documents {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *working = [documents stringByAppendingPathComponent:profile[@"workingDirectory"]];
    NSString *home = profile[@"runtime"] ? [documents stringByAppendingPathComponent:profile[@"runtime"]] : working;
    if (![files fileExistsAtPath:[home stringByAppendingPathComponent:profile[@"executable"]]]) return NO;
    return ![profile[@"download"][@"service"] isEqual:@"steam"] || [files fileExistsAtPath:[working stringByAppendingPathComponent:@"steam.exe"]];
}

+ (BOOL)offersUpdates:(NSDictionary *)configuration {
    return [configuration isKindOfClass:NSDictionary.class] && [configuration[@"service"] isEqual:@"blizzard"] && is_true(configuration[@"update"]);
}

+ (NSDictionary<NSString *, NSString *> *)installedBuildOfConfiguration:(NSDictionary *)configuration documents:(NSString *)documents {
    if (![configuration[@"service"] isEqual:@"blizzard"] || !plain_relative(configuration[@"root"])) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[[documents stringByAppendingPathComponent:configuration[@"root"]] stringByAppendingPathComponent:@".build.info"]];
    for (NSDictionary<NSString *, NSString *> *row in data ? table(data) : @[]) {
        if (![row[@"Product"] isEqual:configuration[@"product"]] || !is_key(row[@"Build Key"])) continue;
        for (NSDictionary *region in configuration[@"regions"]) if ([region[@"id"] isEqual:row[@"Branch"]])
            return @{@"region": row[@"Branch"], @"build": row[@"Build Key"], @"version": row[@"Version"] ?: @""};
    }
    return nil;
}

+ (NSString *)installedLocaleOfConfiguration:(NSDictionary *)configuration documents:(NSString *)documents workingDirectory:(NSString *)workingDirectory {
    NSDictionary *file = configuration[@"settings"];
    if (![file isKindOfClass:NSDictionary.class] || !plain_relative(workingDirectory) || !plain_relative(file[@"file"])) return nil;
    NSString *path = [[documents stringByAppendingPathComponent:workingDirectory] stringByAppendingPathComponent:file[@"file"]];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSString *prefix = [NSString stringWithFormat:@"SET %@ \"", file[@"text"]];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:prefix] || ![line hasSuffix:@"\""] || line.length < prefix.length + 1) continue;
        NSString *locale = [line substringWithRange:NSMakeRange(prefix.length, line.length - prefix.length - 1)];
        if ([configuration[@"locales"] containsObject:locale]) return locale;
    }
    return nil;
}

// "steam": the top folder, the runtime archive and the name of Valve's list.
+ (BOOL)validSteamConfiguration:(NSDictionary *)block workingDirectory:(NSString *)workingDirectory runtime:(NSString *)runtime {
    if (block.count != 4 || !plain_relative(block[@"root"]) || !matches(block[@"client"], @"steam_client_[a-z0-9_]{1,32}")) return NO;
    // The runtime's folder and the Steam folder inside the prefix are both inside the top folder.
    if (!plain_relative(runtime) || !under(runtime, block[@"root"]) || !under(workingDirectory, block[@"root"])) return NO;
    NSDictionary *archive = block[@"runtime"];
    if (![archive isKindOfClass:NSDictionary.class] || archive.count != 3) return NO;
    NSString *url = archive[@"url"];
    if (![url isKindOfClass:NSString.class] || url.length > 512 || ![url hasPrefix:@"https://"] ||
        [url rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        ![NSURL URLWithString:url].host.length) return NO;
    return matches(archive[@"sha256"], @"[0-9a-f]{64}") && whole_number(archive[@"size"], 1, 1ull << 32);
}

+ (BOOL)validConfiguration:(id)configuration workingDirectory:(NSString *)workingDirectory runtime:(NSString *)runtime {
    if (![configuration isKindOfClass:NSDictionary.class] || ![workingDirectory isKindOfClass:NSString.class]) return NO;
    NSDictionary *block = configuration;
    if ([block[@"service"] isEqual:@"steam"]) return [self validSteamConfiguration:block workingDirectory:workingDirectory runtime:runtime];
    if (runtime) return NO;   // an application of its own, not one a runtime starts
    NSSet *known = [NSSet setWithArray:@[@"service", @"product", @"regions", @"locales", @"tags", @"folder", @"root", @"settings", @"update"]];
    for (id key in block) if (![known containsObject:key]) return NO;
    if (block[@"update"] && !is_true(block[@"update"])) return NO;
    if (![block[@"service"] isEqual:@"blizzard"] || !matches(block[@"product"], @"[a-z0-9_]{1,32}")) return NO;
    NSArray *regions = block[@"regions"], *locales = block[@"locales"], *tags = block[@"tags"];
    if (![regions isKindOfClass:NSArray.class] || !regions.count || regions.count > 8) return NO;
    for (NSDictionary *region in regions) {
        if (![region isKindOfClass:NSDictionary.class] || region.count != 3 || !matches(region[@"id"], @"[a-z]{2}") ||
            !matches(region[@"portal"], @"[A-Z]{2,4}") || ![region[@"name"] isKindOfClass:NSString.class] ||
            ![region[@"name"] length] || [region[@"name"] length] > 40) return NO;
    }
    if (![locales isKindOfClass:NSArray.class] || !locales.count || locales.count > 16) return NO;
    for (id locale in locales) if (!matches(locale, @"[a-z]{2}[A-Z]{2}")) return NO;
    if (![tags isKindOfClass:NSArray.class] || !tags.count || tags.count > 8) return NO;
    for (id tag in tags) if (!matches(tag, @"[A-Za-z0-9_]{1,16}")) return NO;
    // The manifest folder that is the application, and the install's top
    // folder: the working directory itself or a folder above it.
    if (!plain_relative(block[@"folder"]) || [block[@"folder"] containsString:@"/"] || !plain_relative(block[@"root"])) return NO;
    if (![workingDirectory isEqual:block[@"root"]] && ![workingDirectory hasPrefix:[block[@"root"] stringByAppendingString:@"/"]]) return NO;
    NSDictionary *file = block[@"settings"];
    if (file) {
        if (![file isKindOfClass:NSDictionary.class] || file.count != 4 || !plain_relative(file[@"file"])) return NO;
        for (NSString *key in @[@"region", @"text", @"audio"]) if (!matches(file[key], @"[A-Za-z]{1,32}")) return NO;
    }
    return YES;
}

- (instancetype)initWithConfiguration:(NSDictionary *)configuration documents:(NSString *)documents
                     workingDirectory:(NSString *)workingDirectory runtime:(NSString *)runtime
                               region:(NSString *)region locale:(NSString *)locale {
    if (!(self = [super init])) return nil;
    if (![TKGameDownload validConfiguration:configuration workingDirectory:workingDirectory runtime:runtime] || !plain_relative(workingDirectory)) return nil;
    if ([TKGameDownload regionsOfConfiguration:configuration].count) {
        BOOL known = NO;
        for (NSDictionary *item in configuration[@"regions"]) known = known || [item[@"id"] isEqual:region];
        if (!known || ![configuration[@"locales"] containsObject:locale]) return nil;
    } else if (region.length || locale.length) return nil;
    _configuration = [configuration copy];
    _root = [documents stringByAppendingPathComponent:configuration[@"root"]];
    _working = [documents stringByAppendingPathComponent:workingDirectory];
    _runtime = runtime ? [documents stringByAppendingPathComponent:runtime] : nil;
    _region = [region copy]; _locale = [locale copy];
    _chunk = 8 << 20;
    return self;
}

- (void)cancel { atomic_store(&_cancelled, true); }

#pragma mark Network

- (NSData *)request:(NSURL *)url range:(NSRange)range error:(NSError **)error {
    if (atomic_load(&_cancelled)) { if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]; return nil; }
    if (self.fetch) return self.fetch(url, range, error);
    if (![url.scheme isEqual:@"https"]) { if (error) *error = download_error(@"The server did not offer a secure address."); return nil; }
    if (!_session) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 60;
        configuration.HTTPMaximumConnectionsPerHost = 8;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    NSError *last = nil;
    for (int attempt = 0; attempt < 3 && !atomic_load(&_cancelled); attempt++) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        if (range.length) [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)range.location,
                                             (unsigned long)(NSMaxRange(range) - 1)] forHTTPHeaderField:@"Range"];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *body = nil; __block NSError *failure = nil;
        [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (taskError) failure = taskError;
            else if (status != (range.length ? 206 : 200)) failure = download_error([NSString stringWithFormat:@"The server answered %ld.", (long)status]);
            else if (range.length && data.length != range.length) failure = download_error(@"The server sent a different amount than asked for.");
            else body = data;
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (body) return body;
        last = failure;
    }
    if (error) *error = last ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    return nil;
}

- (void)report:(NSString *)phase fraction:(double)fraction { if (self.progress) self.progress(phase, fraction); }

#pragma mark Download

- (BOOL)run:(NSError **)error {
    NSError *failure = nil;
    BOOL ok = [self runWithError:&failure];
    if (!ok && atomic_load(&_cancelled)) failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    if (!ok && error) *error = failure ?: download_error(@"The download failed.");
    return ok;
}

- (BOOL)runWithError:(NSError **)error {
    return [_configuration[@"service"] isEqual:@"steam"] ? [self runSteam:error] : [self runBlizzard:error];
}

#pragma mark Blizzard

- (NSDictionary<NSString *, NSString *> *)currentBuild:(NSError **)error {
    if (![_configuration[@"service"] isEqual:@"blizzard"]) { if (error) *error = download_error(@"Only a Blizzard download has builds."); return nil; }
    NSString *address = [NSString stringWithFormat:@"https://%@.version.battle.net/v2/products/%@/versions", _region, _configuration[@"product"]];
    NSData *data = [self request:[NSURL URLWithString:address] range:NSMakeRange(0, 0) error:error];
    if (!data) return nil;
    for (NSDictionary<NSString *, NSString *> *row in table(data)) {
        if (![row[@"Region"] isEqual:_region]) continue;
        if (!is_key(row[@"BuildConfig"]) || !matches(row[@"VersionsName"], @"[0-9A-Za-z._-]{1,40}")) break;
        return @{@"build": row[@"BuildConfig"], @"version": row[@"VersionsName"]};
    }
    if (error) *error = download_error(@"The version server's answer was not understood.");
    return nil;
}

- (BOOL)runBlizzard:(NSError **)error {
    NSString *product = _configuration[@"product"];
    NSFileManager *files = NSFileManager.defaultManager;
    [self report:@"Asking for the current version…" fraction:0];
    // The current build, and where its files are served from.
    NSString *service = [NSString stringWithFormat:@"https://%@.version.battle.net/v2/products/%@/", _region, product];
    NSData *versionsData = [self request:[NSURL URLWithString:[service stringByAppendingString:@"versions"]] range:NSMakeRange(0, 0) error:error];
    if (!versionsData) return NO;
    NSData *cdnsData = [self request:[NSURL URLWithString:[service stringByAppendingString:@"cdns"]] range:NSMakeRange(0, 0) error:error];
    if (!cdnsData) return NO;
    NSDictionary *version = nil, *cdn = nil;
    for (NSDictionary *row in table(versionsData)) if ([row[@"Region"] isEqual:_region]) version = row;
    for (NSDictionary *row in table(cdnsData)) if ([row[@"Name"] isEqual:_region]) cdn = row;
    NSString *base = nil;
    for (NSString *server in [cdn[@"Servers"] componentsSeparatedByString:@" "]) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:server];
        if ([parts.scheme isEqual:@"https"] && parts.host.length && !base) base = [NSString stringWithFormat:@"https://%@", parts.host];
    }
    if (self.fetch && !base && [cdn[@"Hosts"] length]) base = [@"https://" stringByAppendingString:[cdn[@"Hosts"] componentsSeparatedByString:@" "].firstObject];
    if (!is_key(version[@"BuildConfig"]) || !is_key(version[@"CDNConfig"]) || !base || !plain_relative(cdn[@"Path"]) ||
        !matches(version[@"VersionsName"], @"[0-9A-Za-z._-]{1,40}")) {
        if (error) *error = download_error(@"The version server's answer was not understood."); return NO;
    }
    base = [base stringByAppendingFormat:@"/%@", cdn[@"Path"]];
    NSURL *(^address)(NSString *, NSString *, NSString *) = ^NSURL *(NSString *kind, NSString *key, NSString *suffix) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/%@/%@/%@%@", base, kind,
                                     [key substringToIndex:2], [key substringWithRange:NSMakeRange(2, 2)], key, suffix]];
    };

    [self report:@"Reading the file list…" fraction:0.01];
    NSData *buildData = [self request:address(@"config", version[@"BuildConfig"], @"") range:NSMakeRange(0, 0) error:error];
    if (!buildData) return NO;
    NSDictionary *build = settings(buildData);
    NSString *installKey = [build[@"install"] count] == 2 ? build[@"install"][1] : nil;
    NSString *encodingKey = [build[@"encoding"] count] == 2 ? build[@"encoding"][1] : nil;
    if (!is_key(installKey) || !is_key(encodingKey)) { if (error) *error = download_error(@"The build's description was not understood."); return NO; }
    NSData *installData = [self request:address(@"data", installKey, @"") range:NSMakeRange(0, 0) error:error];
    if (!installData) return NO;
    NSData *manifest = blte(installData);
    BCInstall install;
    if (!manifest || !bc_install_open(&install, manifest.bytes, manifest.length)) {
        if (error) *error = download_error(@"The file list was not understood."); return NO;
    }
    // The application's files for this system, region and language.
    NSString *portal = nil;
    for (NSDictionary *item in _configuration[@"regions"]) if ([item[@"id"] isEqual:_region]) portal = item[@"portal"];
    NSMutableArray<NSString *> *tagNames = [_configuration[@"tags"] mutableCopy];
    [tagNames addObjectsFromArray:@[portal, _locale]];
    NSMutableArray<NSNumber *> *tags = [NSMutableArray new];
    for (NSString *name in tagNames) {
        int tag = bc_install_tag(&install, name.UTF8String);
        if (tag < 0) { bc_install_close(&install); if (error) *error = download_error([NSString stringWithFormat:@"The file list has nothing for %@.", name]); return NO; }
        [tags addObject:@(tag)];
    }
    NSString *prefix = [_configuration[@"folder"] stringByAppendingString:@"\\"];
    NSMutableArray<NSString *> *paths = [NSMutableArray new], *ckeys = [NSMutableArray new];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray new];
    NSMutableData *wantedKeys = [NSMutableData new];
    BOOL safe = YES;
    for (uint32_t i = 0; i < install.entry_count; i++) {
        const uint8_t *ckey; uint32_t size;
        NSString *name = @(bc_install_entry(&install, i, &ckey, &size) ?: "");
        if (![name hasPrefix:prefix]) continue;
        BOOL wanted = YES;
        for (NSNumber *tag in tags) wanted = wanted && bc_install_has_tag(&install, i, tag.intValue);
        if (!wanted) continue;
        NSString *path = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!plain_relative(path)) { safe = NO; break; }
        [paths addObject:path]; [ckeys addObject:hex(ckey)]; [sizes addObject:@(size)];
        [wantedKeys appendBytes:ckey length:16];
    }
    bc_install_close(&install);
    if (!safe || !paths.count) { if (error) *error = download_error(safe ? @"The file list names no application files." : @"The file list names a file outside the application."); return NO; }

    // What is already in place and intact is not fetched again.
    uint64_t total = 0, present = 0;
    NSMutableIndexSet *missing = [NSMutableIndexSet new];
    for (NSUInteger i = 0; i < paths.count; i++) {
        total += sizes[i].unsignedLongLongValue;
        NSString *path = [_working stringByAppendingPathComponent:paths[i]];
        NSNumber *onDisk = [files attributesOfItemAtPath:path error:NULL][NSFileSize];
        if (onDisk && [onDisk isEqual:sizes[i]] && [md5_of_file(path) isEqual:ckeys[i]]) present += sizes[i].unsignedLongLongValue;
        else [missing addIndex:i];
    }
    if (missing.count) {
        // The stored name of each file, from the encoding table (large).
        [self report:@"Reading the file list…" fraction:0.02];
        NSData *encodingData = [self request:address(@"data", encodingKey, @"") range:NSMakeRange(0, 0) error:error];
        if (!encodingData) return NO;
        NSData *encoding = blte(encodingData);
        encodingData = nil;
        NSMutableData *ekeys = [NSMutableData dataWithLength:paths.count * 16];
        bool *found = calloc(paths.count, sizeof(bool));
        BOOL understood = encoding && bc_encoding_lookup(encoding.bytes, encoding.length, wantedKeys.bytes, paths.count, ekeys.mutableBytes, found);
        for (NSUInteger i = 0; understood && i < paths.count; i++) understood = found[i];
        free(found);
        encoding = nil;
        if (!understood) { if (error) *error = download_error(@"The file list and the server's storage table do not agree."); return NO; }

        // Where each file lies: in one of the archives, or on its own.
        NSData *cdnData = [self request:address(@"config", version[@"CDNConfig"], @"") range:NSMakeRange(0, 0) error:error];
        if (!cdnData) return NO;
        NSArray<NSString *> *archives = settings(cdnData)[@"archives"];
        for (NSString *archive in archives) if (!is_key(archive)) { if (error) *error = download_error(@"The server's archive list was not understood."); return NO; }
        NSString *indices = [_root stringByAppendingPathComponent:@"Data/indices"];
        if (![files createDirectoryAtPath:indices withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        NSUInteger count = paths.count;
        bool *located = calloc(count, sizeof(bool));
        uint32_t *storedSizes = calloc(count, sizeof(uint32_t)), *offsets = calloc(count, sizeof(uint32_t));
        NSMutableArray<NSString *> *homes = [NSMutableArray new];
        for (NSUInteger i = 0; i < count; i++) [homes addObject:@""];
        NSLock *lock = [NSLock new];
        __block NSError *indexFailure = nil;
        __block NSUInteger scanned = 0;
        dispatch_queue_t queue = dispatch_queue_create("org.tolkara.download.indices", DISPATCH_QUEUE_CONCURRENT);
        dispatch_semaphore_t slots = dispatch_semaphore_create(8);
        dispatch_group_t group = dispatch_group_create();
        for (NSString *archive in archives) {
            dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
            dispatch_group_async(group, queue, ^{
                @autoreleasepool {
                    // The game keeps the same index files here; one it finds is one it need not fetch.
                    NSString *path = [indices stringByAppendingPathComponent:[archive stringByAppendingString:@".index"]];
                    NSData *index = [NSData dataWithContentsOfFile:path];
                    NSError *problem = nil;
                    bool *mine = calloc(count, sizeof(bool));
                    uint32_t *mySizes = calloc(count, sizeof(uint32_t)), *myOffsets = calloc(count, sizeof(uint32_t));
                    IndexSearch search = {ekeys.bytes, count, mine, mySizes, myOffsets, 0};
                    BOOL read = index && bc_index_scan(index.bytes, index.length, index_visit, &search);
                    if (!read) {
                        memset(mine, 0, count * sizeof(bool)); search.hits = 0;
                        [lock lock]; BOOL stop = indexFailure != nil; [lock unlock];
                        index = stop ? nil : [self request:address(@"data", archive, @".index") range:NSMakeRange(0, 0) error:&problem];
                        read = index && bc_index_scan(index.bytes, index.length, index_visit, &search);
                        if (index && !read) problem = download_error(@"An archive's index was not understood.");
                        if (read) [index writeToFile:path atomically:YES];
                    }
                    [lock lock];
                    if (!read && !indexFailure) indexFailure = problem ?: download_error(@"An archive's index could not be fetched.");
                    for (NSUInteger i = 0; read && i < count; i++) if (mine[i] && !located[i]) {
                        located[i] = true; storedSizes[i] = mySizes[i]; offsets[i] = myOffsets[i]; homes[i] = archive;
                    }
                    scanned++;
                    BOOL tell = scanned % 16 == 0;
                    double fraction = 0.03 + 0.17 * (double)scanned / (double)archives.count;
                    [lock unlock];
                    if (tell) [self report:@"Finding the application's files…" fraction:fraction];
                    free(mine); free(mySizes); free(myOffsets);
                }
                dispatch_semaphore_signal(slots);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        if (indexFailure) { free(located); free(storedSizes); free(offsets); if (error) *error = indexFailure; return NO; }

        // The files themselves, a few at a time, each checked before it is put in place.
        __block NSError *fileFailure = nil;
        __block uint64_t done = present;
        dispatch_semaphore_t fileSlots = dispatch_semaphore_create(4);
        dispatch_group_t fileGroup = dispatch_group_create();
        const uint8_t *ekeyBytes = ekeys.bytes;
        [missing enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
            dispatch_semaphore_wait(fileSlots, DISPATCH_TIME_FOREVER);
            [lock lock]; BOOL failed = fileFailure != nil; [lock unlock];
            if (failed) { *stop = YES; dispatch_semaphore_signal(fileSlots); return; }
            dispatch_group_async(fileGroup, queue, ^{
                @autoreleasepool {
                    NSError *problem = nil;
                    NSData *stored = located[i]
                        ? [self request:address(@"data", homes[i], @"") range:NSMakeRange(offsets[i], storedSizes[i]) error:&problem]
                        : [self request:address(@"data", hex(ekeyBytes + i * 16), @"") range:NSMakeRange(0, 0) error:&problem];
                    if (stored && located[i] && !storedSizes[i]) stored = nil;
                    NSString *path = [self->_working stringByAppendingPathComponent:paths[i]], *part = [path stringByAppendingString:@".part"];
                    BOOL placed = NO;
                    if (stored && [files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&problem]) {
                        NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:part append:NO];
                        [stream open];
                        FileSink sink = {stream, {0}, 0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        CC_MD5_Init(&sink.md5);
                        BOOL decoded = bc_blte_decode(stored.bytes, stored.length, file_sink, &sink);
                        uint8_t digest[16]; CC_MD5_Final(digest, &sink.md5);
#pragma clang diagnostic pop
                        [stream close];
                        if (!decoded || sink.written != sizes[i].unsignedLongLongValue || ![hex(digest) isEqual:ckeys[i]]) {
                            problem = download_error([NSString stringWithFormat:@"%@ did not match the server's file list.", paths[i].lastPathComponent]);
                        } else {
                            [files removeItemAtPath:path error:NULL];
                            placed = [files moveItemAtPath:part toPath:path error:&problem];
                        }
                    }
                    if (!placed) [files removeItemAtPath:part error:NULL];
                    [lock lock];
                    if (!placed && !fileFailure) fileFailure = problem ?: download_error(@"A file could not be fetched.");
                    if (placed) done += sizes[i].unsignedLongLongValue;
                    double fraction = 0.2 + 0.8 * (double)done / (double)MAX(total, 1);
                    uint64_t megabytes = done >> 20;
                    [lock unlock];
                    if (placed) [self report:[NSString stringWithFormat:@"Downloading… %llu of %llu MB", megabytes, total >> 20] fraction:fraction];
                }
                dispatch_semaphore_signal(fileSlots);
            });
        }];
        dispatch_group_wait(fileGroup, DISPATCH_TIME_FOREVER);
        free(located); free(storedSizes); free(offsets);
        if (fileFailure) { if (error) *error = fileFailure; return NO; }
    }
    if (atomic_load(&_cancelled)) return NO;

    // What the publisher's own launcher leaves beside the application: which
    // build this is and where its data comes from, the product, and the
    // region and languages the game asks for at its first start.
    NSString *header = @"Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|"
        @"CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|"
        @"Version!STRING:0|KeyRing!HEX:16|Product!STRING:0";
    NSString *tagLine = [NSString stringWithFormat:@"OSX x86_64 %@? %@ speech?:OSX x86_64 %@? %@ text?", portal, _locale, portal, _locale];
    NSArray<NSString *> *row = @[_region, @"1", version[@"BuildConfig"], version[@"CDNConfig"], @"", @"", cdn[@"Path"], cdn[@"Hosts"] ?: @"",
                                 cdn[@"Servers"] ?: @"", tagLine, @"", @"", version[@"VersionsName"], @"", product];
    for (NSString *cell in row) if ([cell containsString:@"|"] || [cell containsString:@"\n"]) { if (error) *error = download_error(@"The version server's answer was not understood."); return NO; }
    // One install can hold several products (World of Warcraft's flavours share
    // a folder): the other products' rows stay, this one's is replaced.
    NSString *buildInfoPath = [_root stringByAppendingPathComponent:@".build.info"];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:header], *columns = [NSMutableArray new];
    for (NSString *column in [header componentsSeparatedByString:@"|"]) [columns addObject:[column componentsSeparatedByString:@"!"].firstObject];
    NSData *existing = [NSData dataWithContentsOfFile:buildInfoPath];
    for (NSDictionary<NSString *, NSString *> *old in existing ? table(existing) : @[]) {
        if ([old[@"Product"] isEqual:product] || ![old[@"Product"] length]) continue;
        NSMutableArray<NSString *> *cells = [NSMutableArray new];
        for (NSString *column in columns) [cells addObject:old[column] ?: @""];
        [lines addObject:[cells componentsJoinedByString:@"|"]];
    }
    [lines addObject:[row componentsJoinedByString:@"|"]];
    NSString *buildInfo = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    if (![files createDirectoryAtPath:[_root stringByAppendingPathComponent:@"Data"] withIntermediateDirectories:YES attributes:nil error:error] ||
        ![files createDirectoryAtPath:_working withIntermediateDirectories:YES attributes:nil error:error] ||
        ![buildInfo writeToFile:buildInfoPath atomically:YES encoding:NSUTF8StringEncoding error:error] ||
        ![[NSString stringWithFormat:@"Product Flavor!STRING:0\n%@\n", product] writeToFile:[_working stringByAppendingPathComponent:@".flavor.info"]
                                                                                 atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    NSDictionary *file = _configuration[@"settings"];
    NSString *settingsPath = file ? [_working stringByAppendingPathComponent:file[@"file"]] : nil;
    // Settings the game already saved are the user's: only a missing file is written.
    if (settingsPath && ![files fileExistsAtPath:settingsPath]) {
        NSString *text = [NSString stringWithFormat:@"SET %@ \"%@\"\nSET %@ \"%@\"\nSET %@ \"%@\"\n",
                          file[@"text"], _locale, file[@"region"], portal, file[@"audio"], _locale];
        if (![files createDirectoryAtPath:settingsPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] ||
            ![text writeToFile:settingsPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    }
    [self report:@"Downloaded." fraction:1];
    return YES;
}

#pragma mark Steam

- (BOOL)stopped { return atomic_load(&_cancelled); }

// nil when the file cannot be read or the download was stopped.
- (NSString *)sha256OfFile:(NSString *)path {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t *buffer = malloc(1 << 20);
    ssize_t got = -1;
    while (buffer && !self.stopped && (got = read(fd, buffer, 1 << 20)) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)got);
    free(buffer); close(fd);
    if (got) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    return hex_of(digest, CC_SHA256_DIGEST_LENGTH);
}

// Brings `url` (`size` bytes with this SHA-256) into the file `part`, a
// chunk at a time so that memory stays bounded, continuing a file an earlier
// run left there. True only for a file of the right size and hash; one that
// is complete and differs is removed.
- (BOOL)fetch:(NSURL *)url toFile:(NSString *)part size:(uint64_t)size sha256:(NSString *)sha256 what:(NSString *)what
     progress:(void (^)(uint64_t have))progress error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:part.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    uint64_t have = [[files attributesOfItemAtPath:part error:NULL][NSFileSize] unsignedLongLongValue];
    if (have > size) { [files removeItemAtPath:part error:NULL]; have = 0; }
    int fd = open(part.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0644);
    NSError *problem = fd < 0 ? download_error(@"A file could not be written on this device.") : nil;
    if (!problem && progress) progress(have);
    while (!problem && have < size) {
        @autoreleasepool {
            NSUInteger length = (NSUInteger)MIN((uint64_t)MAX(self.chunk, 1u), size - have);
            // Something that fits in one chunk is asked for whole.
            BOOL whole = !have && length == size;
            NSError *failure = nil;
            NSData *data = [self request:url range:whole ? NSMakeRange(0, 0) : NSMakeRange((NSUInteger)have, length) error:&failure];
            const uint8_t *bytes = data.bytes;
            if (!data) problem = failure ?: download_error(@"A file could not be fetched.");
            else if (data.length != length) problem = download_error(@"The server sent a different amount than asked for.");
            for (NSUInteger wrote = 0; !problem && wrote < length;) {
                ssize_t count = write(fd, bytes + wrote, length - wrote);
                if (count <= 0) problem = download_error(@"A file could not be written on this device. Is there enough free space?");
                else wrote += (NSUInteger)count;
            }
            if (!problem) { have += length; if (progress) progress(have); }
        }
    }
    if (fd >= 0) close(fd);
    if (!problem) {
        NSString *found = [self sha256OfFile:part];
        if (!found) problem = download_error(@"A downloaded file could not be read back.");
        else if (![found isEqual:sha256]) {
            [files removeItemAtPath:part error:NULL];
            problem = download_error([NSString stringWithFormat:@"%@ did not match its published checksum, so it was not used. Try again.", what]);
        }
    }
    if (problem && error) *error = problem;
    return !problem;
}

// One entry's content to `path` with `mode`, through a file beside it that
// takes its name only when the content matched the archive's checksum.
- (BOOL)extract:(const ZAArchive *)archive entry:(uint32_t)index to:(NSString *)path mode:(mode_t)mode {
    NSString *part = [path stringByAppendingString:@".tolkara-part"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    unlink(part.fileSystemRepresentation);
    EntrySink sink = {open(part.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644), &_cancelled, nil};
    if (sink.fd < 0) return NO;
    BOOL ok = za_extract(archive, index, entry_sink, &sink) && !fchmod(sink.fd, mode);
    close(sink.fd);
    ok = ok && !rename(part.fileSystemRepresentation, path.fileSystemRepresentation);
    if (!ok) unlink(part.fileSystemRepresentation);
    return ok;
}

// The Windows runtime: one archive of Tolkara's own, into the top folder.
- (BOOL)steamRuntime:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *block = _configuration[@"runtime"];
    NSString *sha256 = block[@"sha256"], *marker = [_root stringByAppendingPathComponent:@".tolkara-runtime"];
    uint64_t size = [block[@"size"] unsignedLongLongValue];
    // The marker is written last: it says this very archive is unpacked here.
    if ([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL] containsString:sha256]) return YES;
    NSString *part = [_root stringByAppendingPathComponent:@".download/runtime.zip.part"];
    if (![self fetch:[NSURL URLWithString:block[@"url"]] toFile:part size:size sha256:sha256 what:@"The Windows runtime" progress:^(uint64_t have) {
        [self report:[NSString stringWithFormat:@"Downloading the Windows runtime… %llu of %llu MB", have >> 20, size >> 20]
            fraction:0.5 * (double)have / (double)size];
    } error:error]) return NO;

    [self report:@"Unpacking the Windows runtime…" fraction:0.5];
    NSError *unreadable = download_error(@"The Windows runtime's archive was not understood.");
    ZAArchive archive;
    if (!za_open(&archive, part.fileSystemRepresentation)) { [files removeItemAtPath:part error:NULL]; if (error) *error = unreadable; return NO; }
    // An existing prefix is the user's Steam installation and sign-in: with
    // one here, nothing of the archive's prefix/ is unpacked and no copy is
    // made into it. Only the runtime's own folder is replaced. A prefix
    // counts as existing by its system.reg, which is therefore the last
    // thing unpacked: a prefix that was stopped half-way is completed.
    BOOL keepPrefix = [files fileExistsAtPath:[_root stringByAppendingPathComponent:@"prefix/system.reg"]];
    NSString *runtimeFolder = [_runtime substringFromIndex:_root.length + 1];
    // Every name is checked before anything is written.
    NSMutableArray *paths = [NSMutableArray new], *folders = [NSMutableArray new];
    uint32_t links = UINT32_MAX, registry = UINT32_MAX;
    uint64_t total = 0;
    BOOL understood = YES, holdsRuntime = NO;
    for (uint32_t i = 0; understood && i < archive.count; i++) {
        BOOL directory = NO;
        NSString *path = entry_path(&archive.entries[i], &directory);
        // Names that start with a dot at the top are Tolkara's own notes here.
        if (!path || [path hasPrefix:@"."]) { understood = NO; break; }
        if ([path isEqual:@"tolkara-links.txt"] && !directory) {
            links = i; understood = archive.entries[i].size <= 8 << 20;
            [paths addObject:NSNull.null]; continue;
        }
        BOOL kept = keepPrefix && ([path isEqual:@"prefix"] || under(path, @"prefix"));
        // A folder with nothing in it (C:\windows\temp) is still made.
        if (directory && !kept) [folders addObject:path];
        BOOL skipped = directory || kept;
        if (!directory && under(path, runtimeFolder)) holdsRuntime = YES;
        if ([path isEqual:@"prefix/system.reg"] && !skipped) registry = i;
        if (!skipped) total += archive.entries[i].size;
        [paths addObject:skipped ? NSNull.null : path];
    }
    if (!understood || !holdsRuntime) { za_close(&archive); [files removeItemAtPath:part error:NULL]; if (error) *error = unreadable; return NO; }

    NSError *problem = nil;
    [files removeItemAtPath:marker error:NULL];
    [files removeItemAtPath:_runtime error:NULL];
    for (NSString *folder in folders)
        if (!problem) [files createDirectoryAtPath:[_root stringByAppendingPathComponent:folder] withIntermediateDirectories:YES attributes:nil error:&problem];
    uint64_t done = 0;
    for (uint32_t pass = 0; pass < 2 && !problem; pass++) {
        // Second pass: the copies, then the prefix's system.reg.
        if (pass && links != UINT32_MAX) {
            NSMutableData *text = [NSMutableData new];
            EntrySink sink = {-1, &_cancelled, text};
            if (!za_extract(&archive, links, entry_sink, &sink)) problem = unreadable;
            else [self applyLinks:text keepPrefix:keepPrefix error:&problem];
        }
        for (uint32_t i = 0; i < archive.count && !problem; i++) {
            if (paths[i] == NSNull.null || (i == registry) != (pass == 1)) continue;
            @autoreleasepool {
                const ZAEntry *entry = &archive.entries[i];
                // Files of the runtime are loaded as libraries: the archive says which are executable.
                if (![self extract:&archive entry:i to:[_root stringByAppendingPathComponent:paths[i]] mode:(entry->mode & 0111) ? 0755 : 0644])
                    problem = download_error([NSString stringWithFormat:@"%@ of the Windows runtime could not be unpacked.", [paths[i] lastPathComponent]]);
                done += entry->size;
                if (i % 64 == 0) [self report:@"Unpacking the Windows runtime…" fraction:0.5 + 0.1 * (double)done / (double)MAX(total, 1)];
            }
        }
    }
    za_close(&archive);
    if (!problem && ![[sha256 stringByAppendingString:@"\n"] writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:&problem] && !problem)
        problem = unreadable;
    if (problem) { if (error) *error = problem; return NO; }
    [files removeItemAtPath:part error:NULL];
    return YES;
}

// tolkara-links.txt: "<destination>\t<source>" lines, both inside the top
// folder: the destination becomes a copy of the source that shares its
// storage (a prefix's system32 is mostly the runtime's own libraries).
- (BOOL)applyLinks:(NSData *)data keepPrefix:(BOOL)keepPrefix error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSError *problem = text ? nil : download_error(@"The Windows runtime's list of copies was not understood.");
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        if (problem) break;
        NSString *line = [raw hasSuffix:@"\r"] ? [raw substringToIndex:raw.length - 1] : raw;
        if (!line.length) continue;
        if (self.stopped) { problem = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]; break; }
        @autoreleasepool {
            NSArray<NSString *> *pair = [line componentsSeparatedByString:@"\t"];
            NSString *to = pair.count == 2 ? pair[0] : nil, *from = pair.count == 2 ? pair[1] : nil;
            NSString *source = [_root stringByAppendingPathComponent:from ?: @""], *target = [_root stringByAppendingPathComponent:to ?: @""];
            struct stat status;
            if (!plain_relative(to) || !plain_relative(from) || [to hasPrefix:@"."] || [from hasPrefix:@"."] || [to isEqual:from])
                problem = download_error(@"The Windows runtime's list of copies names a file outside its folder.");
            else if (keepPrefix && under(to, @"prefix")) continue;
            else if (lstat(source.fileSystemRepresentation, &status) || !S_ISREG(status.st_mode))
                problem = download_error([NSString stringWithFormat:@"The Windows runtime's list of copies names %@, which is not in it.", from.lastPathComponent]);
            else {
                [files createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
                unlink(target.fileSystemRepresentation);
                // A clone costs no storage; a volume that cannot clone gets a plain copy.
                if (clonefile(source.fileSystemRepresentation, target.fileSystemRepresentation, CLONE_NOFOLLOW) &&
                    ![files copyItemAtPath:source toPath:target error:NULL])
                    problem = download_error([NSString stringWithFormat:@"%@ of the Windows runtime could not be put in place.", to.lastPathComponent]);
            }
        }
    }
    if (problem && error) *error = problem;
    return !problem;
}

// Steam itself, from Valve's update server: the installer package unpacked
// into the Steam folder, the others kept in its package folder as Steam's
// own updater keeps them, so that it finds them at its first start.
- (BOOL)steamClient:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    // With steam.exe here Steam is installed and keeps itself up to date.
    NSString *steam = [_working stringByAppendingPathComponent:@"steam.exe"];
    if ([files fileExistsAtPath:steam]) return YES;
    [self report:@"Asking Valve's server for Steam's files…" fraction:0.6];
    NSString *server = @"https://client-update.steamstatic.com/", *client = _configuration[@"client"];
    NSData *manifest = [self request:[NSURL URLWithString:[server stringByAppendingString:client]] range:NSMakeRange(0, 0) error:error];
    if (!manifest) return NO;
    // "steam_client_win64" installs with the package "steam_win64".
    NSString *installerName = [@"steam_" stringByAppendingString:[client substringFromIndex:13]];
    NSDictionary *installer = nil;
    NSMutableArray<NSDictionary *> *kept = [NSMutableArray new];
    uint64_t total = 0;
    for (NSDictionary *package in steam_packages(manifest)) {
        if (![package[@"bootstrapper"] boolValue]) [kept addObject:package];
        else if ([package[@"name"] isEqual:installerName]) installer = package;
        else continue;   // another edition's installer
        total += [package[@"size"] unsignedLongLongValue];
    }
    if (!installer) { if (error) *error = download_error(@"Valve's list of Steam's files was not understood."); return NO; }

    __block uint64_t done = 0;
    void (^tell)(uint64_t) = ^(uint64_t have) {
        [self report:[NSString stringWithFormat:@"Downloading Steam… %llu of %llu MB", (done + have) >> 20, total >> 20]
            fraction:0.6 + 0.39 * (double)(done + have) / (double)total];
    };
    NSString *folder = [_working stringByAppendingPathComponent:@"package"], *parts = [_root stringByAppendingPathComponent:@".download"];
    if (![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSError *problem = nil;
    for (NSDictionary *package in kept) {
        @autoreleasepool {
            NSString *name = package[@"fetch"], *path = [folder stringByAppendingPathComponent:name];
            NSString *part = [parts stringByAppendingPathComponent:[name stringByAppendingString:@".part"]];
            uint64_t size = [package[@"size"] unsignedLongLongValue];
            // What is already there and intact is not fetched again.
            BOOL present = [[files attributesOfItemAtPath:path error:NULL][NSFileSize] isEqual:package[@"size"]] &&
                [[self sha256OfFile:path] isEqual:package[@"sha256"]];
            if (!present) {
                present = [self fetch:[NSURL URLWithString:[server stringByAppendingString:name]] toFile:part size:size sha256:package[@"sha256"]
                                 what:name progress:tell error:&problem];
                if (present) { [files removeItemAtPath:path error:NULL]; present = [files moveItemAtPath:part toPath:path error:&problem]; }
            }
            if (!present && !problem) problem = download_error(@"A file could not be fetched.");
            done += size;
            if (present) tell(0);
        }
        if (problem) { if (error) *error = problem; return NO; }
    }

    NSString *name = installer[@"fetch"], *part = [parts stringByAppendingPathComponent:[name stringByAppendingString:@".part"]];
    if (![self fetch:[NSURL URLWithString:[server stringByAppendingString:name]] toFile:part size:[installer[@"size"] unsignedLongLongValue]
              sha256:installer[@"sha256"] what:name progress:tell error:error]) return NO;
    [self report:@"Unpacking Steam…" fraction:0.99];
    ZAArchive archive;
    BOOL understood = za_open(&archive, part.fileSystemRepresentation);
    NSMutableArray *paths = [NSMutableArray new];
    uint32_t program = UINT32_MAX;
    for (uint32_t i = 0; understood && i < archive.count; i++) {
        BOOL directory = NO;
        NSString *path = entry_path(&archive.entries[i], &directory);
        if (!path) { understood = NO; break; }
        // The package folder's contents are the ones fetched above.
        BOOL skipped = directory || [path.lowercaseString isEqual:@"package"] || under(path.lowercaseString, @"package");
        if (!skipped && [path.lowercaseString isEqual:@"steam.exe"]) program = i;
        [paths addObject:skipped ? NSNull.null : path];
    }
    // steam.exe says Steam is installed, so it is unpacked last.
    understood = understood && program != UINT32_MAX;
    for (uint32_t pass = 0; understood && pass < 2; pass++)
        for (uint32_t i = 0; understood && i < archive.count; i++) {
            if (paths[i] == NSNull.null || (i == program) != (pass == 1)) continue;
            @autoreleasepool {
                understood = [self extract:&archive entry:i to:i == program ? steam : [_working stringByAppendingPathComponent:paths[i]] mode:0644];
            }
        }
    za_close(&archive);
    if (!self.stopped) [files removeItemAtPath:part error:NULL];
    if (!understood && error) *error = download_error(@"Steam's installer package could not be unpacked.");
    return understood;
}

- (BOOL)runSteam:(NSError **)error {
    if (![self steamRuntime:error] || self.stopped || ![self steamClient:error] || self.stopped) return NO;
    [NSFileManager.defaultManager removeItemAtPath:[_root stringByAppendingPathComponent:@".download"] error:NULL];
    [self report:@"Downloaded." fraction:1];
    return YES;
}
@end
