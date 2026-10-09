#import "AppLibrary.h"
#import "GuestModule.h"
#include <assert.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static void write_text(NSString *text, NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    assert([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
}
static void copy_file(NSString *from, NSString *to) {
    [NSFileManager.defaultManager createDirectoryAtPath:to.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    assert([NSFileManager.defaultManager copyItemAtPath:from toPath:to error:NULL]);
}
static TKAppLibrary *open_library(NSString *documents, NSString *storage, NSArray *profiles) {
    return [[TKAppLibrary alloc] initWithDocuments:documents storage:storage profiles:profiles];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc==2);
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *fixture=@(argv[1]);
        NSData *original=[NSData dataWithContentsOfFile:fixture]; assert(original.length);
        // TMPDIR when set, so the suite can also run on a case-sensitive volume.
        const char *temporary=getenv("TMPDIR");
        NSString *tmp=[(temporary && *temporary ? @(temporary) : NSTemporaryDirectory()) stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *documents=[tmp stringByAppendingPathComponent:@"Documents"], *storage=[tmp stringByAppendingPathComponent:@"Support"];
        NSString *profiles=[tmp stringByAppendingPathComponent:@"Profiles"];
        assert([fm createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSError *error=nil;

        // Profiles: data only, paths inside Documents, unique identifiers.
        write_text(@"{\"id\":\"p\",\"name\":\"Profiled\",\"workingDirectory\":\"P/_retail_\",\"executable\":\"P.app/Contents/MacOS/P\"}",[profiles stringByAppendingPathComponent:@"a.json"]);
        write_text(@"{\"id\":\"p\",\"name\":\"Duplicate\",\"workingDirectory\":\"Q\",\"executable\":\"Q\"}",[profiles stringByAppendingPathComponent:@"b.json"]);
        write_text(@"{\"id\":\"x\",\"name\":\"Escape\",\"workingDirectory\":\"../x\",\"executable\":\"X\"}",[profiles stringByAppendingPathComponent:@"c.json"]);
        write_text(@"{\"id\":\"y\",\"name\":\"Absolute\",\"workingDirectory\":\"Y\",\"executable\":\"/bin/sh\"}",[profiles stringByAppendingPathComponent:@"d.json"]);
        write_text(@"[]",[profiles stringByAppendingPathComponent:@"e.json"]);
        // A compatibility runtime elsewhere in Documents with a command line (data only).
        write_text(@"{\"id\":\"w\",\"name\":\"Layered\",\"workingDirectory\":\"W/game\",\"runtime\":\"W/Runtime\",\"executable\":\"bin/run\","
            "\"arguments\":[\"game.exe\",\"--windowed\"],\"environment\":{\"PREFIX\":\"${Documents}/W/prefix\",\"_X1\":\"\"},"
            "\"libraries\":[\"lib/core.so\"],\"codePool\":64}",[profiles stringByAppendingPathComponent:@"f.json"]);
        write_text(@"{\"id\":\"g\",\"name\":\"Escape\",\"workingDirectory\":\"G\",\"runtime\":\"../R\",\"executable\":\"run\"}",[profiles stringByAppendingPathComponent:@"g.json"]);
        write_text(@"{\"id\":\"h\",\"name\":\"Text\",\"workingDirectory\":\"H\",\"executable\":\"run\",\"arguments\":\"game.exe\"}",[profiles stringByAppendingPathComponent:@"h.json"]);
        write_text(@"{\"id\":\"i\",\"name\":\"Name\",\"workingDirectory\":\"I\",\"executable\":\"run\",\"environment\":{\"1X\":\"a\"}}",[profiles stringByAppendingPathComponent:@"i.json"]);
        write_text(@"{\"id\":\"j\",\"name\":\"Value\",\"workingDirectory\":\"J\",\"executable\":\"run\",\"environment\":{\"X\":1}}",[profiles stringByAppendingPathComponent:@"j.json"]);
        // Libraries only with a runtime, and only inside it.
        write_text(@"{\"id\":\"k\",\"name\":\"Bare\",\"workingDirectory\":\"K\",\"executable\":\"run\",\"libraries\":[\"core.so\"]}",[profiles stringByAppendingPathComponent:@"k.json"]);
        write_text(@"{\"id\":\"l\",\"name\":\"Out\",\"workingDirectory\":\"L\",\"runtime\":\"R\",\"executable\":\"run\",\"libraries\":[\"../core.so\"]}",[profiles stringByAppendingPathComponent:@"l.json"]);
        // A code pool only with a runtime, and in range.
        write_text(@"{\"id\":\"m\",\"name\":\"Pool\",\"workingDirectory\":\"M\",\"executable\":\"run\",\"codePool\":64}",[profiles stringByAppendingPathComponent:@"m.json"]);
        write_text(@"{\"id\":\"n\",\"name\":\"Huge\",\"workingDirectory\":\"N\",\"runtime\":\"R\",\"executable\":\"run\",\"codePool\":2048}",[profiles stringByAppendingPathComponent:@"n.json"]);
        write_text(@"{\"id\":\"o\",\"name\":\"Flag\",\"workingDirectory\":\"O\",\"runtime\":\"R\",\"executable\":\"run\",\"codePool\":true}",[profiles stringByAppendingPathComponent:@"o.json"]);
        NSArray *known=[TKAppLibrary profilesInDirectory:profiles];
        assert(known.count==2 && [known[0][@"name"] isEqual:@"Profiled"] && [known[1][@"name"] isEqual:@"Layered"]);
        assert([[TKAppLibrary executableOfProfile:known[0]] isEqual:@"P/_retail_/P.app/Contents/MacOS/P"]);
        assert([[TKAppLibrary executableOfProfile:known[1]] isEqual:@"W/Runtime/bin/run"]);

        TKAppLibrary *library=open_library(documents,storage,known);
        assert(!library.apps.count && !library.defaultApp && !library.loadWarning);

        // An application bundle inside Documents runs in place, from the folder
        // that contains the bundle, under the bundle's own name.
        NSString *bundle=[documents stringByAppendingPathComponent:@"Games/Example/Example.app"];
        NSString *executable=[bundle stringByAppendingPathComponent:@"Contents/MacOS/Example"];
        copy_file(fixture,executable);
        assert([@{@"CFBundleName":@"Example Game"} writeToFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        TKApp *inPlace=[library importExecutable:executable copy:NO error:&error];
        assert(inPlace && inPlace.source==TKAppSourceDocuments && [inPlace.name isEqual:@"Example Game"]);
        assert([inPlace.executable isEqual:@"Games/Example/Example.app/Contents/MacOS/Example"]);
        assert([inPlace.workingDirectory isEqual:@"Games/Example"] && inPlace.sha256.length==64 && !inPlace.profile);
        NSString *path=[library executablePathForApp:inPlace error:&error];
        assert(path && [[NSData dataWithContentsOfFile:path] isEqual:original]);
        assert([[library workingDirectoryForApp:inPlace error:&error] isEqual:[documents stringByAppendingPathComponent:@"Games/Example"]]);
        assert([[library currentSHA256OfApp:inPlace error:&error] isEqual:inPlace.sha256]);
        assert([[library importExecutable:executable copy:NO error:&error].identifier isEqual:inPlace.identifier]);
        assert(library.apps.count==1 && [library.defaultApp.identifier isEqual:inPlace.identifier]);
        // Picking the bundle itself selects the executable its Info.plist names.
        assert(![library importExecutable:bundle copy:NO error:&error]);
        NSDictionary *info=@{@"CFBundleName":@"Example Game",@"CFBundleExecutable":@"Example"};
        assert([info writeToFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        assert([[library importExecutable:bundle copy:NO error:&error].identifier isEqual:inPlace.identifier]);
        NSString *badBundle=[tmp stringByAppendingPathComponent:@"Bad.app"];
        assert([fm createDirectoryAtPath:[badBundle stringByAppendingPathComponent:@"Contents"] withIntermediateDirectories:YES attributes:nil error:NULL]);
        info=@{@"CFBundleExecutable":@"../../x"};
        assert([info writeToFile:[badBundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        assert(![library importExecutable:[tmp stringByAppendingPathComponent:@"Bad.app"] copy:NO error:&error]);
        assert(library.apps.count==1);

        // An executable outside Documents is copied; its source is not needed again.
        NSString *outside=[tmp stringByAppendingPathComponent:@"Elsewhere/Tool"];
        copy_file(fixture,outside);
        TKApp *copied=[library importExecutable:outside copy:NO error:&error];
        assert(copied && copied.source==TKAppSourceCopy && [copied.name isEqual:@"Tool"]);
        assert([copied.executable hasPrefix:@"GuestModules/"] && [copied.workingDirectory isEqual:[@"GuestModules/" stringByAppendingString:copied.sha256]]);
        assert([fm removeItemAtPath:outside error:NULL]);
        path=[library executablePathForApp:copied error:&error];
        assert(path && [[NSData dataWithContentsOfFile:path] isEqual:original]);
        assert([library workingDirectoryForApp:copied error:&error]);
        assert(library.apps.count==2 && [library.defaultApp.identifier isEqual:inPlace.identifier]);

        // Unsupported files are rejected and leave the library unchanged.
        NSString *bad=[documents stringByAppendingPathComponent:@"Notes.txt"];
        write_text(@"not a Mach-O",bad);
        assert(![library importExecutable:bad copy:NO error:&error] && error);
        assert(![library importExecutable:[tmp stringByAppendingPathComponent:@"missing"] copy:NO error:&error]);
        assert(library.apps.count==2);

        // An executable updated in place: the recorded hash follows it.
        NSMutableData *updated=[original mutableCopy]; [updated appendBytes:"\0" length:1];
        assert([updated writeToFile:executable atomically:YES]);
        NSString *newHash=[library currentSHA256OfApp:inPlace error:&error];
        assert(newHash.length==64 && ![newHash isEqual:inPlace.sha256]);
        assert([[library appWithIdentifier:inPlace.identifier].sha256 isEqual:newHash]);
        assert([original writeToFile:executable atomically:YES]);
        assert([[library currentSHA256OfApp:inPlace error:&error] isEqual:inPlace.sha256]);
        // Rename, launch order and persistence.
        assert(![library renameApp:copied to:@"  " error:&error]);
        assert([library renameApp:copied to:@" Tool Classic " error:&error]);
        assert([library recordLaunchOfApp:copied error:&error]);
        library=open_library(documents,storage,known);
        assert(library.apps.count==2 && !library.loadWarning);
        assert([library.apps[0].identifier isEqual:copied.identifier] && [library.apps[0].name isEqual:@"Tool Classic"]);
        assert([library.defaultApp.identifier isEqual:copied.identifier]);
        assert([[library appWithIdentifier:inPlace.identifier].name isEqual:@"Example Game"]);

        // Profile apps whose files are present are added once, under the
        // profile's name and working directory; a removed one stays removed.
        assert(![library discover].count);
        NSString *profiled=[documents stringByAppendingPathComponent:@"P/_retail_/P.app/Contents/MacOS/P"];
        copy_file(fixture,profiled);
        NSArray<TKApp *> *found=[library discover];
        assert(found.count==1 && [found[0].name isEqual:@"Profiled"] && [found[0].profile isEqual:@"p"]);
        assert([found[0].workingDirectory isEqual:@"P/_retail_"] && found[0].sha256.length==64);
        assert(![library discover].count && library.apps.count==3);
        assert([library removeApp:found[0] error:&error] && library.apps.count==2);
        assert(![library discover].count);
        assert([fm fileExistsAtPath:profiled]); // files in Documents are never removed
        TKApp *again=[library importExecutable:profiled copy:NO error:&error];
        assert(again && [again.profile isEqual:@"p"] && [again.name isEqual:@"Profiled"]);
        assert(!again.arguments.count && !again.environment.count && !again.runtime && !again.libraries.count && !again.codePool);
        assert([library removeApp:again error:&error]);
        // A runtime profile: the executable is the runtime's, the working
        // directory the application's, and the command line comes along.
        NSString *layered=[documents stringByAppendingPathComponent:@"W/Runtime/bin/run"];
        copy_file(fixture,layered);
        assert(![library discover].count); // the working directory must exist too
        assert([fm createDirectoryAtPath:[documents stringByAppendingPathComponent:@"W/game"] withIntermediateDirectories:YES attributes:nil error:NULL]);
        found=[library discover];
        assert(found.count==1 && [found[0].profile isEqual:@"w"] && [found[0].executable isEqual:@"W/Runtime/bin/run"]);
        assert([found[0].workingDirectory isEqual:@"W/game"] && [found[0].arguments isEqual:(@[@"game.exe",@"--windowed"])]);
        assert([found[0].environment isEqual:(@{@"PREFIX":@"${Documents}/W/prefix",@"_X1":@""})]);
        assert([found[0].runtime isEqual:@"W/Runtime"] && [found[0].libraries isEqual:(@[@"lib/core.so"])] && found[0].codePool==64);
        assert([[library workingDirectoryForApp:found[0] error:&error] isEqual:[documents stringByAppendingPathComponent:@"W/game"]]);
        assert([[library appWithIdentifier:found[0].identifier].arguments count]==2);
        // A newer build's profile names another executable: the entry follows it.
        NSString *layeredID=found[0].identifier;
        assert([library renameApp:found[0] to:@"Renamed" error:&error]);
        NSMutableDictionary *moved=[known[1] mutableCopy];
        moved[@"executable"]=@"lib/run";
        copy_file(fixture,[documents stringByAppendingPathComponent:@"W/Runtime/lib/run"]);
        TKAppLibrary *newer=open_library(documents,storage,@[known[0],moved]);
        found=[newer discover];
        assert(found.count==1 && [found[0].identifier isEqual:layeredID] && [found[0].executable isEqual:@"W/Runtime/lib/run"]);
        assert([found[0].name isEqual:@"Renamed"] && newer.apps.count==3 && ![newer discover].count);
        assert([newer removeApp:found[0] error:&error] && ![newer discover].count);
        library=open_library(documents,storage,known);

        // Integrity at launch.
        NSString *copyPath=[library executablePathForApp:copied error:&error];
        assert([@"corrupted" writeToFile:copyPath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
        assert(![library executablePathForApp:copied error:&error]);
        assert([library importExecutable:fixture copy:YES error:&error]); // repairs the copy
        assert([library executablePathForApp:copied error:&error] && library.apps.count==2);
        assert([fm removeItemAtPath:executable error:NULL]);
        assert(![library executablePathForApp:inPlace error:&error] && [error.localizedDescription containsString:@"missing"]);
        assert(!symlink(fixture.fileSystemRepresentation,executable.fileSystemRepresentation));
        assert(![library executablePathForApp:inPlace error:&error]); // no link leading outside
        // A link leading outside Documents is never run in place (or copied).
        assert(![library importExecutable:executable copy:NO error:&error]);
        assert(library.apps.count==2);

        // Removing a copy deletes Tolkara's own module when nothing else uses it.
        NSString *moduleDirectory=[documents stringByAppendingPathComponent:copied.workingDirectory];
        for (TKApp *app in library.apps) if (app.source==TKAppSourceCopy) assert([library removeApp:app error:&error]);
        assert(![fm fileExistsAtPath:moduleDirectory]);
        assert(![library removeApp:copied error:&error]);

        // A module imported by the older launcher is added once, then not again.
        NSString *legacyDocuments=[tmp stringByAppendingPathComponent:@"Legacy"], *legacyStorage=[tmp stringByAppendingPathComponent:@"LegacySupport"];
        assert(guest_module_import(fixture,[legacyDocuments stringByAppendingPathComponent:@"GuestModules"],&error));
        TKAppLibrary *legacy=open_library(legacyDocuments,legacyStorage,@[]);
        found=[legacy discover];
        assert(found.count==1 && found[0].source==TKAppSourceCopy && [found[0].name isEqual:fixture.lastPathComponent]);
        assert(![legacy discover].count);
        assert([legacy removeApp:found[0] error:&error]);
        assert(!guest_module_selected([legacyDocuments stringByAppendingPathComponent:@"GuestModules"],NULL));
        assert(![open_library(legacyDocuments,legacyStorage,@[]) discover].count);

        // Hostile or damaged library files.
        NSString *libraryFile=[storage stringByAppendingPathComponent:@"apps.json"];
        write_text(@"{\"format\":1,\"apps\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Escape\",\"source\":\"documents\","
            "\"executable\":\"../../bin/sh\",\"workingDirectory\":\"\",\"added\":1},"
            "{\"id\":\"00000000-0000-0000-0000-000000000002\",\"name\":\"Absolute\",\"source\":\"documents\","
            "\"executable\":\"/bin/sh\",\"workingDirectory\":\"\",\"added\":1},"
            "{\"id\":\"00000000-0000-0000-0000-000000000003\",\"name\":\"Fine\",\"source\":\"documents\","
            "\"executable\":\"Fine\",\"workingDirectory\":\"\",\"added\":1},"
            "{\"id\":\"00000000-0000-0000-0000-000000000003\",\"name\":\"Duplicate\",\"source\":\"documents\","
            "\"executable\":\"Other\",\"workingDirectory\":\"\",\"added\":1}]}",libraryFile);
        library=open_library(documents,storage,known);
        assert(library.apps.count==1 && [library.apps[0].name isEqual:@"Fine"] && !library.loadWarning);
        write_text(@"{not json",libraryFile);
        library=open_library(documents,storage,known);
        assert(!library.apps.count && library.loadWarning && ![fm fileExistsAtPath:libraryFile]);

        // caseAliases, checked as tools/check_profile.py does: a missing alias
        // links to its target, a name in another case, inside the working
        // directory only.
        NSString *aliasProfiles=[tmp stringByAppendingPathComponent:@"AliasProfiles"];
        write_text(@"{\"id\":\"c\",\"name\":\"Cased\",\"workingDirectory\":\"C\",\"executable\":\"C.app/Contents/MacOS/C\","
            "\"caseAliases\":{\"archive/mac\":\"Mac\",\"Data\":\"data\",\"gone/x\":\"X\",\"escape/mac\":\"Mac\",\"absent\":\"ABSENT\"}}",
            [aliasProfiles stringByAppendingPathComponent:@"a.json"]);
        NSArray *hostile=@[@"{\"/abs\":\"ABS\"}",@"{\"../up\":\"UP\"}",@"{\"a/mac\":\"../Mac\"}",@"{\"a/mac\":\"x/Mac\"}",
            @"{\"a/mac\":\"Other\"}",@"{\"a/mac\":\"mac\"}",@"{\"a/mac\":1}",@"{\"a/mac\":null}",@"[]",@"{\"a//mac\":\"Mac\"}",@"{\"\":\"x\"}"];
        for (NSUInteger i=0;i<hostile.count;i++)
            write_text([NSString stringWithFormat:@"{\"id\":\"h%lu\",\"name\":\"H\",\"workingDirectory\":\"H\",\"executable\":\"H\",\"caseAliases\":%@}",
                (unsigned long)i,hostile[i]],[aliasProfiles stringByAppendingPathComponent:[NSString stringWithFormat:@"h%lu.json",(unsigned long)i]]);
        NSArray *aliased=[TKAppLibrary profilesInDirectory:aliasProfiles];
        assert(aliased.count==1 && [aliased[0][@"id"] isEqual:@"c"]);
        NSString *cased=[documents stringByAppendingPathComponent:@"C"], *beyond=[tmp stringByAppendingPathComponent:@"Outside"];
        copy_file(fixture,[cased stringByAppendingPathComponent:@"C.app/Contents/MacOS/C"]);
        for (NSString *folder in @[[cased stringByAppendingPathComponent:@"archive/Mac"],[cased stringByAppendingPathComponent:@"data"],
                                   [beyond stringByAppendingPathComponent:@"Mac"]])
            assert([fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert(!symlink(beyond.fileSystemRepresentation,[cased stringByAppendingPathComponent:@"escape"].fileSystemRepresentation));
        TKAppLibrary *aliasLibrary=open_library(documents,[tmp stringByAppendingPathComponent:@"AliasSupport"],aliased);
        NSArray<TKApp *> *casedApps=[aliasLibrary discover];
        assert(casedApps.count==1 && [casedApps[0].profile isEqual:@"c"]);
        NSDictionary *aliases=[aliasLibrary caseAliasesForApp:casedApps[0]];
        assert(aliases.count==5 && [aliases[@"archive/mac"] isEqual:@"Mac"]);
        // A case-insensitive volume (the Mac's default) already answers both spellings.
        BOOL sensitive=pathconf(cased.fileSystemRepresentation,_PC_CASE_SENSITIVE)==1;
        NSString *made=sensitive?@"linked":@"present";
        NSArray *expected=@[[@"case alias Data -> data: " stringByAppendingString:made],
            @"case alias absent -> ABSENT: the target is missing",
            [@"case alias archive/mac -> Mac: " stringByAppendingString:made],
            @"case alias escape/mac -> Mac: its folder is missing or outside the working directory",
            @"case alias gone/x -> X: its folder is missing or outside the working directory"];
        assert([[aliasLibrary linkCaseAliasesForApp:casedApps[0]] isEqual:expected]);
        struct stat link_info;
        if (sensitive) {
            NSString *link=[cased stringByAppendingPathComponent:@"archive/mac"];
            assert(!lstat(link.fileSystemRepresentation,&link_info) && S_ISLNK(link_info.st_mode));
            assert([[fm destinationOfSymbolicLinkAtPath:link error:NULL] isEqual:@"Mac"]);
            assert([[aliasLibrary linkCaseAliasesForApp:casedApps[0]][2] hasSuffix:@": present"]);
        }
        assert(lstat([beyond stringByAppendingPathComponent:@"mac"].fileSystemRepresentation,&link_info) || !S_ISLNK(link_info.st_mode));
        assert(![fm fileExistsAtPath:[cased stringByAppendingPathComponent:@"gone"]]);
        assert(![aliasLibrary caseAliasesForApp:inPlace].count && ![aliasLibrary linkCaseAliasesForApp:inPlace].count);

        // Removing an application's folder for Tolkara Management: only a folder that holds
        // an application, never Tolkara's own or Documents, and the profile comes back with its files.
        NSString *managed=[tmp stringByAppendingPathComponent:@"Managed"];
        NSString *managedDocuments=[managed stringByAppendingPathComponent:@"Documents"];
        NSArray *managedProfiles=@[@{@"id":@"m",@"name":@"Managed",@"workingDirectory":@"Game/_beta_",@"executable":@"M.app/Contents/MacOS/M"}];
        copy_file(fixture,[managedDocuments stringByAppendingPathComponent:@"Game/_beta_/M.app/Contents/MacOS/M"]);
        write_text(@"data",[managedDocuments stringByAppendingPathComponent:@"Game/Data/d"]);
        write_text(@"mine",[managedDocuments stringByAppendingPathComponent:@"Notes/n.txt"]);
        write_text(@"module",[managedDocuments stringByAppendingPathComponent:@"GuestModules/x"]);
        TKAppLibrary *manager=open_library(managedDocuments,[managed stringByAppendingPathComponent:@"Support"],managedProfiles);
        assert([manager discover].count==1);
        for (NSString *refused in @[@"",@"/",@"..",@"Game/..",@"../Game",@"/Game",@"Game/",@".hidden",@"GuestModules",@"LocalSigning",
                                    @"GuestCompatibility/Nibs",@"Notes",@"Missing"]) {
            error=nil;
            assert(![manager removeApplicationFolder:refused error:&error] && error);
        }
        assert([fm fileExistsAtPath:[managedDocuments stringByAppendingPathComponent:@"Notes/n.txt"]]);
        NSArray<NSString *> *removedNames=[manager removeApplicationFolder:@"Game" error:&error];
        assert([removedNames isEqual:@[@"Managed"]] && !manager.apps.count);
        assert(![fm fileExistsAtPath:[managedDocuments stringByAppendingPathComponent:@"Game"]]);
        assert([fm fileExistsAtPath:[managedDocuments stringByAppendingPathComponent:@"GuestModules/x"]]);
        copy_file(fixture,[managedDocuments stringByAppendingPathComponent:@"Game/_beta_/M.app/Contents/MacOS/M"]);
        assert([manager discover].count==1);

        assert([[NSData dataWithContentsOfFile:fixture] isEqual:original]);
        assert([fm removeItemAtPath:tmp error:&error]);
        puts("PASS: app library import in place and by copy, profiles, legacy module, order, persistence, integrity, hostile entries, case aliases and folder removal");
    }
}
