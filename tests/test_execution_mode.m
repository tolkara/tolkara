// Execution-mode naming, persistence, launch resolution and --signed-image
// validation. Built with and without TOLKARA_INTEGRATED_AUTH.
#import "ExecutionMode.h"
#include <assert.h>
#include <stdio.h>
#ifndef TOLKARA_INTEGRATED_AUTH
#define TOLKARA_INTEGRATED_AUTH 0
#endif

static NSUInteger Sentences(NSString *text) {
    NSRegularExpression *end=[NSRegularExpression regularExpressionWithPattern:@"[.!?](\\s|$)" options:0 error:NULL];
    return [end numberOfMatchesInString:text options:0 range:NSMakeRange(0,text.length)];
}
static TKExecutionMode Resolve(NSArray<NSString *> *arguments, NSUserDefaults *defaults, NSString *preselected, NSString **source) {
    return TKExecutionModeResolve([@[@"Tolkara"] arrayByAddingObjectsFromArray:arguments],defaults,preselected,source);
}

int main(void) {
    @autoreleasepool {
        // Identifiers and names.
        const TKExecutionMode modes[]={TKExecutionModeDeveloperService,TKExecutionModeLocalSigning};
        for(size_t i=0;i<2;i++) assert(TKExecutionModeFromIdentifier(TKExecutionModeIdentifier(modes[i]))==modes[i]);
        assert([TKExecutionModeIdentifier(TKExecutionModeDeveloperService) isEqualToString:@"developer-service"]);
        assert([TKExecutionModeIdentifier(TKExecutionModeLocalSigning) isEqualToString:@"local-signing"]);
        assert([TKExecutionModeName(TKExecutionModeDeveloperService) isEqualToString:@"Developer service"]);
        assert([TKExecutionModeName(TKExecutionModeLocalSigning) isEqualToString:@"Local signing"]);
        assert(!TKExecutionModeIdentifier(TKExecutionModeNone) && !TKExecutionModeName(TKExecutionModeNone) && !TKExecutionModeSummary(TKExecutionModeNone));
        assert(!TKExecutionModeIdentifier((TKExecutionMode)7) && !TKExecutionModeName((TKExecutionMode)-1));
        for(NSString *bad in @[@"",@"none",@"Local-Signing",@"local_signing",@" local-signing",@"developer-service "])
            assert(TKExecutionModeFromIdentifier(bad)==TKExecutionModeNone);
        assert(TKExecutionModeFromIdentifier(nil)==TKExecutionModeNone);
        assert(TKExecutionModeFromIdentifier((NSString *)(id)@42)==TKExecutionModeNone);

        // Summaries: exactly two sentences, prerequisites first.
        NSString *developer=TKExecutionModeSummary(TKExecutionModeDeveloperService), *local=TKExecutionModeSummary(TKExecutionModeLocalSigning);
        assert(Sentences(developer)==2 && [developer hasSuffix:@"."] && Sentences(local)==2 && [local hasSuffix:@"."]);
        for(NSString *needed in @[@"Developer Mode",@"tools/enroll.sh",@"VPN-style tunnel",@"developer service",@"never signed or changed"])
            assert([developer containsString:needed]);
        for(NSString *needed in @[@"page container",@"your own developer identity",@"tools/build_signed_container.py",
                                  @"Documents/LocalSigning",@"never changed",@"signed under your identity"])
            assert([local containsString:needed]);
        assert([developer hasPrefix:@"Needs "] && [local hasPrefix:@"Needs "]);

        // Availability: Developer service exists only in TOLKARA_INTEGRATED_AUTH builds.
        NSString *reason=@"stale";
        assert(TKExecutionModeAvailable(TKExecutionModeLocalSigning,&reason) && !reason);
#if TOLKARA_INTEGRATED_AUTH
        assert(TKExecutionModeAvailable(TKExecutionModeDeveloperService,&reason) && !reason);
#else
        assert(!TKExecutionModeAvailable(TKExecutionModeDeveloperService,&reason));
        assert([reason isEqualToString:@"Not included in this build (TolkaraDiagnostics)."]);
#endif
        assert(!TKExecutionModeAvailable(TKExecutionModeNone,&reason) && reason.length);
        assert(TKExecutionModeAvailable(TKExecutionModeLocalSigning,NULL));

        // Persistence in a private defaults suite.
        NSString *suite=@"tolkara.test-execution-mode";   // one fixed private suite, emptied before and after
        NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite]; assert(defaults);
        [defaults removePersistentDomainForName:suite];
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeNone);
        TKExecutionModeSave(defaults,TKExecutionModeLocalSigning);
        assert([[defaults stringForKey:@"TolkaraExecutionMode"] isEqualToString:@"local-signing"]);
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeLocalSigning);
        TKExecutionModeSave(defaults,TKExecutionModeDeveloperService);
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        TKExecutionModeSave(defaults,TKExecutionModeNone);
        assert(![defaults objectForKey:@"TolkaraExecutionMode"] && TKExecutionModeLoad(defaults)==TKExecutionModeNone);
        [defaults setObject:@"bogus" forKey:@"TolkaraExecutionMode"]; assert(TKExecutionModeLoad(defaults)==TKExecutionModeNone);
        [defaults setObject:@1 forKey:@"TolkaraExecutionMode"]; assert(TKExecutionModeLoad(defaults)==TKExecutionModeNone);
        [defaults removeObjectForKey:@"TolkaraExecutionMode"];
        assert([TKExecutionModeDefaultsKey isEqualToString:@"TolkaraExecutionMode"]);
        assert([TKExecutionModePreselectionKey isEqualToString:@"TolkaraPreselectedExecutionMode"]);

        // Resolution: nothing anywhere -> None, the app asks.
        NSString *source=nil;
        assert(Resolve(@[],defaults,nil,&source)==TKExecutionModeNone && [source isEqualToString:@"none"]);
        assert(Resolve(@[],defaults,@"",&source)==TKExecutionModeNone && [source isEqualToString:@"none"]);
        assert(!TKExecutionModeSourceIsInvalid(source) && ![defaults objectForKey:@"TolkaraExecutionMode"]);
        assert(Resolve(@[],defaults,nil,NULL)==TKExecutionModeNone);
        assert(TKExecutionModeResolve(@[],nil,nil,&source)==TKExecutionModeNone);
        // The argument wins and is never saved, even over a valid preselection.
        assert(Resolve(@[@"--execution-mode=local-signing"],defaults,@"developer-service",&source)==TKExecutionModeLocalSigning);
        assert([source isEqualToString:@"argument"] && ![defaults objectForKey:@"TolkaraExecutionMode"]);
        // A valid preselection is saved when nothing is saved yet.
        assert(Resolve(@[],defaults,@"developer-service",&source)==TKExecutionModeDeveloperService);
        assert([source isEqualToString:@"TOLKARA_MODE"] && TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        // Saved beats a different preselection, which is not saved over it.
        assert(Resolve(@[],defaults,@"local-signing",&source)==TKExecutionModeDeveloperService && [source isEqualToString:@"saved"]);
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        // Saved beats an invalid preselection (not consulted).
        assert(Resolve(@[],defaults,@"bogus",&source)==TKExecutionModeDeveloperService && [source isEqualToString:@"saved"]);
        // Argument beats saved and leaves it untouched.
        assert(Resolve(@[@"--native-initializer",@"--execution-mode=local-signing"],defaults,nil,&source)==TKExecutionModeLocalSigning);
        assert([source isEqualToString:@"argument"] && TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        // Invalid arguments are reported, not ignored: no fallback to saved or preselected.
        for(NSArray *arguments in @[@[@"--execution-mode=bogus"],@[@"--execution-mode="],@[@"--execution-mode=Local signing"],
                                    @[@"--execution-mode=local-signing",@"--execution-mode=local-signing"],
                                    @[@"--execution-mode=local-signing",@"--execution-mode=developer-service"]]) {
            source=nil;
            assert(Resolve(arguments,defaults,@"local-signing",&source)==TKExecutionModeNone);
            assert([source hasPrefix:@"invalid --execution-mode"] && TKExecutionModeSourceIsInvalid(source));
            assert(![source containsString:@"/"] && TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        }
        assert(Resolve(@[@"--execution-mode=a",@"--execution-mode=b"],defaults,nil,&source)==TKExecutionModeNone && [source containsString:@"2 times"]);
        // "--execution-mode" without '=' is not the override.
        assert(Resolve(@[@"--execution-mode",@"local-signing"],defaults,nil,&source)==TKExecutionModeDeveloperService && [source isEqualToString:@"saved"]);
        // Invalid preselection with nothing saved: reported, nothing saved, the app asks.
        TKExecutionModeSave(defaults,TKExecutionModeNone);
        assert(Resolve(@[],defaults,@"Developer service",&source)==TKExecutionModeNone);
        assert([source hasPrefix:@"invalid TOLKARA_MODE"] && TKExecutionModeSourceIsInvalid(source) && ![defaults objectForKey:@"TolkaraExecutionMode"]);
        assert(Resolve(@[],defaults,(NSString *)(id)@3,&source)==TKExecutionModeNone && [source isEqualToString:@"none"]);
        // A corrupt saved value counts as nothing saved; a valid preselection replaces it.
        [defaults setObject:@"bogus" forKey:@"TolkaraExecutionMode"];
        assert(Resolve(@[],defaults,@"local-signing",&source)==TKExecutionModeLocalSigning && [source isEqualToString:@"TOLKARA_MODE"]);
        assert([[defaults stringForKey:@"TolkaraExecutionMode"] isEqualToString:@"local-signing"]);
        assert(Resolve(@[],defaults,nil,&source)==TKExecutionModeLocalSigning && [source isEqualToString:@"saved"]);
        [defaults removePersistentDomainForName:suite];

        // Explicit setup persists a choice for a later plain launch; diagnostic
        // per-launch overrides above still leave the saved choice untouched.
        TKExecutionModeSave(defaults,TKExecutionModeDeveloperService);
        assert(TKExecutionModeApplySaveArgument(@[@"--execution-mode=local-signing"],defaults,&reason) && !reason);
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
        assert(TKExecutionModeApplySaveArgument(@[@"--save-execution-mode",@"--execution-mode=local-signing"],defaults,&reason) && !reason);
        NSUserDefaults *reloaded=[[NSUserDefaults alloc] initWithSuiteName:suite];
        assert(Resolve(@[],reloaded,nil,&source)==TKExecutionModeLocalSigning && [source isEqualToString:@"saved"]);
        for(NSArray *bad in @[@[@"--save-execution-mode"],@[@"--save-execution-mode",@"--execution-mode=bogus"],
                @[@"--save-execution-mode",@"--execution-mode=local-signing",@"--execution-mode=developer-service"],
                @[@"--save-execution-mode",@"--save-execution-mode",@"--execution-mode=local-signing"]]) {
            assert(!TKExecutionModeApplySaveArgument(bad,defaults,&reason));
            assert(TKExecutionModeSourceIsInvalid(reason) && TKExecutionModeLoad(defaults)==TKExecutionModeLocalSigning);
        }
#if TOLKARA_INTEGRATED_AUTH
        assert(TKExecutionModeApplySaveArgument(@[@"--save-execution-mode",@"--execution-mode=developer-service"],defaults,&reason));
        assert(Resolve(@[],reloaded,nil,&source)==TKExecutionModeDeveloperService && [source isEqualToString:@"saved"]);
        assert(!TKExecutionModeApplySaveArgument(@[@"--save-execution-mode",@"--execution-mode=external-jit"],defaults,&reason));
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeDeveloperService);
#else
        assert(!TKExecutionModeApplySaveArgument(@[@"--save-execution-mode",@"--execution-mode=developer-service"],defaults,&reason));
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeLocalSigning);
#endif
        [defaults removePersistentDomainForName:suite];

        // Local signing container.
        NSString *home=@"/var/mobile/Containers/Data/Application/TEST-HOME";
        assert([TKLocalSigningContainerDisplayPath() isEqualToString:@"Documents/LocalSigning/page-container.dylib"]);
        assert([TKLocalSigningContainerPath(home) isEqualToString:[home stringByAppendingString:@"/Documents/LocalSigning/page-container.dylib"]]);
        assert([TKLocalSigningContainerPath([home stringByAppendingString:@"/"]) isEqualToString:TKLocalSigningContainerPath(home)]);
        assert([TKHomeDisplayPath(TKLocalSigningContainerPath(home),home) isEqualToString:@"~/Documents/LocalSigning/page-container.dylib"]);
        // Per-application containers are named after the executable's SHA-256.
        NSString *sha=[@"" stringByPaddingToLength:64 withString:@"0123456789abcdef" startingAtIndex:0];
        NSString *ownDisplay=[@"Documents/LocalSigning/" stringByAppendingFormat:@"%@.dylib",sha];
        NSString *ownPath=[home stringByAppendingPathComponent:ownDisplay];
        assert([TKLocalSigningAppContainerDisplayPath(sha) isEqualToString:ownDisplay]);
        assert([TKLocalSigningAppContainerPath(home,sha) isEqualToString:ownPath]);
        for (NSString *bad in @[@"",@"../x",[sha uppercaseString],[sha substringToIndex:63],[sha stringByAppendingString:@"0"],
                                [[sha substringToIndex:63] stringByAppendingString:@"/"]]) {
            assert(!TKLocalSigningAppContainerDisplayPath(bad) && !TKLocalSigningAppContainerPath(home,bad));
        }
        assert(!TKLocalSigningAppContainerDisplayPath((NSString *)(id)@42));

        // --signed-image validation.
        NSString *(^signedImage)(NSArray *)=^NSString *(NSArray *arguments) {
            return TKSignedImagePath([@[@"Tolkara",@"--native-startup"] arrayByAddingObjectsFromArray:arguments],home,NULL);
        };
        reason=@"stale";
        assert(!TKSignedImagePath(@[@"Tolkara"],home,&reason) && !reason);                  // none
        assert(!TKSignedImagePath(@[@"Tolkara",@"--signed-image"],home,&reason) && !reason); // not the option
        NSString *expected=[home stringByAppendingString:@"/Documents/LocalSigning/page-container.dylib"];
        assert([TKSignedImagePath(@[@"--signed-image=Documents/LocalSigning/page-container.dylib"],home,&reason) isEqualToString:expected] && !reason);
        assert([signedImage(@[@"--signed-image=./Documents//LocalSigning/page-container.dylib/"]) isEqualToString:expected]);
        assert([signedImage(@[[@"--signed-image=" stringByAppendingString:expected]]) isEqualToString:expected]); // absolute inside home
        assert([signedImage(@[[@"--signed-image=" stringByAppendingString:home]]) isEqualToString:home]);         // the home itself, as before
        assert([TKSignedImagePath(@[@"--signed-image=Documents/x.dylib"],[home stringByAppendingString:@"/"],NULL)
                isEqualToString:[home stringByAppendingString:@"/Documents/x.dylib"]]);
        struct { NSArray *arguments; NSString *says; } rejected[]={
            {@[@"--signed-image=a.dylib",@"--signed-image=a.dylib"],@"2 times"},                 // two
            {@[@"--signed-image=a.dylib",@"--signed-image="],@"2 times"},
            {@[@"--signed-image="],@"empty"},                                                    // empty
            {@[@"--signed-image=../outside.dylib"],@"'..'"},                                      // '..'
            {@[@"--signed-image=Documents/../../outside.dylib"],@"'..'"},
            {@[@"--signed-image=Documents/.."],@"'..'"},
            {@[[NSString stringWithFormat:@"--signed-image=%@/Documents/../x.dylib",home]],@"'..'"},
            {@[@"--signed-image=/usr/lib/libobjc.dylib"],@"inside the app home"},                 // absolute outside home
            {@[[NSString stringWithFormat:@"--signed-image=%@-OTHER/x.dylib",home]],@"inside the app home"},
            {@[@"--signed-image=/"],@"inside the app home"},
        };
        for(size_t i=0;i<sizeof rejected/sizeof *rejected;i++) {
            reason=nil;
            assert(!TKSignedImagePath(rejected[i].arguments,home,&reason));
            assert([reason containsString:rejected[i].says] && ![reason containsString:home]);
            assert(!TKSignedImagePath(rejected[i].arguments,home,NULL));
        }
        // Display form: never an absolute path.
        assert([TKHomeDisplayPath(expected,home) isEqualToString:@"~/Documents/LocalSigning/page-container.dylib"]);
        assert([TKHomeDisplayPath(home,home) isEqualToString:@"~"]);
        assert([TKHomeDisplayPath([home stringByAppendingString:@"/"],home) isEqualToString:@"~"]);
        assert([TKHomeDisplayPath(@"/usr/lib/libobjc.dylib",home) isEqualToString:@"libobjc.dylib"]);
        assert([TKHomeDisplayPath([home stringByAppendingString:@"-OTHER/x.dylib"],home) isEqualToString:@"x.dylib"]);
        // Container lookup: the app's own, else the single-application one, else none.
        NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *folder=[root stringByAppendingPathComponent:@"Documents/LocalSigning"];
        assert([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert(!TKLocalSigningFindContainer(root,sha) && !TKLocalSigningFindContainer(root,nil));
        assert([NSData.data writeToFile:TKLocalSigningContainerPath(root) atomically:YES]);
        assert([TKLocalSigningFindContainer(root,sha) isEqualToString:TKLocalSigningContainerPath(root)]);
        assert([TKLocalSigningFindContainer(root,@"not-a-hash") isEqualToString:TKLocalSigningContainerPath(root)]);
        assert([NSData.data writeToFile:TKLocalSigningAppContainerPath(root,sha) atomically:YES]);
        assert([TKLocalSigningFindContainer(root,sha) isEqualToString:TKLocalSigningAppContainerPath(root,sha)]);
        assert([NSFileManager.defaultManager removeItemAtPath:TKLocalSigningContainerPath(root) error:NULL]);
        NSString *other=[@"" stringByPaddingToLength:64 withString:@"f" startingAtIndex:0];
        assert(!TKLocalSigningFindContainer(root,other));
        assert([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
        printf("PASS: execution mode names, summaries, availability (%s), saved choice, resolution precedence, container paths and lookup, --signed-image validation\n",
            TOLKARA_INTEGRATED_AUTH?"Tolkara":"TolkaraDiagnostics");

        // External JIT: only without the tunnel, preselected by the unsigned build.
        assert(TKExecutionModeFromIdentifier(@"external-jit")==TKExecutionModeExternalJIT);
        assert([TKExecutionModeIdentifier(TKExecutionModeExternalJIT) isEqualToString:@"external-jit"]);
        assert([TKExecutionModeName(TKExecutionModeExternalJIT) isEqualToString:@"External JIT"]);
        for(NSString *bad in @[@"External-JIT",@"external_jit",@" external-jit",@"external-jit "])
            assert(TKExecutionModeFromIdentifier(bad)==TKExecutionModeNone);
        NSString *external=TKExecutionModeSummary(TKExecutionModeExternalJIT);
        assert(Sentences(external)==2 && [external hasPrefix:@"Needs "] && [external hasSuffix:@"."]);
        for(NSString *needed in @[@"SideStore",@"StikDebug",@"never signed or changed"]) assert([external containsString:needed]);
        reason=@"stale";
#if TOLKARA_INTEGRATED_AUTH
        assert(!TKExecutionModeAvailable(TKExecutionModeExternalJIT,&reason) && [reason isEqualToString:@"Not included in this build (Tolkara)."]);
#else
        assert(TKExecutionModeAvailable(TKExecutionModeExternalJIT,&reason) && !reason);
#endif
        [defaults removePersistentDomainForName:suite];
        assert(Resolve(@[],defaults,@"external-jit",&source)==TKExecutionModeExternalJIT && [source isEqualToString:@"TOLKARA_MODE"]);
        assert([[defaults stringForKey:@"TolkaraExecutionMode"] isEqualToString:@"external-jit"]);
        assert(Resolve(@[],defaults,nil,&source)==TKExecutionModeExternalJIT && [source isEqualToString:@"saved"]);
        assert(Resolve(@[@"--execution-mode=local-signing"],defaults,nil,&source)==TKExecutionModeLocalSigning);
        assert(TKExecutionModeLoad(defaults)==TKExecutionModeExternalJIT);
        [defaults removePersistentDomainForName:suite];
        printf("PASS: External JIT name, summary, availability (%s), preselection and saved choice\n",
            TOLKARA_INTEGRATED_AUTH?"Tolkara":"TolkaraDiagnostics");
    }
    return 0;
}
