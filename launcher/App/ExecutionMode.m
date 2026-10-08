#import "ExecutionMode.h"

NSString *const TKExecutionModeDefaultsKey=@"TolkaraExecutionMode";
NSString *const TKExecutionModePreselectionKey=@"TolkaraPreselectedExecutionMode";
NSString *const TKExecutionModeArgumentPrefix=@"--execution-mode=";
NSString *const TKExecutionModeSaveArgument=@"--save-execution-mode";
NSString *const TKExecutionModeSourceArgument=@"argument";
NSString *const TKExecutionModeSourceSaved=@"saved";
NSString *const TKExecutionModeSourcePreselected=@"TOLKARA_MODE";
NSString *const TKExecutionModeSourceNone=@"none";
NSString *const TKExecutionModeSourceInvalidArgument=@"invalid --execution-mode";
NSString *const TKExecutionModeSourceInvalidPreselection=@"invalid TOLKARA_MODE";
static NSString *const Expected=@"expected developer-service, local-signing or external-jit";
static NSString *const SignedImagePrefix=@"--signed-image=";

NSString *TKExecutionModeIdentifier(TKExecutionMode mode) {
    switch(mode) {
    case TKExecutionModeDeveloperService: return @"developer-service";
    case TKExecutionModeLocalSigning: return @"local-signing";
    case TKExecutionModeExternalJIT: return @"external-jit";
    case TKExecutionModeNone: break;
    }
    return nil;
}
TKExecutionMode TKExecutionModeFromIdentifier(NSString *identifier) {
    if(![identifier isKindOfClass:NSString.class]) return TKExecutionModeNone;
    for(TKExecutionMode mode=TKExecutionModeDeveloperService;mode<=TKExecutionModeExternalJIT;mode++)
        if([identifier isEqualToString:TKExecutionModeIdentifier(mode)]) return mode;
    return TKExecutionModeNone;
}
NSString *TKExecutionModeName(TKExecutionMode mode) {
    switch(mode) {
    case TKExecutionModeDeveloperService: return @"Developer service";
    case TKExecutionModeLocalSigning: return @"Local signing";
    case TKExecutionModeExternalJIT: return @"External JIT";
    case TKExecutionModeNone: break;
    }
    return nil;
}
NSString *TKExecutionModeSummary(TKExecutionMode mode) {
    switch(mode) {
    case TKExecutionModeDeveloperService:
        return @"Needs Developer Mode, a one-time enrolment from a Mac (tools/enroll.sh) and Tolkara's own VPN-style tunnel "
            "to this iPad's developer service. The application's code is never signed or changed: the service prepares memory and "
            "detaches, then Tolkara copies the original code in.";
    case TKExecutionModeLocalSigning:
        return @"Needs a page container signed with your own developer identity, currently built on a Mac with "
            "tools/build_signed_container.py and copied to Documents/LocalSigning. The application's executable is never changed, "
            "but the container is a copy of its final code pages, signed under your identity and kept on this iPad.";
    case TKExecutionModeExternalJIT:
        return @"Needs JIT enabled when Tolkara opens, by the tool you sideloaded it with (such as SideStore) or a JIT enabler such as StikDebug. "
            "The application's code is never signed or changed: the enabler's debugger prepares memory, then Tolkara copies the original code in.";
    case TKExecutionModeNone: break;
    }
    return nil;
}
BOOL TKExecutionModeAvailable(TKExecutionMode mode, NSString **reason) {
    if(reason) *reason=nil;
    switch(mode) {
    case TKExecutionModeLocalSigning: return YES;
    case TKExecutionModeDeveloperService:
#if TOLKARA_INTEGRATED_AUTH
        return YES;
#else
        if(reason) *reason=@"Not included in this build (TolkaraDiagnostics).";
        return NO;
#endif
    case TKExecutionModeExternalJIT:
#if TOLKARA_INTEGRATED_AUTH
        if(reason) *reason=@"Not included in this build (Tolkara).";
        return NO;
#else
        return YES;
#endif
    case TKExecutionModeNone: break;
    }
    if(reason) *reason=@"No execution mode chosen.";
    return NO;
}

