// The experimental downloader against a content server made up here: every
// file is synthetic, nothing of a publisher's is fetched or included.
#import "GameDownload.h"
#import "BlizzardContent.h"
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>
#include <assert.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSData *md5(NSData *data) {
    uint8_t digest[16]; CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:16];
}
static NSString *hex(NSData *data) {
    NSMutableString *text = [NSMutableString new];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}
static void be32(NSMutableData *out, uint32_t value) { uint8_t b[4] = {value >> 24, value >> 16, value >> 8, value}; [out appendBytes:b length:4]; }
static void be16(NSMutableData *out, uint16_t value) { uint8_t b[2] = {value >> 8, value}; [out appendBytes:b length:2]; }
static void cstring(NSMutableData *out, NSString *text) { [out appendBytes:text.UTF8String length:strlen(text.UTF8String) + 1]; }

// One plain chunk, with no chunk table.
static NSData *blte_plain(NSData *content) {
    NSMutableData *out = [NSMutableData dataWithBytes:"BLTE\0\0\0\0N" length:9];
    [out appendData:content];
    return out;
}
// Compressed chunks of `piece` bytes, with a chunk table.
static NSData *blte_chunks(NSData *content, NSUInteger piece) {
    NSMutableArray<NSData *> *chunks = [NSMutableArray new];
    for (NSUInteger at = 0; at < content.length; at += piece) {
        NSData *part = [content subdataWithRange:NSMakeRange(at, MIN(piece, content.length - at))];
        uLongf length = compressBound((uLong)part.length);
        NSMutableData *packed = [NSMutableData dataWithLength:length + 1];
        ((uint8_t *)packed.mutableBytes)[0] = 'Z';
        assert(compress((Bytef *)packed.mutableBytes + 1, &length, part.bytes, (uLong)part.length) == Z_OK);
        packed.length = length + 1;
        [chunks addObject:packed];
    }
    NSMutableData *out = [NSMutableData dataWithBytes:"BLTE" length:4];
    be32(out, (uint32_t)(12 + 24 * chunks.count));
    be32(out, 0x0F000000u | (uint32_t)chunks.count);
    for (NSData *chunk in chunks) { be32(out, (uint32_t)chunk.length); be32(out, 0); [out appendData:md5(chunk)]; }
    for (NSData *chunk in chunks) [out appendData:chunk];
    return out;
}
static bool collect(void *context, const uint8_t *bytes, size_t length) {
    [(__bridge NSMutableData *)context appendBytes:bytes length:length]; return true;
}
static bool refuse(void *context, const uint8_t *bytes, size_t length) { (void)context; (void)bytes; (void)length; return false; }
static void count_entry(void *context, const uint8_t *ekey, uint32_t size, uint32_t offset) {
    (void)ekey; (void)size; (void)offset; (*(unsigned *)context)++;
}

// tags: [[name, [entry numbers]]]; entries: [[name, content key, size]].
static NSData *install_manifest(NSArray *tags, NSArray *entries) {
    NSMutableData *out = [NSMutableData dataWithBytes:"IN\x01\x10" length:4];
    be16(out, (uint16_t)tags.count); be32(out, (uint32_t)entries.count);
    NSUInteger mask = (entries.count + 7) / 8;
    for (NSArray *tag in tags) {
        cstring(out, tag[0]); be16(out, 1);
        NSMutableData *bits = [NSMutableData dataWithLength:mask];
        for (NSNumber *entry in tag[1]) ((uint8_t *)bits.mutableBytes)[entry.unsignedIntValue / 8] |= 0x80 >> (entry.unsignedIntValue % 8);
        [out appendData:bits];
    }
    for (NSArray *entry in entries) { cstring(out, entry[0]); [out appendData:entry[1]]; be32(out, [entry[2] unsignedIntValue]); }
    return out;
}
// pairs: [[content key, encoded key]], two to a page so that a lookup crosses pages.
static NSData *encoding_table(NSArray<NSArray<NSData *> *> *pairs) {
    NSArray *sorted = [pairs sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSData *> *a, NSArray<NSData *> *b) {
        int order = memcmp(a[0].bytes, b[0].bytes, 16); return order < 0 ? NSOrderedAscending : order > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger pages = (sorted.count + 1) / 2;
    NSMutableData *out = [NSMutableData dataWithBytes:"EN\x01\x10\x10" length:5];
    be16(out, 1); be16(out, 1); be32(out, (uint32_t)pages); be32(out, 0);
    [out appendBytes:"\0" length:1]; be32(out, 5);
    [out appendBytes:"z\0n\0\0" length:5];   // the encoding specifications, not read
    for (NSUInteger page = 0; page < pages; page++) { [out appendData:sorted[page * 2][0]]; [out increaseLengthBy:16]; }
    for (NSUInteger page = 0; page < pages; page++) {
        NSMutableData *block = [NSMutableData new];
        for (NSUInteger i = page * 2; i < MIN(page * 2 + 2, sorted.count); i++) {
            [block appendBytes:"\x01\0\0\0\0\0" length:6]; [block appendData:sorted[i][0]]; [block appendData:sorted[i][1]];
        }
        block.length = 1024;
        [out appendData:block];
    }
    return out;
}
// items: [[encoded key, size, offset]].
static NSData *archive_index(NSArray *items) {
    NSMutableData *out = [NSMutableData new];
    for (NSArray *item in items) { [out appendData:item[0]]; be32(out, [item[1] unsignedIntValue]); be32(out, [item[2] unsignedIntValue]); }
    out.length = 4096;
    [out increaseLengthBy:8];
    uint8_t footer[12] = {1, 0, 0, 4, 4, 4, 16, 8, (uint8_t)items.count, 0, 0, 0};
    [out appendBytes:footer length:12];
    [out increaseLengthBy:8];
    return out;
}
static NSData *pattern(NSUInteger length, uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) bytes[i] = (uint8_t)(seed + i * 31 + (i >> 8));
    return data;
}

