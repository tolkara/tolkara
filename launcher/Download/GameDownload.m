#import "GameDownload.h"
#import "BlizzardContent.h"
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>

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
static NSString *hex(const uint8_t *bytes) {
    NSMutableString *text = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
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

@implementation TKGameDownload {
    NSDictionary *_configuration;
    NSString *_root, *_working, *_region, *_locale;
    atomic_bool _cancelled;
    NSURLSession *_session;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)regionsOfConfiguration:(NSDictionary *)configuration { return configuration[@"regions"]; }
+ (NSArray<NSString *> *)localesOfConfiguration:(NSDictionary *)configuration { return configuration[@"locales"]; }

+ (BOOL)validConfiguration:(id)configuration workingDirectory:(NSString *)workingDirectory {
    if (![configuration isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *block = configuration;
    NSSet *known = [NSSet setWithArray:@[@"service", @"product", @"regions", @"locales", @"tags", @"folder", @"root", @"settings"]];
    for (id key in block) if (![known containsObject:key]) return NO;
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
                     workingDirectory:(NSString *)workingDirectory region:(NSString *)region locale:(NSString *)locale {
    if (!(self = [super init])) return nil;
    if (![TKGameDownload validConfiguration:configuration workingDirectory:workingDirectory] || !plain_relative(workingDirectory)) return nil;
    BOOL known = NO;
    for (NSDictionary *item in configuration[@"regions"]) known = known || [item[@"id"] isEqual:region];
    if (!known || ![configuration[@"locales"] containsObject:locale]) return nil;
    _configuration = [configuration copy];
    _root = [documents stringByAppendingPathComponent:configuration[@"root"]];
    _working = [documents stringByAppendingPathComponent:workingDirectory];
    _region = [region copy]; _locale = [locale copy];
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
    NSString *buildInfo = [NSString stringWithFormat:@"%@\n%@\n", header, [row componentsJoinedByString:@"|"]];
    if (![files createDirectoryAtPath:[_root stringByAppendingPathComponent:@"Data"] withIntermediateDirectories:YES attributes:nil error:error] ||
        ![files createDirectoryAtPath:_working withIntermediateDirectories:YES attributes:nil error:error] ||
        ![buildInfo writeToFile:[_root stringByAppendingPathComponent:@".build.info"] atomically:YES encoding:NSUTF8StringEncoding error:error] ||
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
@end