TKExecutionMode TKExecutionModeLoad(NSUserDefaults *defaults) {
    return TKExecutionModeFromIdentifier([defaults objectForKey:TKExecutionModeDefaultsKey]);
}
void TKExecutionModeSave(NSUserDefaults *defaults, TKExecutionMode mode) {
    NSString *identifier=TKExecutionModeIdentifier(mode);
    if(identifier) [defaults setObject:identifier forKey:TKExecutionModeDefaultsKey];
    else [defaults removeObjectForKey:TKExecutionModeDefaultsKey];
}
BOOL TKExecutionModeApplySaveArgument(NSArray<NSString *> *arguments, NSUserDefaults *defaults, NSString **reason) {
    if(reason) *reason=nil;
    NSUInteger saves=0, modes=0; NSString *value=nil;
    for(NSString *argument in arguments) {
        if([argument isEqualToString:TKExecutionModeSaveArgument]) saves++;
        if([argument hasPrefix:TKExecutionModeArgumentPrefix]) { modes++;value=[argument substringFromIndex:TKExecutionModeArgumentPrefix.length]; }
    }
    if(!saves) return YES;
    NSString *problem=nil;
    TKExecutionMode mode=TKExecutionModeFromIdentifier(value);
    if(saves!=1 || modes!=1 || !mode) problem=@"requires one --save-execution-mode and one valid --execution-mode";
    else if(!TKExecutionModeAvailable(mode,&problem)) {}  // availability supplies its reason
    else { TKExecutionModeSave(defaults,mode);return YES; }
    if(reason) *reason=[@"invalid --save-execution-mode: " stringByAppendingString:problem];
    return NO;
}
BOOL TKExecutionModeSourceIsInvalid(NSString *source) {
    return [source hasPrefix:TKExecutionModeSourceInvalidArgument] || [source hasPrefix:TKExecutionModeSourceInvalidPreselection] || [source hasPrefix:@"invalid --save-execution-mode"];
}
static TKExecutionMode Resolved(TKExecutionMode mode, NSString *why, NSString **source) {
    if(source) *source=why;
    return mode;
}
TKExecutionMode TKExecutionModeResolve(NSArray<NSString *> *arguments, NSUserDefaults *defaults, NSString *preselected, NSString **source) {
    // Per-launch override: reported when unusable, never saved, never ignored.
    NSString *value=nil; NSUInteger given=0;
    for(NSString *argument in arguments) if([argument hasPrefix:TKExecutionModeArgumentPrefix]) {
        given++; value=[argument substringFromIndex:TKExecutionModeArgumentPrefix.length];
    }
    if(given>1) return Resolved(TKExecutionModeNone,[NSString stringWithFormat:@"%@ (given %lu times)",
        TKExecutionModeSourceInvalidArgument,(unsigned long)given],source);
    if(given) {
        TKExecutionMode mode=TKExecutionModeFromIdentifier(value);
        return mode ? Resolved(mode,TKExecutionModeSourceArgument,source) :
            Resolved(TKExecutionModeNone,[NSString stringWithFormat:@"%@ (%@)",TKExecutionModeSourceInvalidArgument,Expected],source);
    }
    TKExecutionMode saved=TKExecutionModeLoad(defaults);
    if(saved) return Resolved(saved,TKExecutionModeSourceSaved,source);
    // The build's preselection becomes the user's choice on first use.
    if([preselected isKindOfClass:NSString.class] && preselected.length) {
        TKExecutionMode mode=TKExecutionModeFromIdentifier(preselected);
        if(!mode) return Resolved(TKExecutionModeNone,[NSString stringWithFormat:@"%@ (%@)",TKExecutionModeSourceInvalidPreselection,Expected],source);
        TKExecutionModeSave(defaults,mode);
        return Resolved(mode,TKExecutionModeSourcePreselected,source);
    }
    return Resolved(TKExecutionModeNone,TKExecutionModeSourceNone,source);
}

NSString *TKLocalSigningContainerDisplayPath(void) { return @"Documents/LocalSigning/page-container.dylib"; }
NSString *TKLocalSigningContainerPath(NSString *home) {
    return [home.stringByStandardizingPath stringByAppendingPathComponent:TKLocalSigningContainerDisplayPath()];
}

NSString *TKLocalSigningAppContainerDisplayPath(NSString *sha256) {
    if(![sha256 isKindOfClass:NSString.class] || sha256.length!=64 ||
        [sha256 rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound) return nil;
    return [NSString stringWithFormat:@"Documents/LocalSigning/%@.dylib",sha256];
}
NSString *TKLocalSigningAppContainerPath(NSString *home, NSString *sha256) {
    NSString *relative=TKLocalSigningAppContainerDisplayPath(sha256);
    return relative ? [home.stringByStandardizingPath stringByAppendingPathComponent:relative] : nil;
}
NSString *TKLocalSigningFindContainer(NSString *home, NSString *sha256) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *own=TKLocalSigningAppContainerPath(home,sha256), *shared=TKLocalSigningContainerPath(home);
    if(own && [files fileExistsAtPath:own]) return own;
    return [files fileExistsAtPath:shared] ? shared : nil;
}

NSString *TKSignedImagePath(NSArray<NSString *> *arguments, NSString *home, NSString **reason) {
    if(reason) *reason=nil;
    NSString *value=nil; NSUInteger given=0;
    for(NSString *argument in arguments) if([argument hasPrefix:SignedImagePrefix]) {
        given++; value=[argument substringFromIndex:SignedImagePrefix.length];
    }
    if(!given) return nil;
    NSString *root=home.stringByStandardizingPath, *prefix=[root stringByAppendingString:@"/"], *container=nil, *problem=nil;
    if(given>1) problem=[NSString stringWithFormat:@"--signed-image given %lu times; pass it at most once",(unsigned long)given];
    else if(!value.length) problem=@"container path is empty";
    // Reject '..' components up front: -stringByStandardizingPath may leave
    // them unresolved when a preceding component is a symlink, so the prefix
    // check below cannot be relied on alone to keep the path inside home.
    else if([value.pathComponents containsObject:@".."]) problem=@"container path must not contain '..'";
    else {
        container=(value.isAbsolutePath?value:[root stringByAppendingPathComponent:value]).stringByStandardizingPath;
        if(![container isEqualToString:root] && ![container hasPrefix:prefix]) problem=@"container must stay inside the app home";
    }
    if(problem) { if(reason) *reason=problem; return nil; }
    return container;
}
NSString *TKHomeDisplayPath(NSString *path, NSString *home) {
    NSString *root=home.stringByStandardizingPath, *prefix=[root stringByAppendingString:@"/"], *standard=path.stringByStandardizingPath;
    if([standard isEqualToString:root]) return @"~";
    if([standard hasPrefix:prefix]) return [@"~/" stringByAppendingString:[standard substringFromIndex:prefix.length]];
    return standard.lastPathComponent;
}