int main(void) {
    @autoreleasepool {
        // BLTE: plain and compressed chunks decode to the content; malformed input is refused.
        NSData *content = pattern(100000, 3);
        for (NSData *packed in @[blte_plain(content), blte_chunks(content, 30000), blte_chunks(content, 100000)]) {
            NSMutableData *out = [NSMutableData new];
            assert(bc_blte_decode(packed.bytes, packed.length, collect, (__bridge void *)out) && [out isEqual:content]);
            assert(!bc_blte_decode(packed.bytes, packed.length, refuse, NULL));
            assert(!bc_blte_decode(packed.bytes, 7, collect, (__bridge void *)out));
        }
        NSData *chunked = blte_chunks(content, 30000);
        for (NSUInteger cut = 8; cut < chunked.length; cut += 997) {
            NSMutableData *out = [NSMutableData new];
            assert(!bc_blte_decode(chunked.bytes, cut, collect, (__bridge void *)out));
        }
        NSMutableData *bad = [chunked mutableCopy];
        ((uint8_t *)bad.mutableBytes)[0] = 'X';
        assert(!bc_blte_decode(bad.bytes, bad.length, collect, (__bridge void *)[NSMutableData new]));
        bad = [chunked mutableCopy];
        ((uint8_t *)bad.mutableBytes)[12] = 0x7F;   // a chunk longer than the container
        assert(!bc_blte_decode(bad.bytes, bad.length, collect, (__bridge void *)[NSMutableData new]));
        bad = [blte_plain(content) mutableCopy];
        ((uint8_t *)bad.mutableBytes)[8] = 'E';     // encrypted: not supported
        assert(!bc_blte_decode(bad.bytes, bad.length, collect, (__bridge void *)[NSMutableData new]));

        // The made-up product: an executable in an archive, a small file on
        // its own, a file for another system and one outside the application.
        NSData *game = pattern(150000, 9), *info = [@"<plist/>" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *other = pattern(64, 1), *tool = pattern(64, 2);
        NSData *gameStored = blte_chunks(game, 40000), *infoStored = blte_plain(info);
        NSData *gameEkey = md5(gameStored), *infoEkey = md5(infoStored), *otherEkey = md5(other), *toolEkey = md5(tool);
        NSArray *entries = @[@[@"Game.app\\Contents\\MacOS\\Game", md5(game), @(game.length)],
                             @[@"Game.app\\Contents\\Info.plist", md5(info), @(info.length)],
                             @[@"Game.app\\Contents\\Other", md5(other), @(other.length)],
                             @[@"Tools\\Helper", md5(tool), @(tool.length)]];
        NSArray *tags = @[@[@"OSX", @[@0, @1, @3]], @[@"Windows", @[@2]], @[@"arm64", @[@0, @1, @2, @3]],
                          @[@"EU", @[@0, @1, @2, @3]], @[@"US", @[@0, @1, @2, @3]], @[@"enUS", @[@0, @1, @2, @3]]];
        NSData *manifest = install_manifest(tags, entries);
        BCInstall install;
        assert(bc_install_open(&install, manifest.bytes, manifest.length) && install.entry_count == 4 && install.tag_count == 6);
        int osx = bc_install_tag(&install, "OSX");
        assert(osx == 0 && bc_install_tag(&install, "Linux") == -1);
        assert(bc_install_has_tag(&install, 0, osx) && !bc_install_has_tag(&install, 2, osx) && !bc_install_has_tag(&install, 9, osx));
        const uint8_t *key; uint32_t size;
        assert(!strcmp(bc_install_entry(&install, 1, &key, &size), "Game.app\\Contents\\Info.plist") && size == info.length);
        assert(!memcmp(key, md5(info).bytes, 16) && !bc_install_entry(&install, 4, &key, &size));
        bc_install_close(&install);
        for (NSUInteger cut = 0; cut < manifest.length; cut++) assert(!bc_install_open(&install, manifest.bytes, cut));

        NSData *encoding = encoding_table(@[@[md5(game), gameEkey], @[md5(info), infoEkey], @[md5(other), otherEkey], @[md5(tool), toolEkey]]);
        NSMutableData *wanted = [NSMutableData new], *ekeys = [NSMutableData dataWithLength:48];
        [wanted appendData:md5(game)]; [wanted appendData:md5(tool)]; [wanted appendData:md5(content)];
        bool found[3];
        assert(bc_encoding_lookup(encoding.bytes, encoding.length, wanted.bytes, 3, ekeys.mutableBytes, found));
        assert(found[0] && found[1] && !found[2] && !memcmp(ekeys.bytes, gameEkey.bytes, 16) && !memcmp((const uint8_t *)ekeys.bytes + 16, toolEkey.bytes, 16));
        for (NSUInteger cut = 0; cut < encoding.length; cut += 61) assert(!bc_encoding_lookup(encoding.bytes, cut, wanted.bytes, 3, ekeys.mutableBytes, found));

        // The archive: some bytes, then the executable's stored form.
        NSMutableData *archive = [pattern(777, 5) mutableCopy];
        [archive appendData:gameStored];
        NSData *archiveKey = md5(archive), *index = archive_index(@[@[gameEkey, @(gameStored.length), @777], @[otherEkey, @64, @0]]);
        unsigned listed = 0;
        assert(bc_index_scan(index.bytes, index.length, count_entry, &listed) && listed == 2);
        assert(!bc_index_scan(index.bytes, 27, count_entry, &listed) && !bc_index_scan(index.bytes, index.length - 1, count_entry, &listed));
        bad = [index mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 28 + 14] = 9;   // a key width this reader does not know
        assert(!bc_index_scan(bad.bytes, bad.length, count_entry, &listed));
        bad = [index mutableCopy];
        ((uint8_t *)bad.mutableBytes)[bad.length - 28 + 17] = 9;   // more entries than the blocks hold
        assert(!bc_index_scan(bad.bytes, bad.length, count_entry, &listed));

        // The server.
        NSString *buildKey = hex(md5(pattern(8, 1))), *cdnKey = hex(md5(pattern(8, 2)));
        NSData *installStored = blte_chunks(manifest, 4096), *encodingStored = blte_chunks(encoding, 4096);
        NSString *base = @"https://cdn.example/tpr/test";
        NSString *(^address)(NSString *, NSString *) = ^(NSString *kind, NSString *name) {
            return [NSString stringWithFormat:@"%@/%@/%@/%@/%@", base, kind, [name substringToIndex:2], [name substringWithRange:NSMakeRange(2, 2)], name];
        };
        NSMutableDictionary<NSString *, NSData *> *server = [NSMutableDictionary new];
        server[@"https://eu.version.battle.net/v2/products/testp/versions"] = [[NSString stringWithFormat:
            @"Region!STRING:0|BuildConfig!HEX:16|CDNConfig!HEX:16|KeyRing!HEX:16|BuildId!DEC:4|VersionsName!String:0|ProductConfig!HEX:16\n"
            @"## seqn = 1\nus|%@|%@||7|9.9.9.7|\neu|%@|%@||7|1.2.3.7|\n", cdnKey, buildKey, buildKey, cdnKey] dataUsingEncoding:NSUTF8StringEncoding];
        server[@"https://eu.version.battle.net/v2/products/testp/cdns"] = [@"Name!STRING:0|Path!STRING:0|Hosts!STRING:0|Servers!STRING:0|ConfigPath!STRING:0\n"
            @"## seqn = 1\neu|tpr/test|cdn.example|http://cdn.example/?maxhosts=8 https://cdn.example/?maxhosts=8&fallback=1|tpr/configs/data\n" dataUsingEncoding:NSUTF8StringEncoding];
        server[address(@"config", buildKey)] = [[NSString stringWithFormat:@"# Build Configuration\n\nroot = %@\ninstall = %@ %@\nencoding = %@ %@\n",
            hex(md5(tool)), hex(md5(manifest)), hex(md5(installStored)), hex(md5(encoding)), hex(md5(encodingStored))] dataUsingEncoding:NSUTF8StringEncoding];
        server[address(@"data", hex(md5(installStored)))] = installStored;
        server[address(@"data", hex(md5(encodingStored)))] = encodingStored;
        server[address(@"config", cdnKey)] = [[NSString stringWithFormat:@"# CDN Configuration\n\narchives = %@\n", hex(archiveKey)] dataUsingEncoding:NSUTF8StringEncoding];
        server[[address(@"data", hex(archiveKey)) stringByAppendingString:@".index"]] = index;
        server[address(@"data", hex(archiveKey))] = archive;
        server[address(@"data", hex(infoEkey))] = infoStored;
        NSMutableArray<NSString *> *asked = [NSMutableArray new];
        TKGameDownloadFetch fetch = ^NSData *(NSURL *url, NSRange range, NSError **error) {
            @synchronized (asked) { [asked addObject:url.absoluteString]; }
            NSData *body = server[url.absoluteString];
            if (!body || NSMaxRange(range) > body.length) { if (error) *error = [NSError errorWithDomain:@"test" code:404 userInfo:nil]; return nil; }
            return range.length ? [body subdataWithRange:range] : body;
        };

        NSDictionary *block = @{@"service": @"blizzard", @"product": @"testp",
            @"regions": @[@{@"id": @"eu", @"name": @"Europe", @"portal": @"EU"}, @{@"id": @"us", @"name": @"Americas", @"portal": @"US"}],
            @"locales": @[@"enUS", @"deDE"], @"tags": @[@"OSX", @"arm64"], @"folder": @"Game.app", @"root": @"Game",
            @"settings": @{@"file": @"WTF/Config.wtf", @"region": @"portal", @"text": @"textLocale", @"audio": @"audioLocale"}};
        NSString *working = @"Game/_flavor_";
        assert([TKGameDownload validConfiguration:block workingDirectory:working runtime:nil] && [TKGameDownload validConfiguration:block workingDirectory:@"Game" runtime:nil]);
        assert([[TKGameDownload regionsOfConfiguration:block] count] == 2 && [[TKGameDownload localesOfConfiguration:block] count] == 2);
        // Data only, inside Documents, and nothing this reader does not know.
        NSArray<NSDictionary *> *changes = @[@{@"service": @"other"}, @{@"product": @"../x"}, @{@"regions": @[]}, @{@"regions": @[@{@"id": @"EU", @"name": @"E", @"portal": @"EU"}]},
            @{@"regions": @[@{@"id": @"eu", @"name": @"E", @"portal": @"EU", @"host": @"x"}]}, @{@"locales": @[@"english"]}, @{@"tags": @[]}, @{@"tags": @[@"a b"]},
            @{@"folder": @"../Game.app"}, @{@"folder": @"a/b"}, @{@"root": @"/Game"}, @{@"root": @"Other"}, @{@"root": @"Game/.."},
            @{@"settings": @{@"file": @"../Config.wtf", @"region": @"portal", @"text": @"t", @"audio": @"a"}},
            @{@"settings": @{@"file": @"Config.wtf", @"region": @"por tal", @"text": @"t", @"audio": @"a"}}, @{@"script": @"run.sh"}];
        for (NSDictionary *change in changes) {
            NSMutableDictionary *changed = [block mutableCopy];
            [changed addEntriesFromDictionary:change];
            assert(![TKGameDownload validConfiguration:changed workingDirectory:working runtime:nil]);
        }
        assert(![TKGameDownload validConfiguration:@[] workingDirectory:working runtime:nil]);
        // An application of its own: not for a profile with a runtime.
        assert(![TKGameDownload validConfiguration:block workingDirectory:working runtime:@"Game/Runtime"]);
        assert(![TKGameDownload profileIsInPlace:(@{@"workingDirectory": working, @"executable": @"Game.app/Contents/MacOS/Game", @"download": block}) documents:NSTemporaryDirectory()]);

        NSString *documents = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        assert(![[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:nil region:@"kr" locale:@"enUS"]);
        assert(![[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:nil region:@"eu" locale:@"frFR"]);
        TKGameDownload *download = [[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:nil region:@"eu" locale:@"enUS"];
        download.fetch = fetch;
        __block double last = -1; __block BOOL ordered = YES;
        download.progress = ^(NSString *phase, double fraction) { (void)phase; @synchronized (asked) { ordered = ordered && fraction >= last - 1e-9 && fraction <= 1; last = fraction; } };
        NSError *error = nil;
        BOOL ran = [download run:&error];
        if (!ran || error) printf("first run: %s\n", error.localizedDescription.UTF8String);
        assert(ran && !error && ordered && last == 1);
        NSString *app = [documents stringByAppendingPathComponent:@"Game/_flavor_/Game.app/Contents"];
        assert([[NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"MacOS/Game"]] isEqual:game]);
        assert([[NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]] isEqual:info]);
        // Another system's file and a file outside the application are not fetched.
        assert(![files fileExistsAtPath:[app stringByAppendingPathComponent:@"Other"]]);
        assert(![files fileExistsAtPath:[documents stringByAppendingPathComponent:@"Game/_flavor_/Tools"]] && ![files fileExistsAtPath:[documents stringByAppendingPathComponent:@"Tools"]]);
        NSString *buildInfo = [NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"Game/.build.info"] encoding:NSUTF8StringEncoding error:NULL];
        NSString *row = [NSString stringWithFormat:@"eu|1|%@|%@|||tpr/test|cdn.example|http://cdn.example/?maxhosts=8 https://cdn.example/?maxhosts=8&fallback=1|"
            @"OSX x86_64 EU? enUS speech?:OSX x86_64 EU? enUS text?|||1.2.3.7||testp\n", buildKey, cdnKey];
        assert([buildInfo hasPrefix:@"Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|"] && [buildInfo hasSuffix:row] && [buildInfo componentsSeparatedByString:@"\n"].count == 3);
        assert([[NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"Game/_flavor_/.flavor.info"] encoding:NSUTF8StringEncoding error:NULL]
                isEqual:@"Product Flavor!STRING:0\ntestp\n"]);
        NSString *settingsPath = [documents stringByAppendingPathComponent:@"Game/_flavor_/WTF/Config.wtf"];
        assert([[NSString stringWithContentsOfFile:settingsPath encoding:NSUTF8StringEncoding error:NULL]
                isEqual:@"SET textLocale \"enUS\"\nSET portal \"EU\"\nSET audioLocale \"enUS\"\n"]);
        BOOL directory = NO;
        assert([files fileExistsAtPath:[documents stringByAppendingPathComponent:@"Game/Data"] isDirectory:&directory] && directory);
        // The archive's index is kept where the game keeps its own.
        NSString *indexPath = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"Game/Data/indices/%@.index", hex(archiveKey)]];
        assert([[NSData dataWithContentsOfFile:indexPath] isEqual:index]);
        // The executable came as a part of the archive, not the whole archive.
        assert(server[address(@"data", hex(archiveKey))].length > gameStored.length && [asked containsObject:address(@"data", hex(archiveKey))]);

        // Again with everything in place: only the lists are asked for, the
        // user's settings stay, and a file that changed is fetched again.
        [@"SET portal \"US\"\n" writeToFile:settingsPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // Another product installed in the same folder keeps its row; this
        // product's old row is replaced, not repeated.
        NSString *otherRow = @"us|1|00000000000000000000000000000001|00000000000000000000000000000002|||tpr/test|h|s|OSX|||0.0.1||otherp";
        NSString *staleRow = @"eu|1|00000000000000000000000000000003|00000000000000000000000000000004|||tpr/test|h|s|OSX|||0.0.0||testp";
        NSString *buildInfoPath = [documents stringByAppendingPathComponent:@"Game/.build.info"];
        [[NSString stringWithFormat:@"%@\n%@\n%@\n", [buildInfo componentsSeparatedByString:@"\n"][0], otherRow, staleRow]
            writeToFile:buildInfoPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [asked removeAllObjects];
        download = [[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:nil region:@"eu" locale:@"enUS"];
        download.fetch = fetch;
        assert([download run:&error] && asked.count == 4);
        NSArray<NSString *> *merged = [[NSString stringWithContentsOfFile:buildInfoPath encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];
        assert(merged.count == 4 && [merged[1] isEqual:otherRow] && [[merged[2] stringByAppendingString:@"\n"] isEqual:row]);
        assert([[NSString stringWithContentsOfFile:settingsPath encoding:NSUTF8StringEncoding error:NULL] isEqual:@"SET portal \"US\"\n"]);
        [pattern(info.length, 7) writeToFile:[app stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
        [asked removeAllObjects];
        assert([download run:&error] && [[NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]] isEqual:info]);
        assert([asked containsObject:address(@"data", hex(infoEkey))] && ![asked containsObject:address(@"data", hex(archiveKey))]);
        // The index on disk was used: it is not fetched a second time.
        assert(![asked containsObject:[address(@"data", hex(archiveKey)) stringByAppendingString:@".index"]]);

        // Content that does not match the file list is not put in place.
        NSString *second = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSData *intact = server[address(@"data", hex(infoEkey))];
        server[address(@"data", hex(infoEkey))] = blte_plain([@"<other/>" dataUsingEncoding:NSUTF8StringEncoding]);
        download = [[TKGameDownload alloc] initWithConfiguration:block documents:second workingDirectory:working runtime:nil region:@"eu" locale:@"enUS"];
        download.fetch = fetch;
        error = nil;
        assert(![download run:&error] && [error.domain isEqual:TKGameDownloadErrorDomain] && [error.localizedDescription containsString:@"Info.plist"]);
        NSString *secondApp = [second stringByAppendingPathComponent:@"Game/_flavor_/Game.app/Contents"];
        assert(![files fileExistsAtPath:[secondApp stringByAppendingPathComponent:@"Info.plist"]] &&
               ![files fileExistsAtPath:[secondApp stringByAppendingPathComponent:@"Info.plist.part"]]);
        // Nothing that says the application is installed is written after a failure.
        assert(![files fileExistsAtPath:[second stringByAppendingPathComponent:@"Game/.build.info"]]);
        server[address(@"data", hex(infoEkey))] = intact;

        // A file list that names a path outside the application is refused whole.
        NSData *escaping = install_manifest(tags, @[@[@"Game.app\\..\\..\\outside", md5(info), @(info.length)], entries[1], entries[2], entries[3]]);
        NSData *escapingStored = blte_plain(escaping);
        NSData *goodBuild = server[address(@"config", buildKey)];
        server[address(@"config", buildKey)] = [[NSString stringWithFormat:@"install = %@ %@\nencoding = %@ %@\n",
            hex(md5(escaping)), hex(md5(escapingStored)), hex(md5(encoding)), hex(md5(encodingStored))] dataUsingEncoding:NSUTF8StringEncoding];
        server[address(@"data", hex(md5(escapingStored)))] = escapingStored;
        NSString *third = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        download = [[TKGameDownload alloc] initWithConfiguration:block documents:third workingDirectory:working runtime:nil region:@"eu" locale:@"enUS"];
        download.fetch = fetch;
        error = nil;
        assert(![download run:&error] && [error.localizedDescription containsString:@"outside"] && ![files fileExistsAtPath:third]);
        server[address(@"config", buildKey)] = goodBuild;

        // A region the server does not list, an answer that is not a table, and a stop.
        download = [[TKGameDownload alloc] initWithConfiguration:block documents:third workingDirectory:working runtime:nil region:@"us" locale:@"enUS"];
        download.fetch = fetch;
        error = nil;
        assert(![download run:&error] && error && ![files fileExistsAtPath:third]);
        download = [[TKGameDownload alloc] initWithConfiguration:block documents:third workingDirectory:working runtime:nil region:@"eu" locale:@"enUS"];
        download.fetch = fetch;
        [download cancel];
        error = nil;
        assert(![download run:&error] && [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSUserCancelledError);
        [files removeItemAtPath:documents error:NULL]; [files removeItemAtPath:second error:NULL];
        puts("game download: container, file list, storage table and archive index readers with malformed input; a download from a made-up server, "
             "its resume, a changed file, mismatched content, a path outside the application, an unknown region and a stop: PASS");
    }
    return 0;
}
