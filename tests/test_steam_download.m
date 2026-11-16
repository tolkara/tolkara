// The "steam" download against servers made up here: the runtime archive,
// Valve's list and its packages are all synthetic, nothing of Valve's or of
// a Windows runtime is fetched or included.
#import "GameDownload.h"
#import "zip_writer.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

static NSString *sha256(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}
static NSData *pattern(NSUInteger length, uint8_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) bytes[i] = (uint8_t)(seed + i * 31 + (i >> 8) * 7 + (i >> 13));
    return data;
}
static NSData *text(NSString *string) { return [string dataUsingEncoding:NSUTF8StringEncoding]; }
// entries: [[name, content, deflated, Unix mode or 0]].
static NSData *zip(NSArray<NSArray *> *entries) {
    ZipWriter writer = {0};
    for (NSArray *entry in entries)
        zw_add(&writer, [entry[0] UTF8String], [entry[1] bytes], [entry[1] length], [entry[2] boolValue], [entry[3] unsignedIntValue]);
    zw_finish(&writer);
    NSData *data = [NSData dataWithBytes:writer.file.bytes length:writer.file.size];
    zw_free(&writer);
    return data;
}
static mode_t mode_of(NSString *path) { struct stat status; return stat(path.fileSystemRepresentation, &status) ? 0 : status.st_mode & 07777; }
static NSData *read_file(NSString *path) { return [NSData dataWithContentsOfFile:path]; }
// A new folder for Documents: in TMPDIR when set, as the other tests' are.
static NSString *fresh(void) {
    const char *temporary = getenv("TMPDIR");
    return [(temporary && *temporary ? @(temporary) : NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *working = @"Steam/prefix/drive_c/Program Files (x86)/Steam", *runtime = @"Steam/Wine";

        // The runtime archive: the runtime, an empty prefix, and the list of
        // files the prefix repeats from the runtime.
        NSData *wine = pattern(200000, 4), *kernel = pattern(50000, 8), *registry = text(@"WINE REGISTRY Version 2\n"), *ini = text(@"[fonts]\r\n");
        NSString *linkList = @"prefix/drive_c/windows/system32/kernel32.dll\tWine/lib/wine/x86_64-windows/kernel32.dll\r\n\n"
            @"Wine/copy/of.dll\tWine/lib/wine/x86_64-windows/kernel32.dll\n";
        NSArray *runtimeEntries = @[@[@"Wine/lib/wine/aarch64-unix/wine", wine, @YES, @(S_IFREG | 0755)],
            @[@"prefix/system.reg", registry, @YES, @(S_IFREG | 0644)],
            @[@"Wine/lib/wine/x86_64-windows/kernel32.dll", kernel, @NO, @(S_IFREG | 0644)],
            @[@"Wine/share/", NSData.data, @NO, @(S_IFDIR | 0755)],
            @[@"tolkara-links.txt", text(linkList), @YES, @(S_IFREG | 0644)],
            @[@"prefix/drive_c/windows/win.ini", ini, @NO, @0]];
        NSData *runtimeZip = zip(runtimeEntries);
        NSString *runtimeURL = @"https://releases.example/download/tolkara-windows-runtime-1.zip";

        // Valve's list as its server words it, and the packages it names.
        NSData *bins = pattern(70000, 1), *strings = pattern(3000, 2), *program = pattern(40000, 3), *library = pattern(900, 5);
        NSData *installer = zip(@[@[@"steam.exe", program, @YES, @0], @[@"bin\\shaders/", NSData.data, @NO, @0],
            @[@"bin\\shaders/basic.txt", text(@"shader"), @NO, @0], @[@"package/beta", text(@"not ours"), @NO, @0], @[@"Steam.dll", library, @YES, @0]]);
        NSString *binsName = [NSString stringWithFormat:@"bins_win64.zip.vz.4a749655f0aa_%lu", (unsigned long)bins.length];
        NSString *stringsName = @"strings_en_all.zip.e716a6", *installerName = @"steam_win64.zip.42bca4";
        NSString *list = [NSString stringWithFormat:@"\"win64\"\n{\n\t\"version\"\t\t\"1794536281\"\n\t\"ostype\"\t\t\"win10\"\n"
            @"\t\"bins_win64\"\n\t{\n\t\t\"file\"\t\t\"bins_win64.zip.4a74\"\n\t\t\"size\"\t\t\"99\"\n\t\t\"sha2\"\t\t\"%@\"\n"
            @"\t\t\"zipvz\"\t\t\"%@\"\n\t\t\"sha2vz\"\t\t\"%@\"\n\t}\n"
            @"\t\"strings_en_all\"\n\t{\n\t\t\"file\"\t\t\"%@\"\n\t\t\"size\"\t\t\"%lu\"\n\t\t\"sha2\"\t\t\"%@\"\n\t}\n"
            @"\t\"steam_win64\"\n\t{\n\t\t\"steamchina\"\n\t\t{\n\t\t\t\"file\"\t\t\"steam_win64_steamchina.zip.c35f\"\n\t\t\t\"size\"\t\t\"5\"\n"
            @"\t\t\t\"sha2\"\t\t\"%@\"\n\t\t\t\"IsBootstrapperPackage\"\t\t\"1\"\n\t\t}\n"
            @"\t\t\"file\"\t\t\"%@\"\n\t\t\"size\"\t\t\"%lu\"\n\t\t\"sha2\"\t\t\"%@\"\n"
            @"\t\t\"zipvz\"\t\t\"steam_win64.zip.vz.6b35_77\"\n\t\t\"sha2vz\"\t\t\"%@\"\n\t\t\"IsBootstrapperPackage\"\t\t\"1\"\n\t}\n"
            @"\t\"steamchina\"\n\t{\n\t\t\"file\"\t\t\"steamchina.zip.11\"\n\t\t\"size\"\t\t\"5\"\n\t\t\"sha2\"\t\t\"%@\"\n\t\t\"IsBootstrapperPackage\"\t\t\"1\"\n\t}\n"
            @"}\n\"kvsign2\"\n{\n\t\"win64\"\t\t\"cadeb91a\"\n}\n",
            sha256(strings), binsName, sha256(bins), stringsName, (unsigned long)strings.length, sha256(strings),
            sha256(bins), installerName, (unsigned long)installer.length, sha256(installer), sha256(bins), sha256(bins)];
        NSString *valve = @"https://client-update.steamstatic.com/";
        NSMutableDictionary<NSString *, NSData *> *server = [NSMutableDictionary new];
        server[runtimeURL] = runtimeZip;
        server[[valve stringByAppendingString:@"steam_client_win64"]] = text(list);
        server[[valve stringByAppendingString:binsName]] = bins;
        server[[valve stringByAppendingString:stringsName]] = strings;
        server[[valve stringByAppendingString:installerName]] = installer;
        // Each request as "url from+length"; `failing` makes that request fail, `shortened` answers with less.
        NSMutableArray<NSString *> *asked = [NSMutableArray new];
        __block NSString *failing = nil, *shortened = nil;
        TKGameDownloadFetch fetch = ^NSData *(NSURL *url, NSRange range, NSError **error) {
            NSString *request = [NSString stringWithFormat:@"%@ %lu+%lu", url.absoluteString, (unsigned long)range.location, (unsigned long)range.length];
            [asked addObject:request];
            NSData *body = server[url.absoluteString];
            if (!body || NSMaxRange(range) > body.length || [request isEqual:failing]) { if (error) *error = [NSError errorWithDomain:@"test" code:404 userInfo:nil]; return nil; }
            if ([request isEqual:shortened]) return [body subdataWithRange:NSMakeRange(range.location, range.length - 1)];
            return range.length ? [body subdataWithRange:range] : body;
        };
        NSUInteger (^requests)(NSString *) = ^NSUInteger(NSString *address) {
            NSUInteger count = 0;
            for (NSString *request in asked) if ([request hasPrefix:[address stringByAppendingString:@" "]]) count++;
            return count;
        };

        NSDictionary *(^blockFor)(NSData *) = ^NSDictionary *(NSData *archive) {
            return @{@"service": @"steam", @"root": @"Steam", @"client": @"steam_client_win64",
                     @"runtime": @{@"url": runtimeURL, @"sha256": sha256(archive), @"size": @(archive.length)}};
        };
        NSDictionary *block = blockFor(runtimeZip);
        NSDictionary *profile = @{@"id": @"s", @"name": @"S", @"workingDirectory": working, @"runtime": runtime,
                                  @"executable": @"lib/wine/aarch64-unix/wine", @"download": block};

        // The block: exactly these keys, inside Documents, a runtime profile.
        assert([TKGameDownload validConfiguration:block workingDirectory:working runtime:runtime]);
        assert(![[TKGameDownload regionsOfConfiguration:block] count] && ![[TKGameDownload localesOfConfiguration:block] count]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:working runtime:nil]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:@"Steam" runtime:runtime]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:@"Other/Steam" runtime:runtime]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:working runtime:@"Wine"]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:working runtime:@"Steam/../Wine"]);
        assert(![TKGameDownload validConfiguration:block workingDirectory:working runtime:@"Steam"]);
        NSDictionary *archive = block[@"runtime"];
        NSMutableDictionary *(^with)(NSDictionary *, NSDictionary *) = ^NSMutableDictionary *(NSDictionary *base, NSDictionary *change) {
            NSMutableDictionary *changed = [base mutableCopy]; [changed addEntriesFromDictionary:change]; return changed;
        };
        NSString *longURL = [@"https://releases.example/" stringByPaddingToLength:513 withString:@"a" startingAtIndex:0];
        NSArray<NSDictionary *> *changes = @[@{@"root": @"/Steam"}, @{@"root": @"Steam/.."}, @{@"root": @"Other"}, @{@"root": @1}, @{@"client": @"steam_client_"},
            @{@"client": @"steam_client_../x"}, @{@"client": @"steam_cmd_win64"}, @{@"client": @"steam_client_WIN64"}, @{@"script": @"run.sh"},
            @{@"product": @"steam"}, @{@"runtime": @"https://releases.example/r.zip"}, @{@"runtime": with(archive, @{@"url": @"http://releases.example/r.zip"})},
            @{@"runtime": with(archive, @{@"url": @"https://"})}, @{@"runtime": with(archive, @{@"url": @"https://releases.example/r .zip"})},
            @{@"runtime": with(archive, @{@"url": longURL})}, @{@"runtime": with(archive, @{@"url": @7})},
            @{@"runtime": with(archive, @{@"sha256": @"abc"})}, @{@"runtime": with(archive, @{@"sha256": [archive[@"sha256"] uppercaseString]})},
            @{@"runtime": with(archive, @{@"size": @0})}, @{@"runtime": with(archive, @{@"size": @(-5)})}, @{@"runtime": with(archive, @{@"size": @1.5})},
            @{@"runtime": with(archive, @{@"size": @YES})}, @{@"runtime": with(archive, @{@"size": @"12"})}, @{@"runtime": with(archive, @{@"size": @((1ull << 32) + 1)})},
            @{@"runtime": with(archive, @{@"mirror": @"https://other.example/r.zip"})}];
        for (NSDictionary *change in changes) assert(![TKGameDownload validConfiguration:with(block, change) workingDirectory:working runtime:runtime]);
        for (NSString *missing in @[@"root", @"client", @"runtime"]) {
            NSMutableDictionary *less = [block mutableCopy]; [less removeObjectForKey:missing];
            assert(![TKGameDownload validConfiguration:less workingDirectory:working runtime:runtime]);
        }
        assert([TKGameDownload validConfiguration:with(block, @{@"runtime": with(archive, @{@"size": @(1ull << 32), @"url": [longURL substringToIndex:512]})})
                                 workingDirectory:working runtime:runtime]);

        NSString *documents = fresh();
        TKGameDownload *(^downloadInto)(NSString *, NSDictionary *) = ^TKGameDownload *(NSString *folder, NSDictionary *configuration) {
            TKGameDownload *download = [[TKGameDownload alloc] initWithConfiguration:configuration documents:folder workingDirectory:working
                                                                              runtime:runtime region:nil locale:nil];
            assert(download);
            download.fetch = fetch; download.chunk = 16384;
            return download;
        };
        // No region or language is asked, and none is taken.
        assert(![[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:runtime region:@"eu" locale:@"enUS"]);
        assert(![[TKGameDownload alloc] initWithConfiguration:block documents:documents workingDirectory:working runtime:nil region:nil locale:nil]);
        assert(![TKGameDownload profileIsInPlace:profile documents:documents]);

        // A chunk of the runtime fails: what came before it stays, nothing is unpacked.
        NSString *root = [documents stringByAppendingPathComponent:@"Steam"], *steamFolder = [documents stringByAppendingPathComponent:working];
        NSString *part = [root stringByAppendingPathComponent:@".download/runtime.zip.part"], *marker = [root stringByAppendingPathComponent:@".tolkara-runtime"];
        failing = [NSString stringWithFormat:@"%@ 32768+16384", runtimeURL];
        NSError *error = nil;
        assert(![downloadInto(documents, block) run:&error] && [error.domain isEqual:@"test"]);
        assert(read_file(part).length == 32768 && ![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine"]] && ![files fileExistsAtPath:marker]);
        failing = nil;

        // Stopped while Steam's packages come: the runtime is complete, Steam is not installed.
        TKGameDownload *download = downloadInto(documents, block);
        __weak TKGameDownload *stopping = download;
        NSMutableArray<NSString *> *phases = [NSMutableArray new];
        download.progress = ^(NSString *phase, double fraction) { (void)fraction; [phases addObject:phase]; if ([phase hasPrefix:@"Downloading Steam… 0 of"] && fraction > 0.62) [stopping cancel]; };
        [asked removeAllObjects];
        error = nil;
        assert(![download run:&error] && [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSUserCancelledError);
        // The runtime continued where the failed run left it.
        assert(([asked[0] isEqual:[NSString stringWithFormat:@"%@ 32768+16384", runtimeURL]]));
        assert([phases containsObject:@"Unpacking the Windows runtime…"] && [phases[0] hasPrefix:@"Downloading the Windows runtime… 0 of 0 MB"]);
        assert([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL] isEqual:[sha256(runtimeZip) stringByAppendingString:@"\n"]]);
        assert(![files fileExistsAtPath:part] && ![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:@"steam.exe"]]);
        assert(![TKGameDownload profileIsInPlace:profile documents:documents]);
        NSString *binsPart = [root stringByAppendingPathComponent:[NSString stringWithFormat:@".download/%@.part", binsName]];
        NSUInteger binsHad = read_file(binsPart).length;
        assert(binsHad > 0 && binsHad < bins.length && binsHad % 16384 == 0);

        // The rest: only what is missing is asked for.
        download = downloadInto(documents, block);
        __block double last = -1; __block BOOL ordered = YES;
        [phases removeAllObjects];
        download.progress = ^(NSString *phase, double fraction) { [phases addObject:phase]; ordered = ordered && fraction >= last - 1e-9 && fraction <= 1; last = fraction; };
        [asked removeAllObjects];
        error = nil;
        BOOL ran = [download run:&error];
        if (!ran) printf("steam download: %s\n", error.localizedDescription.UTF8String);
        assert(ran && !error && ordered && last == 1 && [phases.lastObject isEqual:@"Downloaded."]);
        assert(!requests(runtimeURL) && [asked[0] isEqual:[valve stringByAppendingString:@"steam_client_win64 0+0"]]);
        assert(([asked[1] isEqual:[NSString stringWithFormat:@"%@%@ %lu+16384", valve, binsName, (unsigned long)binsHad]]));
        // Something that fits in one chunk is asked for whole; another edition's installer is not asked for.
        assert(([asked containsObject:[NSString stringWithFormat:@"%@%@ 0+0", valve, stringsName]]) && !requests([valve stringByAppendingString:@"steamchina.zip.11"]));
        assert(!requests([valve stringByAppendingString:@"steam_win64.zip.vz.6b35_77"]) && !requests([valve stringByAppendingString:@"steam_win64_steamchina.zip.c35f"]));
        BOOL told = NO;
        for (NSString *phase in phases) told = told || [phase hasPrefix:@"Downloading Steam… "];
        assert(told);

        // The runtime with its executable bits, the prefix, and the copies.
        NSString *winePath = [root stringByAppendingPathComponent:@"Wine/lib/wine/aarch64-unix/wine"];
        NSString *kernelPath = [root stringByAppendingPathComponent:@"Wine/lib/wine/x86_64-windows/kernel32.dll"];
        NSString *registryPath = [root stringByAppendingPathComponent:@"prefix/system.reg"], *iniPath = [root stringByAppendingPathComponent:@"prefix/drive_c/windows/win.ini"];
        NSString *copyPath = [root stringByAppendingPathComponent:@"prefix/drive_c/windows/system32/kernel32.dll"];
        assert([read_file(winePath) isEqual:wine] && mode_of(winePath) == 0755);
        assert([read_file(kernelPath) isEqual:kernel] && mode_of(kernelPath) == 0644);
        assert([read_file(registryPath) isEqual:registry] && [read_file(iniPath) isEqual:ini] && mode_of(iniPath) == 0644);
        assert([read_file(copyPath) isEqual:kernel] && [read_file([root stringByAppendingPathComponent:@"Wine/copy/of.dll"]) isEqual:kernel]);
        assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@"tolkara-links.txt"]]);
        // Steam: the installer unpacked, the other packages where its updater keeps them.
        assert([read_file([steamFolder stringByAppendingPathComponent:@"steam.exe"]) isEqual:program]);
        assert([read_file([steamFolder stringByAppendingPathComponent:@"Steam.dll"]) isEqual:library]);
        assert([read_file([steamFolder stringByAppendingPathComponent:@"bin/shaders/basic.txt"]) isEqual:text(@"shader")]);
        NSArray *kept = [[files contentsOfDirectoryAtPath:[steamFolder stringByAppendingPathComponent:@"package"] error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        assert([kept isEqual:(@[binsName, stringsName])]);
        assert([read_file([steamFolder stringByAppendingPathComponent:[@"package/" stringByAppendingString:binsName]]) isEqual:bins]);
        assert([read_file([steamFolder stringByAppendingPathComponent:[@"package/" stringByAppendingString:stringsName]]) isEqual:strings]);
        assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@".download"]]);
        NSArray *top = [[files contentsOfDirectoryAtPath:root error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        assert([top isEqual:(@[@".tolkara-runtime", @"Wine", @"prefix"])] && [[files contentsOfDirectoryAtPath:documents error:NULL] count] == 1);
        assert([TKGameDownload profileIsInPlace:profile documents:documents]);

        // Again with everything here: nothing is asked for at all.
        [asked removeAllObjects];
        assert([downloadInto(documents, block) run:&error] && !asked.count);

        // A newer runtime over an installation: the runtime's folder is
        // replaced; the prefix and Steam in it are the user's and stay.
        NSData *wine2 = pattern(90000, 6);
        NSData *runtimeZip2 = zip(@[@[@"Wine/lib/wine/aarch64-unix/wine", wine2, @YES, @(S_IFREG | 0755)], runtimeEntries[1], runtimeEntries[2], runtimeEntries[4],
            runtimeEntries[5], @[@"prefix/drive_c/new.txt", text(@"new"), @NO, @0]]);
        server[runtimeURL] = runtimeZip2;
        [text(@"user registry") writeToFile:registryPath atomically:YES];
        [text(@"user copy") writeToFile:copyPath atomically:YES];
        [text(@"stale") writeToFile:[root stringByAppendingPathComponent:@"Wine/stale.so"] atomically:YES];
        [asked removeAllObjects];
        assert([downloadInto(documents, blockFor(runtimeZip2)) run:&error]);
        assert([read_file(winePath) isEqual:wine2] && ![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine/stale.so"]]);
        assert([read_file(registryPath) isEqual:text(@"user registry")] && [read_file(copyPath) isEqual:text(@"user copy")]);
        assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@"prefix/drive_c/new.txt"]]);
        assert([read_file([root stringByAppendingPathComponent:@"Wine/copy/of.dll"]) isEqual:kernel]);
        assert([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL] hasPrefix:sha256(runtimeZip2)]);
        // steam.exe is here: Valve's server is not asked.
        assert(requests(runtimeURL) && !requests([valve stringByAppendingString:@"steam_client_win64"]));
        // Steam missing, the runtime in place: only Steam is fetched.
        [files removeItemAtPath:[steamFolder stringByAppendingPathComponent:@"steam.exe"] error:NULL];
        assert(![TKGameDownload profileIsInPlace:profile documents:documents]);
        [asked removeAllObjects];
        assert([downloadInto(documents, blockFor(runtimeZip2)) run:&error] && !requests(runtimeURL));
        // The packages that are intact are not fetched again; the installer is.
        assert(asked.count == 1 + requests([valve stringByAppendingString:installerName]) && [read_file([steamFolder stringByAppendingPathComponent:@"steam.exe"]) isEqual:program]);
        server[runtimeURL] = runtimeZip;
        [files removeItemAtPath:documents error:NULL];

        // A runtime archive that is not the one the profile names is removed, not unpacked.
        documents = fresh(); root = [documents stringByAppendingPathComponent:@"Steam"];
        error = nil;
        assert(![downloadInto(documents, with(block, @{@"runtime": with(archive, @{@"sha256": sha256(bins)})})) run:&error]);
        assert([error.domain isEqual:TKGameDownloadErrorDomain] && [error.localizedDescription containsString:@"checksum"]);
        assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@".download/runtime.zip.part"]] &&
               ![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine"]] && ![files fileExistsAtPath:[root stringByAppendingPathComponent:@".tolkara-runtime"]]);
        // A server that answers a ranged request with another amount.
        shortened = [NSString stringWithFormat:@"%@ 16384+16384", runtimeURL];
        error = nil;
        assert(![downloadInto(documents, block) run:&error] && [error.localizedDescription containsString:@"different amount"]);
        shortened = nil;
        // A size that is not the archive's: more than the server has, or less.
        assert(![downloadInto(documents, with(block, @{@"runtime": with(archive, @{@"size": @(runtimeZip.length + 1)})})) run:&error]);
        assert(![downloadInto(documents, with(block, @{@"runtime": with(archive, @{@"size": @(runtimeZip.length - 1)})})) run:&error]);
        assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine"]] && ![files fileExistsAtPath:[root stringByAppendingPathComponent:@".tolkara-runtime"]]);
        [files removeItemAtPath:documents error:NULL];

        // Runtime archives that reach outside their folder, or are not plain files, are refused whole.
        NSArray *good = @[runtimeEntries[0], runtimeEntries[1]];
        NSArray<NSArray *> *hostile = @[
            @[@[@"../escaped.txt", text(@"x"), @NO, @0]], @[@[@"/escaped.txt", text(@"x"), @NO, @0]], @[@[@"Wine/../../escaped.txt", text(@"x"), @NO, @0]],
            @[@[@"Wine\\..\\..\\escaped.txt", text(@"x"), @NO, @0]], @[@[@"Wine//escaped.txt", text(@"x"), @NO, @0]],
            @[@[@".download/escaped.txt", text(@"x"), @NO, @0]], @[@[@".tolkara-runtime", text(@"x"), @NO, @0]],
            @[@[@"Wine/link", text(@"/etc/passwd"), @NO, @(S_IFLNK | 0777)]],
            @[@[@"tolkara-links.txt", text(@"../escaped.txt\tWine/lib/wine/aarch64-unix/wine\n"), @NO, @0]],
            @[@[@"tolkara-links.txt", text(@"/escaped.txt\tWine/lib/wine/aarch64-unix/wine\n"), @NO, @0]],
            @[@[@"tolkara-links.txt", text(@"Wine/a\t../../etc/passwd\n"), @NO, @0]],
            @[@[@"tolkara-links.txt", text(@"Wine/a\tWine/missing.dll\n"), @NO, @0]],
            @[@[@"tolkara-links.txt", text(@"Wine/a Wine/lib/wine/aarch64-unix/wine\n"), @NO, @0]],
            @[@[@"tolkara-links.txt", text(@"Wine\\a\tWine/lib/wine/aarch64-unix/wine\n"), @NO, @0]]];
        for (NSArray *extra in hostile) {
            documents = fresh(); root = [documents stringByAppendingPathComponent:@"Steam"];
            NSData *bad = zip([good arrayByAddingObjectsFromArray:extra]);
            server[runtimeURL] = bad;
            error = nil;
            assert(![downloadInto(documents, blockFor(bad)) run:&error] && [error.domain isEqual:TKGameDownloadErrorDomain]);
            assert(![files fileExistsAtPath:[root stringByAppendingPathComponent:@".tolkara-runtime"]]);
            assert(![files fileExistsAtPath:[documents stringByAppendingPathComponent:@"escaped.txt"]] &&
                   ![files fileExistsAtPath:[documents.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"escaped.txt"]] &&
                   ![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine/link"]] && ![files fileExistsAtPath:[root stringByAppendingPathComponent:@"Wine/a"]]);
            [files removeItemAtPath:documents error:NULL];
        }
        // An archive with nothing for the profile's runtime folder, and a file that is no archive.
        for (NSData *bad in @[zip(@[runtimeEntries[1]]), pattern(5000, 9)]) {
            documents = fresh();
            server[runtimeURL] = bad;
            assert(![downloadInto(documents, blockFor(bad)) run:&error] && ![files fileExistsAtPath:[documents stringByAppendingPathComponent:@"Steam/prefix"]]);
            [files removeItemAtPath:documents error:NULL];
        }
        server[runtimeURL] = runtimeZip;

        // Valve's side, with the runtime in place.
        NSString *listAddress = [valve stringByAppendingString:@"steam_client_win64"];
        NSString *(^prepared)(void) = ^NSString *{
            NSString *folder = fresh();
            assert([files createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Steam"] withIntermediateDirectories:YES attributes:nil error:NULL]);
            assert([sha256(runtimeZip) writeToFile:[folder stringByAppendingPathComponent:@"Steam/.tolkara-runtime"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
            return folder;
        };
        // A package that is not what the list says is not kept, and Steam is not installed.
        documents = prepared(); steamFolder = [documents stringByAppendingPathComponent:working];
        server[[valve stringByAppendingString:stringsName]] = pattern(strings.length, 77);
        error = nil;
        assert(![downloadInto(documents, block) run:&error] && [error.localizedDescription containsString:stringsName]);
        assert(![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:[@"package/" stringByAppendingString:stringsName]]] &&
               ![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:@"steam.exe"]]);
        assert((![files fileExistsAtPath:[documents stringByAppendingPathComponent:[NSString stringWithFormat:@"Steam/.download/%@.part", stringsName]]]));
        server[[valve stringByAppendingString:stringsName]] = strings;
        // The same for the installer.
        server[[valve stringByAppendingString:installerName]] = pattern(installer.length, 99);
        assert(![downloadInto(documents, block) run:&error] && ![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:@"steam.exe"]]);
        server[[valve stringByAppendingString:installerName]] = installer;
        [files removeItemAtPath:documents error:NULL];

        // Lists that name a file outside the server's folder, or are not understood.
        NSArray<NSString *> *lists = @[[list stringByReplacingOccurrencesOfString:stringsName withString:@"../../../escaped.zip"],
            [list stringByReplacingOccurrencesOfString:stringsName withString:@"folder/strings.zip"],
            [list stringByReplacingOccurrencesOfString:stringsName withString:@".."],
            [list stringByReplacingOccurrencesOfString:binsName withString:@"..\\\\bins.zip.vz.aa_70000"],
            [list stringByReplacingOccurrencesOfString:binsName withString:@"bins_win64.zip.vz.4a749655f0aa"],
            [list stringByReplacingOccurrencesOfString:binsName withString:@"bins_win64.zip.vz.4a749655f0aa_0"],
            [list stringByReplacingOccurrencesOfString:sha256(strings) withString:@"abcd"],
            [list stringByReplacingOccurrencesOfString:@"\"99\"" withString:@"\"-1\""],
            [list stringByReplacingOccurrencesOfString:@"\"99\"" withString:@"\"99999999999\""],
            [list stringByReplacingOccurrencesOfString:@"\t\"steam_win64\"" withString:@"\t\"steam_linux\""],
            [list stringByReplacingOccurrencesOfString:@"\t\t\"zipvz\"\t\t\"steam_win64.zip.vz.6b35_77\"" withString:@"\t\t\"file\"\t\t\"again.zip\""],
            [list stringByReplacingOccurrencesOfString:@"\"ostype\"" withString:@"ostype"],
            [list substringToIndex:list.length / 2], [list stringByReplacingOccurrencesOfString:@"{" withString:@"{{{{{{"], @"", @"\"win64\"", @"\"win64\" \"x\"",
            @"<html>not found</html>", @"\"win64\"\n{\n}\n"];
        for (NSString *changed in lists) {
            documents = prepared();
            server[listAddress] = text(changed);
            [asked removeAllObjects];
            error = nil;
            assert(![downloadInto(documents, block) run:&error] && [error.localizedDescription containsString:@"not understood"]);
            // Nothing but the list was asked for.
            assert(asked.count == 1 && ![files fileExistsAtPath:[documents stringByAppendingPathComponent:@"escaped.zip"]]);
            [files removeItemAtPath:documents error:NULL];
        }
        // More packages than any client has.
        NSMutableString *many = [@"\"win64\"\n{\n" mutableCopy];
        for (int i = 0; i < 65; i++) [many appendFormat:@"\"p%d\" { \"file\" \"p%d.zip\" \"size\" \"5\" \"sha2\" \"%@\" }\n", i, i, sha256(bins)];
        [many appendString:@"}\n"];
        documents = prepared();
        server[listAddress] = text(many);
        assert(![downloadInto(documents, block) run:&error] && [error.localizedDescription containsString:@"not understood"]);
        server[listAddress] = text(list);

        // An installer that reaches outside the Steam folder, or holds no steam.exe, installs nothing.
        for (NSArray *entries in @[@[@[@"steam.exe", program, @YES, @0], @[@"..\\..\\escaped.txt", text(@"x"), @NO, @0]],
                                   @[@[@"steam.exe", program, @YES, @0], @[@"/escaped.txt", text(@"x"), @NO, @0]],
                                   @[@[@"Steam.dll", library, @YES, @0]]]) {
            NSData *bad = zip(entries);
            server[[valve stringByAppendingString:installerName]] = bad;
            server[listAddress] = text([[list stringByReplacingOccurrencesOfString:sha256(installer) withString:sha256(bad)]
                stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"\"%lu\"", (unsigned long)installer.length]
                                          withString:[NSString stringWithFormat:@"\"%lu\"", (unsigned long)bad.length]]);
            error = nil;
            assert(![downloadInto(documents, block) run:&error] && [error.localizedDescription containsString:@"installer"]);
            steamFolder = [documents stringByAppendingPathComponent:working];
            assert(![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:@"steam.exe"]] && ![files fileExistsAtPath:[steamFolder stringByAppendingPathComponent:@"Steam.dll"]]);
            assert(![files fileExistsAtPath:[steamFolder.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"escaped.txt"]]);
        }
        [files removeItemAtPath:documents error:NULL];
        puts("steam download: the block's rules; a runtime archive and Steam's packages from made-up servers with a failed chunk, a stop and their resume; "
             "modes, copies, the marker and the package folder; a newer runtime over an existing prefix; Steam alone; wrong checksums and sizes; "
             "archives and lists that reach outside their folder or are not understood: PASS");
    }
    return 0;
}
