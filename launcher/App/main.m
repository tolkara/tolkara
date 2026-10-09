// UIKit launcher: keeps a library of unchanged macOS executables the user owns,
// starts them through the translation runtime in the user's chosen execution
// mode, and offers development checks in a separate Diagnostics menu.
#import <UIKit/UIKit.h>
#import "AppLibrary.h"
#import "Diagnostics.h"
#import "DiagnosticsViewController.h"
#import "ExecutionMode.h"
#import "LibraryViewController.h"
#import "LaunchProgressView.h"
#import "NativeGuest.h"
#import "SignedFileProbe.h"
#import "StartupActivity.h"
#import "../Cloud/SteamCloudCoordinator.h"
#include "HostDiagnostics.h"
#include <errno.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#if TOLKARA_INTEGRATED_AUTH
#import "LocalAuthorization.h"
#import "Tolkara-Swift.h"
#endif

@interface AKHostSceneDelegate : UIResponder <UIWindowSceneDelegate, TKLibraryViewControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) TKLaunchProgressView *launchProgress;
@property(nonatomic, strong) TKStartupActivityView *startupActivity;
@property(nonatomic, strong) UIButton *diagnosticsButton;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) TKLibraryViewController *libraryController;
@property(nonatomic, strong) TKAppLibrary *library;
@property(nonatomic, strong, nullable) TKApp *launchingApp;
@property(nonatomic, strong) TKSteamCloudCoordinator *steamCloud;
@property(nonatomic) BOOL cloudPrepared;
@property(nonatomic) BOOL cloudPreparing;
@property(nonatomic) BOOL cloudFullStartup;
@property(nonatomic, strong) TKApp *cloudApp;
@property(nonatomic, copy) NSString *cloudContainer;
// iPadOS allows one guest startup per process; some checks also end it.
@property(nonatomic) BOOL sessionUsed;
// A plain launch (library shown, no development arguments): a game that
// closes cleanly ends the process so the next tap starts another app.
@property(nonatomic) BOOL uiSession;
@property(nonatomic) BOOL consumedImportArgument;
// This launch's execution mode and where it came from (logged; never a path).
@property(nonatomic) TKExecutionMode executionMode;
@property(nonatomic,copy) NSString *executionModeSource;
#if TOLKARA_INTEGRATED_AUTH
@property(nonatomic,strong) TKLocalAuthorization *localAuthorization;
// A development run's startup kind, kept while this iPad's Developer service prepares.
@property(nonatomic) BOOL nativeFullStartup;
#endif
@end

// App profiles (profiles/*/profile.json, packaged into Guest/Profiles) name
// known applications and say where their files live under Documents. They
// carry no code and no app data; the library adds a profile's app when its
// files are present.
static TKAppLibrary *OpenLibrary(void) {
    NSString *profiles=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/Profiles"];
    NSString *storage=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Tolkara"];
    return [[TKAppLibrary alloc] initWithDocuments:TKDocumentsPath(@"") storage:storage profiles:[TKAppLibrary profilesInDirectory:profiles]];
}
// Starting apps needs compatibility
// libraries built for the imported executables (tools/install.sh).
// Generic ones count too: both ship libAKSupport.dylib.
static BOOL CanStartApps(void) {
    NSString *support=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libAKSupport.dylib"];
    return [NSFileManager.defaultManager fileExistsAtPath:support];
}
static void FlushSteamCloudAtExit(int code, void *context) {
    if (!code) @autoreleasepool { [(__bridge TKSteamCloudCoordinator *)context flush]; }
}
static const char *ModeIdentifier(TKExecutionMode mode) { return (TKExecutionModeIdentifier(mode)?:@"none").UTF8String; }
// Files shows the app's Documents under its bundle name (Tolkara or TolkaraDiagnostics).
static NSString *FilesFolderName(void) {
    NSDictionary *info=NSBundle.mainBundle.infoDictionary; id name=info[@"CFBundleDisplayName"]?:info[@"CFBundleName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : @"this app";
}
static NSString *LocalSigningNeeds(NSString *sha256) {
    NSString *container=TKLocalSigningAppContainerDisplayPath(sha256)?:TKLocalSigningContainerDisplayPath();
    return [NSString stringWithFormat:@"Local signing needs this app's page container at %@ (visible in Files > On My iPad > %@ > LocalSigning). "
        "Build it on a Mac with tools/build_signed_container.py (tools/install.sh does) and copy it there; see docs/BUILDING.md.",container,FilesFolderName()];
}
// Show the folder in Files so the user can put containers there.
static void PrepareLocalSigningFolder(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:TKLocalSigningContainerPath(NSHomeDirectory()).stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL];
}
// JIT enabled from outside, or an arena its enabler left.
static BOOL PreparedFromOutside(void) { return hd_may_run_unsigned_code() || ng_arena_reserved(); }

// Explicit execution-mode choice: equal buttons, neither highlighted nor
// recommended. The first choice cannot be dismissed without choosing.
@interface TKExecutionModeChooser : UIViewController
- (instancetype)initWithApp:(NSString *)app current:(TKExecutionMode)current cancellable:(BOOL)cancellable chosen:(void (^)(TKExecutionMode))chosen;
@end
@implementation TKExecutionModeChooser {
    NSString *_app; TKExecutionMode _current; BOOL _cancellable; void (^_chosen)(TKExecutionMode);
}
- (instancetype)initWithApp:(NSString *)app current:(TKExecutionMode)current cancellable:(BOOL)cancellable chosen:(void (^)(TKExecutionMode))chosen {
    if (!(self=[super initWithNibName:nil bundle:nil])) return nil;
    _app=app;_current=current;_cancellable=cancellable;_chosen=[chosen copy];
    self.modalPresentationStyle=UIModalPresentationFormSheet;
    self.modalInPresentation=!cancellable;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *title=[UILabel new], *line=[UILabel new];
    title.text=[NSString stringWithFormat:@"How should Tolkara run %@?",_app];
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    line.text=@"Choose one. You can change it later with Execution mode.";
    line.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    line.textColor=UIColor.secondaryLabelColor;
    for (UILabel *label in @[title,line]) { label.numberOfLines=0; label.adjustsFontForContentSizeCategory=YES; }
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,line]];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=16;
    [stack setCustomSpacing:28 afterView:line];
    __weak TKExecutionModeChooser *weakSelf=self;
    for (NSNumber *each in @[@(TKExecutionModeDeveloperService),@(TKExecutionModeLocalSigning),@(TKExecutionModeExternalJIT)]) {
        TKExecutionMode mode=each.integerValue; NSString *unavailable=nil;
        BOOL available=TKExecutionModeAvailable(mode,&unavailable);
        NSString *subtitle=TKExecutionModeSummary(mode);
        if (_cancellable && mode==_current) subtitle=[@"Current. " stringByAppendingString:subtitle];
        if (!available) subtitle=[subtitle stringByAppendingFormat:@"\n%@",unavailable];
        UIButtonConfiguration *configuration=UIButtonConfiguration.grayButtonConfiguration;
        configuration.title=TKExecutionModeName(mode); configuration.subtitle=subtitle;
        configuration.titleAlignment=UIButtonConfigurationTitleAlignmentLeading;
        configuration.titlePadding=8;
        configuration.contentInsets=NSDirectionalEdgeInsetsMake(20,20,20,20);
        configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes) {
            NSMutableDictionary *result=attributes.mutableCopy; result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; return result;
        };
        configuration.subtitleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes) {
            NSMutableDictionary *result=attributes.mutableCopy; result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; return result;
        };
        UIButton *button=[UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action;[weakSelf choose:mode];
        }]];
        button.enabled=available;
        [stack addArrangedSubview:button];
    }
    if (_cancellable) {
        UIButtonConfiguration *configuration=UIButtonConfiguration.plainButtonConfiguration; configuration.title=@"Cancel";
        [stack addArrangedSubview:[UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action;[weakSelf.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }]]];
    }
    UIScrollView *scroll=[UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints=NO; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:scroll]; [scroll addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:32],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-32],
    ]];
}
- (void)choose:(TKExecutionMode)mode {
    if (_chosen) _chosen(mode);
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}
@end

@implementation AKHostSceneDelegate
- (UISceneWindowingControlStyle *)preferredWindowingControlStyleForScene:(UIWindowScene *)scene API_AVAILABLE(ios(26.0)) {
    (void)scene;
    return UISceneWindowingControlStyle.minimalStyle;
}
// An enabler attaches only briefly: take its arena now.
- (void)reserveExecutableMemory {
    // External JIT only: any other debugger stops at the request.
    if(self.executionMode!=TKExecutionModeExternalJIT || !TKExecutionModeAvailable(self.executionMode,NULL) ||
       ng_arena_reserved() || !hd_debugger_attached() || !CanStartApps()) return;
    ng_reserve_arena(NULL);
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    (void)scene; [self reserveExecutableMemory];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    static BOOL started;
    if (started) return;
    started = YES;
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    // --execution-mode=<id> > saved choice > TOLKARA_MODE preselection > ask.
    NSString *source=nil;
    NSString *saveProblem=nil;
    if(TKExecutionModeApplySaveArgument(arguments,NSUserDefaults.standardUserDefaults,&saveProblem))
        self.executionMode=TKExecutionModeResolve(arguments,NSUserDefaults.standardUserDefaults,
            [NSBundle.mainBundle objectForInfoDictionaryKey:TKExecutionModePreselectionKey],&source);
    else { self.executionMode=TKExecutionModeNone;source=saveProblem; }
    self.executionModeSource=source;
    fprintf(stderr,"[host] execution mode=%s source=%s\n",ModeIdentifier(self.executionMode),source.UTF8String);
    // Any Local signing launch makes the container folder, so a fresh install
    // can receive containers (tools/install.sh launches once if needed).
    if (self.executionMode==TKExecutionModeLocalSigning) PrepareLocalSigningFolder();
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    [self reserveExecutableMemory];
    self.library = OpenLibrary();
#if TOLKARA_INTEGRATED_AUTH
    (void)[TKEnrollmentImport prepare];
    self.localAuthorization=[TKLocalAuthorization new];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(arenaWillPrepare:)
        name:TKLocalArenaWillPrepare object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(arenaDidPrepare:)
        name:TKLocalArenaDidPrepare object:nil];
#endif
    // A plain launch (no arguments, or a mode choice with optional explicit save)
    // shows the app library. Any other launch is a development run from
    // tools/: keep its plain status screen and behaviour.
    BOOL plain=YES;
    for(NSUInteger i=1;i<arguments.count;i++) if(![arguments[i] hasPrefix:TKExecutionModeArgumentPrefix] &&
        ![arguments[i] isEqualToString:TKExecutionModeSaveArgument]) plain=NO;
    if (plain) {
        self.uiSession=YES;
        self.libraryController=[[TKLibraryViewController alloc] initWithLibrary:self.library];
        self.libraryController.delegate=self;
        // An unusable per-launch mode or preselection never falls back; say so.
        if (TKExecutionModeSourceIsInvalid(source))
            self.libraryController.notice=[NSString stringWithFormat:@"Execution mode not set: %@. Choose one with Execution Mode before starting an app.",source];
        self.navigation=[[UINavigationController alloc] initWithRootViewController:self.libraryController];
        self.window.rootViewController=self.navigation;
        [self.window makeKeyAndVisible];
        [self performSelector:@selector(askExecutionModeIfNeeded) withObject:nil afterDelay:0];
        return;
    }
    self.window.rootViewController = [self statusController];
    // Development runs can prepare for minutes before a guest starts; Auto-Lock must not end them.
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    self.status.text = @"Preparing original guest executable…";
    [self.window makeKeyAndVisible];
    // Timer callout, not dispatch_async: the guest never returns from main(), and a
    // main-queue block that never returns would wedge the main dispatch queue.
    [self performSelector:@selector(startGuest) withObject:nil afterDelay:0];
}
- (UIViewController *)statusController {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightRegular];
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.status];
    self.launchProgress = [TKLaunchProgressView new];
    self.launchProgress.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.launchProgress];
    self.startupActivity = [TKStartupActivityView new];
    self.startupActivity.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.startupActivity];
    self.diagnosticsButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.diagnosticsButton setTitle:@"Diagnostics and logs" forState:UIControlStateNormal];
    [self.diagnosticsButton addTarget:self action:@selector(showDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    self.diagnosticsButton.translatesAutoresizingMaskIntoConstraints=NO;
    self.diagnosticsButton.hidden=YES;
    [controller.view addSubview:self.diagnosticsButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.status.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:32],
        [self.status.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-32],
        [self.status.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [self.launchProgress.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:20],
        [self.launchProgress.leadingAnchor constraintEqualToAnchor:self.status.leadingAnchor],
        [self.startupActivity.topAnchor constraintEqualToAnchor:self.launchProgress.bottomAnchor constant:12],
        [self.startupActivity.leadingAnchor constraintEqualToAnchor:self.status.leadingAnchor],
        [self.startupActivity.trailingAnchor constraintEqualToAnchor:self.status.trailingAnchor],
        [self.diagnosticsButton.topAnchor constraintEqualToAnchor:self.startupActivity.bottomAnchor constant:24],
        [self.diagnosticsButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
    return controller;
}
// Ends with the status screen in front; the library cannot come back because
// this process can no longer start an app.
- (void)showStatusScreen {
    if (!self.navigation) return;
    UIViewController *controller=[self statusController];
    controller.navigationItem.hidesBackButton=YES;
    [self.navigation setNavigationBarHidden:YES animated:NO];
    [self.navigation pushViewController:controller animated:YES];
}
- (void)showStartStopped {
    [self.launchProgress stop];
    [self stopStartupActivity];
    self.diagnosticsButton.hidden=NO;
    UIApplication.sharedApplication.idleTimerDisabled=NO;
}
- (void)endSession:(NSString *)reason {
    self.sessionUsed=YES;
    self.libraryController.notice=reason;
}

#pragma mark Execution mode

// First launch with no chosen, saved or preselected mode: ask before any app
// starts; the choice cannot be skipped. TolkaraDiagnostics asks only when an
// app starts.
- (void)askExecutionModeIfNeeded {
#if TOLKARA_INTEGRATED_AUTH
    if (!self.executionMode) [self chooseExecutionMode:NO forApp:nil];
#endif
}
// The mode chooser over whatever is showing. When app is given, its start
// continues once the mode is chosen.
- (void)chooseExecutionMode:(BOOL)cancellable forApp:(TKApp *)app {
    if ([self.window.rootViewController.presentedViewController isKindOfClass:TKExecutionModeChooser.class]) return;
    __weak AKHostSceneDelegate *weakSelf=self;
    TKExecutionModeChooser *chooser=[[TKExecutionModeChooser alloc] initWithApp:app.name?:@"your apps"
        current:self.executionMode cancellable:cancellable chosen:^(TKExecutionMode mode) {
        TKExecutionModeSave(NSUserDefaults.standardUserDefaults,mode);
        weakSelf.executionMode=mode;weakSelf.executionModeSource=@"chosen";
        fprintf(stderr,"[host] execution mode=%s source=chosen\n",ModeIdentifier(mode));
        weakSelf.libraryController.notice=nil;
        if (mode==TKExecutionModeLocalSigning) PrepareLocalSigningFolder();
        if (app) [weakSelf libraryViewController:weakSelf.libraryController startApp:app];
    }];
    [self.window.rootViewController presentViewController:chooser animated:YES completion:nil];
}
// Cancellable once a mode is chosen; the first choice cannot be skipped.
- (void)changeExecutionMode { [self chooseExecutionMode:self.executionMode!=TKExecutionModeNone forApp:nil]; }

#pragma mark Library

// --app=<identifier> selects an app for development runs (the library UUID or
// its profile id); otherwise the most recently started one (or a profile app)
// is used. Discovery runs first: on a fresh launch nothing has populated the
// library yet.
- (TKApp *)appFromArguments {
    [self.library discover];
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if (![argument hasPrefix:@"--app="]) continue;
        NSString *requested=[argument substringFromIndex:6];
        TKApp *app=[self.library appWithIdentifier:requested];
        if (app) return app;
        for (TKApp *candidate in self.library.apps) if ([candidate.profile isEqualToString:requested]) return candidate;
        return nil;
    }
    return self.library.defaultApp;
}
- (void)libraryViewController:(TKLibraryViewController *)controller startApp:(TKApp *)app {
    (void)controller;
    if (!CanStartApps()) {
        // A build with no compatibility libraries at all checks the loader only.
        [self libraryViewController:controller checkApp:app];
        return;
    }
    // Starting an app uses the chosen execution mode. Without one the user
    // must choose first (not skippable), then the start continues.
    if (!self.executionMode) { [self chooseExecutionMode:NO forApp:app]; return; }
    NSString *unavailable=nil;
    if (!TKExecutionModeAvailable(self.executionMode,&unavailable)) { [self alert:@"Execution Mode Unavailable" message:unavailable]; return; }
    if (self.executionMode==TKExecutionModeLocalSigning) { [self launchLocalSigningApp:app]; return; }
    if (self.executionMode==TKExecutionModeExternalJIT) { [self launchExternalJITApp:app]; return; }
#if TOLKARA_INTEGRATED_AUTH
    [self launchLocalApp:app];
#endif
}
- (void)libraryViewController:(TKLibraryViewController *)controller checkApp:(TKApp *)app {
    (void)controller;
    TKReportViewController *report=[[TKReportViewController alloc] initWithTitle:app.name file:nil];
    report.text=@"Checking the loader… No app code is run.";
    [self.navigation pushViewController:report animated:YES];
    NSError *error=nil;
    NSString *path=[self.library executablePathForApp:app error:&error];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *message=TKLoaderCheck(path,error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(),^{ report.text=message; });
    });
}
- (void)libraryViewControllerShowDiagnostics:(TKLibraryViewController *)controller {
    (void)controller;
    [self showDiagnostics];
}
- (void)libraryViewControllerShowExecutionMode:(TKLibraryViewController *)controller {
    (void)controller;
    [self changeExecutionMode];
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}

#pragma mark Diagnostics

- (void)showDiagnostics {
    TKDiagnosticsViewController *diagnostics=[[TKDiagnosticsViewController alloc] initWithSections:[self diagnosticSections]];
    __weak AKHostSceneDelegate *weakSelf=self;
    diagnostics.sessionEnding=^{
        [weakSelf endSession:@"A diagnostic test ran in this session. Close Tolkara in the app switcher and open it again before starting an app."];
    };
    if (self.navigation && self.window.rootViewController==self.navigation) {
        [self.navigation setNavigationBarHidden:NO animated:YES];
        [self.navigation pushViewController:diagnostics animated:YES];
        return;
    }
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:diagnostics];
    diagnostics.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        primaryAction:[UIAction actionWithHandler:^(UIAction *action) { (void)action; [navigation dismissViewControllerAnimated:YES completion:nil]; }]];
    [self.window.rootViewController presentViewController:navigation animated:YES completion:nil];
}
- (NSArray<TKDiagnosticSection *> *)diagnosticSections {
    NSMutableArray *sections=[NSMutableArray new];
    TKAppLibrary *library=self.library;
    [sections addObject:[TKDiagnosticSection sectionWithTitle:@"Runtime" footer:@"These checks run only Tolkara's own code." items:@[
        [TKDiagnostic diagnosticWithTitle:@"Host diagnostics" detail:@"Debugger, code signing, memory and the arena limit. No probe sample runs." run:^(TKDiagnosticReport report) {
            report(TKHostDiagnosticsReport(),YES);
        }],
        [TKDiagnostic diagnosticWithTitle:@"Check loader" detail:@"Loads the most recently started app into emulated memory without running it." run:^(TKDiagnosticReport report) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                [library discover];
                TKApp *app=library.defaultApp;
                NSError *error=nil;
                NSString *path=app ? [library executablePathForApp:app error:&error] : nil;
                NSString *message=TKLoaderCheck(path,app ? error.localizedDescription : @"Add an app to the library first.");
                report(app ? [NSString stringWithFormat:@"%@\n\n%@",app.name,message] : message,YES);
            });
        }],
        [TKDiagnostic diagnosticWithTitle:@"CPU interpreter" detail:@"Runs Tolkara's test program through the interpreter." run:^(TKDiagnosticReport report) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ report(TKCPUProbeReport(),YES); });
        }],
        [TKDiagnostic diagnosticWithTitle:@"Signed code mapping" detail:@"Remaps Tolkara's own signed pages." run:^(TKDiagnosticReport report) {
            report(TKSignedCacheProbeReport(),YES);
        }],
        [TKDiagnostic diagnosticWithTitle:@"Local shader compiler" detail:@"Compiles the shader fixtures staged in Documents/LocalShaderProbe." run:^(TKDiagnosticReport report) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ report(TKLocalShaderProbeReport(),YES); });
        }],
        [TKDiagnostic diagnosticWithTitle:@"Captured shaders" detail:@"Compiles every shader library a game left in Documents/ShaderRequests on this iPad." run:^(TKDiagnosticReport report) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ report(TKCapturedShaderProbeReport(),YES); });
        }],
    ]]];
#if TOLKARA_INTEGRATED_AUTH
    TKLocalAuthorization *authorization=self.localAuthorization;
    [sections addObject:[TKDiagnosticSection sectionWithTitle:@"Local launch"
        footer:@"The local route connects Tolkara to the iPad's development service. Starting it may ask to add a VPN configuration." items:@[
        [TKDiagnostic diagnosticWithTitle:@"Check direct access" detail:nil run:^(TKDiagnosticReport report) {
            [TKLocalAuthorization probeDirectAccess:^(NSString *result) { report(result,YES); }];
        }],
        [TKDiagnostic diagnosticWithTitle:@"Start local route" detail:nil run:^(TKDiagnosticReport report) {
            [authorization startLocalRoute:^(NSString *result) { report(result,YES); }];
        }],
        [TKDiagnostic diagnosticWithTitle:@"Check local route service" detail:nil run:^(TKDiagnosticReport report) {
            [TKLocalAuthorization probeLocalRouteService:^(NSString *result) {
                [result writeToFile:TKDocumentsPath(@"local-route-service-probe.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                report(result,YES);
            }];
        }],
        [TKDiagnostic diagnosticWithTitle:@"Stop local route" detail:nil run:^(TKDiagnosticReport report) {
            [authorization stopLocalRoute];
            report(@"Local route stopped.",YES);
        }],
    ]]];
#endif
    TKDiagnostic *(^endsSession)(TKDiagnostic *)=^(TKDiagnostic *diagnostic) { diagnostic.endsSession=YES; return diagnostic; };
    // Run from a timer callout, as at launch: these block the main thread.
    void (^onMainRunLoop)(dispatch_block_t)=^(dispatch_block_t block) {
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) { (void)timer; block(); }];
    };
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    [sections addObject:[TKDiagnosticSection sectionWithTitle:@"Session-ending tests"
        footer:@"These execute host-generated code or load compatibility libraries, and the system may close Tolkara. Reopen Tolkara before starting an app." items:@[
        endsSession([TKDiagnostic diagnosticWithTitle:@"Execution: RW → RX" detail:@"Tolkara's two-instruction sample." run:^(TKDiagnosticReport report) {
            onMainRunLoop(^{ report(TKExecutionProbeReport(HP_WRITE_THEN_EXECUTE,arguments),YES); });
        }]),
        endsSession([TKDiagnostic diagnosticWithTitle:@"Execution: shared RW / RX views" detail:@"Tolkara's two-instruction sample." run:^(TKDiagnosticReport report) {
            onMainRunLoop(^{ report(TKExecutionProbeReport(HP_DUAL_MAPPING,arguments),YES); });
        }]),
        endsSession([TKDiagnostic diagnosticWithTitle:@"Execution: RWX" detail:@"Tolkara's two-instruction sample." run:^(TKDiagnosticReport report) {
            onMainRunLoop(^{ report(TKExecutionProbeReport(HP_READ_WRITE_EXECUTE,arguments),YES); });
        }]),
        endsSession([TKDiagnostic diagnosticWithTitle:@"Shader pause and recovery" detail:@"Needs Documents/shader-pause-probe.metallib. Takes over a minute." run:^(TKDiagnosticReport report) {
            onMainRunLoop(^{ report(TKShaderPauseProbeReport(),YES); });
        }]),
    ]]];
    return sections;
}

#pragma mark Starting apps

#if TOLKARA_INTEGRATED_AUTH
// Developer service: the iPad's developer service prepares memory and detaches
// before any application code runs.
- (void)launchLocalApp:(TKApp *)app {
    if(self.sessionUsed) {
        [self alert:@"Reopen Tolkara" message:@"Only one app can start per session. Close Tolkara in the app switcher and open it again."];
        return;
    }
    NSError *error=nil;
    if(!app || ![self.library executablePathForApp:app error:&error] || ![self.library workingDirectoryForApp:app error:&error]) {
        NSString *message=app ? error.localizedDescription : @"Add an app to the library first.";
        if(self.navigation) [self alert:@"Cannot Start App" message:message];
        else self.status.text=message;
        return;
    }
    [self endSession:[NSString stringWithFormat:@"%@ was started in this session. Close Tolkara in the app switcher and open it again to start an app.",app.name]];
    self.launchingApp=app;
    [self.library recordLaunchOfApp:app error:NULL];
    [self showStatusScreen];
    // Preserve responsiveness on an uncached shader while local translation
    // is being completed; a missing artifact must not become a nil library.
    setenv("TOLKARA_WAIT_FOR_MISSING_SHADERS","1",1);
    if([NSProcessInfo.processInfo.arguments containsObject:@"--local-shaders-only"])
        setenv("TOLKARA_LOCAL_SHADERS_ONLY","1",1);
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    self.status.text=[NSString stringWithFormat:@"Preparing %@\nConnecting to the developer service…",app.name];
    [self.launchProgress start];
    [self.localAuthorization startAndPrepareLocalAuthorization:^(NSString *report) {
        [report writeToFile:TKDocumentsPath(@"local-game-setup.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if(!self.localAuthorization.localSessionReady || !ng_use_local_authorization()) {
            self.status.text=[@"Local launch could not prepare. Close and reopen the app to retry.\n" stringByAppendingString:report];
            [self showStartStopped];return;
        }
        self.status.text=[NSString stringWithFormat:@"Starting %@…\nKeep Tolkara open.",app.name];
        // Guest main must enter from a timer callout, never a dispatch block.
        [self performSelector:@selector(startLocalGame) withObject:nil afterDelay:0];
    }];
}
- (void)startLocalGame { [self runNativeGame:YES app:self.launchingApp container:nil]; }
#endif
// Local signing: the page container holds the app's final code pages, signed
// with the user's own identity. Without it, say what is needed; the session
// stays usable and the library remains in front.
- (void)launchLocalSigningApp:(TKApp *)app {
    if(self.sessionUsed) {
        [self alert:@"Reopen Tolkara" message:@"Only one app can start per session. Close Tolkara in the app switcher and open it again."];
        return;
    }
    NSError *error=nil;
    if(![self.library executablePathForApp:app error:&error] || ![self.library workingDirectoryForApp:app error:&error]) {
        [self alert:@"Cannot Start App" message:error.localizedDescription];
        return;
    }
    // The container is named after the executable's current SHA-256; hashing
    // it is slow, so look for the container off the main thread.
    self.libraryController.navigationItem.prompt=[NSString stringWithFormat:@"Preparing %@…",app.name];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *sha=[self.library currentSHA256OfApp:app error:NULL];
        NSString *container=TKLocalSigningFindContainer(NSHomeDirectory(),sha);
        dispatch_async(dispatch_get_main_queue(),^{
            self.libraryController.navigationItem.prompt=nil;
            if(self.sessionUsed) {
                [self alert:@"Reopen Tolkara" message:@"Only one app can start per session. Close Tolkara in the app switcher and open it again."];
                return;
            }
            if(!container) {
                PrepareLocalSigningFolder();
                [self alert:@"Page Container Needed" message:LocalSigningNeeds(sha?:app.sha256)];
                return;
            }
            [self endSession:[NSString stringWithFormat:@"%@ was started in this session. Close Tolkara in the app switcher and open it again to start an app.",app.name]];
            self.launchingApp=app;
            [self.library recordLaunchOfApp:app error:NULL];
            [self showStatusScreen];
            // As for Developer service: an uncached shader waits instead of failing.
            setenv("TOLKARA_WAIT_FOR_MISSING_SHADERS","1",1);
            UIApplication.sharedApplication.idleTimerDisabled=YES;
            self.status.text=[NSString stringWithFormat:@"Starting %@…\nKeep Tolkara open.",app.name];
            // Guest main must enter from a timer callout, never a dispatch block.
            [self performSelector:@selector(startSignedGame:) withObject:container afterDelay:0];
        });
    });
}
- (void)startSignedGame:(NSString *)container { [self runNativeGame:YES app:self.launchingApp container:container]; }
// External JIT: a tool outside the app prepares memory.
- (void)launchExternalJITApp:(TKApp *)app {
    if(self.sessionUsed) {
        [self alert:@"Reopen Tolkara" message:@"Only one app can start per session. Close Tolkara in the app switcher and open it again."];
        return;
    }
    NSError *error=nil;
    if(![self.library executablePathForApp:app error:&error] || ![self.library workingDirectoryForApp:app error:&error]) {
        [self alert:@"Cannot Start App" message:error.localizedDescription];
        return;
    }
    // Opened without JIT: say so; the session stays usable.
    if(!PreparedFromOutside()) {
        [self alert:@"JIT Not Enabled" message:@"Tolkara was opened without JIT. Enable JIT for it with the tool you sideloaded it with "
            "(such as SideStore) or a JIT enabler such as StikDebug, then open it again."];
        return;
    }
    [self endSession:[NSString stringWithFormat:@"%@ was started in this session. Close Tolkara in the app switcher and open it again to start an app.",app.name]];
    self.launchingApp=app;
    [self.library recordLaunchOfApp:app error:NULL];
    [self showStatusScreen];
    // An uncached shader waits instead of failing.
    setenv("TOLKARA_WAIT_FOR_MISSING_SHADERS","1",1);
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    self.status.text=[NSString stringWithFormat:@"Starting %@…\nKeep Tolkara open.",app.name];
    // Enter from a timer callout, never a dispatch block.
    [self performSelector:@selector(startExternalJITGame) withObject:nil afterDelay:0];
}
- (void)startExternalJITGame {
    (void)ng_use_external_authorization();
    [self runNativeGame:YES app:self.launchingApp container:nil];
}

#pragma mark Native runs

// Refuse a native startup before it begins; the runtime log says why.
- (void)refuseNativeGame:(NSString *)reason {
    FILE *log=fopen(TKDocumentsPath(@"native-guest.log").fileSystemRepresentation,"w");
    if (log) { fprintf(log,"[host] native startup refused: %s\n",reason.UTF8String); fclose(log); }
    self.status.text=reason;
}
// Only an unusable --execution-mode stops a diagnostic launch. An invalid
// TOLKARA_MODE preselection just means no mode: the launch flags decide.
- (BOOL)refuseInvalidModeArgument {
    if (![self.executionModeSource hasPrefix:TKExecutionModeSourceInvalidArgument]) return NO;
    [self refuseNativeGame:[NSString stringWithFormat:@"Cannot start: %@.",self.executionModeSource]];
    return YES;
}
// A launch flag that decides the mode by itself. It replaces a saved choice or
// a preselection (the log keeps what it replaced), but a --execution-mode that
// says otherwise is refused: two explicit flags that disagree are not settled.
- (BOOL)forceExecutionMode:(TKExecutionMode)mode by:(NSString *)flag {
    NSString *source=self.executionModeSource;
    if (self.executionMode!=mode && [source isEqualToString:TKExecutionModeSourceArgument]) {
        [self refuseNativeGame:[NSString stringWithFormat:@"--execution-mode=%s conflicts with %@, which uses %@. Pass only one of them.",
            ModeIdentifier(self.executionMode),flag,TKExecutionModeName(mode)]];
        return NO;
    }
    self.executionModeSource=self.executionMode!=mode && ![source isEqualToString:TKExecutionModeSourceNone] ?
        [NSString stringWithFormat:@"%@ (overrides %s from %@)",flag,ModeIdentifier(self.executionMode),source] : flag;
    self.executionMode=mode;
    fprintf(stderr,"[host] execution mode=%s source=%s\n",ModeIdentifier(mode),self.executionModeSource.UTF8String);
    return YES;
}
// --native-initializer / --native-startup: the container from --signed-image=
// if given, else Local signing's container for the selected app when that is
// the mode, else the Developer-service/debugger path exactly as before modes
// existed.
- (void)startNativeDiagnostic:(BOOL)fullStartup {
    if ([self refuseInvalidModeArgument]) return;
    NSString *problem=nil, *container=TKSignedImagePath(NSProcessInfo.processInfo.arguments,NSHomeDirectory(),&problem);
    if (problem) { [self refuseNativeGame:[NSString stringWithFormat:@"--signed-image rejected: %@.",problem]];return; }
    if (container) { if (![self forceExecutionMode:TKExecutionModeLocalSigning by:@"--signed-image"]) return; }
    TKApp *app=[self appFromArguments];
    if (!container && self.executionMode==TKExecutionModeLocalSigning) {
        NSString *sha=app ? [self.library currentSHA256OfApp:app error:NULL] : nil;
        container=TKLocalSigningFindContainer(NSHomeDirectory(),sha);
        if (!container) {
            PrepareLocalSigningFolder();
            // A saved choice or preselection is shared with the interactive app; say how to override it.
            NSString *reason=LocalSigningNeeds(sha?:app.sha256);
            if (![self.executionModeSource isEqualToString:TKExecutionModeSourceArgument])
                reason=[reason stringByAppendingFormat:@" (Local signing is the %@ execution mode; pass --execution-mode=developer-service for the debugger path.)",
                    [self.executionModeSource isEqualToString:TKExecutionModeSourceSaved]?@"saved":@"preselected"];
            [self refuseNativeGame:reason];return;
        }
    }
    // External JIT names its route; nothing infers it. A build without it
    // refuses rather than taking another route under that name.
    if (!container && self.executionMode==TKExecutionModeExternalJIT) {
        NSString *unavailable=nil;
        if (!TKExecutionModeAvailable(TKExecutionModeExternalJIT,&unavailable) || !ng_use_external_authorization()) {
            [self refuseNativeGame:unavailable?:@"External JIT could not be selected for this run."];return;
        }
    }
#if TOLKARA_INTEGRATED_AUTH
    // Opt-in: without it these runs wait for a Mac-side debugger as before.
    if (!container && app && [NSProcessInfo.processInfo.arguments containsObject:@"--local-native-authorization"]) {
        [self prepareNativeDiagnostic:fullStartup app:app];return;
    }
#endif
    [self runNativeGame:fullStartup app:app container:container];
}
#if TOLKARA_INTEGRATED_AUTH
// --local-native-authorization: this iPad's Developer service prepares memory,
// as for a library launch (launchLocalApp). It must be ready and selected
// before ng_initialize, which reads the same argument; the service detaches
// before any application code runs.
- (void)prepareNativeDiagnostic:(BOOL)fullStartup app:(TKApp *)app {
    self.launchingApp=app;
    self.nativeFullStartup=fullStartup;
    self.status.text=[NSString stringWithFormat:@"Preparing %@\nConnecting to the developer service…",app.name ?: @"app"];
    [self.launchProgress start];
    [self.localAuthorization startAndPrepareLocalAuthorization:^(NSString *report) {
        [report writeToFile:TKDocumentsPath(@"local-game-setup.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if(!self.localAuthorization.localSessionReady || !ng_use_local_authorization()) {
            [self refuseNativeGame:@"Developer service could not prepare; see Documents/local-game-setup.txt."];
            self.status.text=[@"Developer service could not prepare. Close and reopen the app to retry.\n" stringByAppendingString:report];
            [self showStartStopped];return;
        }
        // Guest main must enter from a timer callout, never a dispatch block.
        [self performSelector:@selector(startPreparedNativeDiagnostic) withObject:nil afterDelay:0];
    }];
}
- (void)startPreparedNativeDiagnostic { [self runNativeGame:self.nativeFullStartup app:self.launchingApp container:nil]; }
- (void)arenaWillPrepare:(NSNotification *)notification {
    double mib = [notification.userInfo[@"bytes"] unsignedLongLongValue] / (1024.0 * 1024.0);
    self.status.text=[NSString stringWithFormat:@"Preparing %@\nSetting up %.0f MiB of execution memory.\nThis step can take a few minutes. Keep Tolkara open.", self.launchingApp.name ?: @"app", mib];
    [self.launchProgress start];
    [self.status.superview layoutIfNeeded];
}
- (void)arenaDidPrepare:(NSNotification *)notification {
    if ([notification.userInfo[@"prepared"] boolValue] && self.launchingApp)
        self.status.text=[NSString stringWithFormat:@"Loading %@…\nMemory preparation is complete. Starting the app.",self.launchingApp.name ?: @"app"];
    else [self.launchProgress stop];
    [self.status.superview layoutIfNeeded];
}
#endif
// What startup is doing, below the elapsed time, until the app's own window
// is on screen: application code may hold the main thread meanwhile.
- (void)startStartupActivityInFolder:(NSString *)folder {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    [self.startupActivity startInFolder:folder step:^NSString *(NSTimeInterval *seconds) {
        NGStartupStep now=ng_startup_step();
        if (now.step) *seconds=(double)(mach_absolute_time()-now.since)*timebase.numer/timebase.denom/1e9;
        return TKStartupStepText(now.step,now.done,now.total);
    }];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowBecameVisible:)
                                               name:UIWindowDidBecomeVisibleNotification object:nil];
}
- (void)windowBecameVisible:(NSNotification *)notification {
    UIWindow *window=notification.object;
    if (window!=self.window && window.windowLevel==UIWindowLevelNormal) [self stopStartupActivity];
}
- (void)stopStartupActivity {
    [self.startupActivity stop];
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIWindowDidBecomeVisibleNotification object:nil];
}
// container: Local signing's validated page container, or nil for the
// Developer-service/debugger path. Callers choose it; this only applies it.
- (void)resumeCloudPreparedNativeGame { [self runNativeGame:self.cloudFullStartup app:self.cloudApp container:self.cloudContainer]; }
- (void)runNativeGame:(BOOL)fullStartup app:(TKApp *)app container:(NSString *)container {
    if (!self.cloudPrepared && [TKSteamCloudCoordinator configuredProfile:app.profile documents:TKDocumentsPath(@"")]) {
        if(self.cloudPreparing)return;self.cloudPreparing=YES;
        self.cloudFullStartup=fullStartup;self.cloudApp=app;self.cloudContainer=container;
        self.steamCloud=[[TKSteamCloudCoordinator alloc] initWithProfile:app.profile documents:TKDocumentsPath(@"")];
        self.status.text=@"Synchronizing Steam Cloud saves…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSError *error=nil;NSString *report=nil;BOOL ready=[self.steamCloud prepareWithReport:&report error:&error];
            dispatch_async(dispatch_get_main_queue(),^{
                self.cloudPreparing=NO;
                if(!ready) { self.status.text=report?:[NSString stringWithFormat:@"Steam Cloud sync failed (%@:%ld). Saves preserved. See SteamCloud/%@/sync.log.",error.domain,(long)error.code,app.profile];[self showStartStopped];return; }
                self.cloudPrepared=YES;[self.steamCloud startPeriodicSync];
                ng_set_exit_observer(FlushSteamCloudAtExit,(__bridge void *)self.steamCloud);
                // The guest enters from a timer callout, after this dispatch block returns.
                [self performSelector:@selector(resumeCloudPreparedNativeGame) withObject:nil afterDelay:0];
            });
        });return;
    }
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSString *logPath = TKDocumentsPath(@"native-guest.log");
    FILE *log = fopen(logPath.fileSystemRepresentation, "w");
    if (!log) { self.status.text = @"Cannot open native runtime log."; [self showStartStopped]; return; }
    // Line-buffered: an early return must not leave its message stuck in the buffer.
    setvbuf(log, NULL, _IOLBF, 0);
    dup2(fileno(log), STDERR_FILENO);
    dup2(fileno(log), STDOUT_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (NSString *argument in arguments) if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log,"%s\n",argument.UTF8String);
    fprintf(log,"[host] execution mode=%s source=%s\n",ModeIdentifier(self.executionMode),self.executionModeSource.UTF8String);
    NSString *map = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/libraries.json"];
    NSError *error=nil;
    NSString *path=app ? [self.library executablePathForApp:app error:&error] : nil;
    // The application finds its resources relative to its working directory.
    NSString *directory=path ? [self.library workingDirectoryForApp:app error:&error] : nil;
    if (!directory) {
        self.status.text=app ? error.localizedDescription : @"Import an app into the library before running the development loader.";
        fprintf(log,"[host] %s\n",self.status.text.UTF8String);
        [self showStartStopped];
        return;
    }
    fprintf(log,"[host] app=%s sha256=%s\n",app.name.UTF8String,app.sha256.UTF8String);
    [self startStartupActivityInFolder:directory];
    if (chdir(directory.fileSystemRepresentation)) fprintf(log,"[host] app working directory failed: %s\n",strerror(errno));
    else fprintf(log,"[host] app working directory=%s\n",directory.fileSystemRepresentation);
    // A profile's caseAliases: folders the application names in another case
    // than its installer wrote them, which only macOS's file system ignores.
    for (NSString *line in [self.library linkCaseAliasesForApp:app]) fprintf(log,"[host] %s\n",line.UTF8String);
    // A profile's command line for a compatibility runtime (data from the
    // profile; nothing here changes the application). `${Documents}` in a
    // variable's value stands for the absolute Documents folder.
    NSString *documents=TKDocumentsPath(@"");
    NSMutableDictionary<NSString *, NSString *> *environment=[app.environment mutableCopy];
    for (NSString *argument in arguments) if ([argument hasPrefix:@"--guest-environment="]) {
        // Development launches may set a variable over the profile's (NAME=value).
        NSString *setting=[argument substringFromIndex:20];
        NSUInteger equals=[setting rangeOfString:@"="].location;
        if (equals!=NSNotFound && equals>0) environment[[setting substringToIndex:equals]]=[setting substringFromIndex:equals+1];
    }
    for (NSString *name in [environment.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value=[environment[name] stringByReplacingOccurrencesOfString:@"${Documents}" withString:documents];
        setenv(name.UTF8String,value.UTF8String,1);
        fprintf(log,"[host] environment %s=%s\n",name.UTF8String,TKHomeDisplayPath(value,NSHomeDirectory()).UTF8String);
    }
    NSMutableArray<NSString *> *launchArguments=[app.arguments mutableCopy];
    for (NSString *argument in arguments) if ([argument hasPrefix:@"--guest-arguments="]) {
        // Development launches may replace the profile's arguments (tab-separated).
        [launchArguments setArray:[[argument substringFromIndex:18] componentsSeparatedByString:@"\t"]];
    }
    const char *argv[64]; size_t argc=0;
    for (NSString *argument in launchArguments) if (argc<64) { argv[argc++]=argument.UTF8String; fprintf(log,"[host] argument %s\n",argument.UTF8String); }
    ng_set_arguments(argv,argc);
    // A profile's runtime libraries (opened by path, not linked) are placed with it.
    if (app.runtime) {
        NSString *runtime=TKDocumentsPath(app.runtime);
        NSMutableArray<NSString *> *paths=[NSMutableArray new];
        const char *libraries[64]; size_t count=0;
        for (NSString *library in app.libraries) if (count<64) {
            [paths addObject:[runtime stringByAppendingPathComponent:library]];
            libraries[count++]=paths.lastObject.fileSystemRepresentation;
            fprintf(log,"[host] library %s\n",library.UTF8String);
        }
        ng_set_libraries(runtime.fileSystemRepresentation,libraries,count);
        if (app.codePool) {
            ng_set_code_pool((size_t)app.codePool<<20);
            fprintf(log,"[host] code pool %lu MB\n",(unsigned long)app.codePool);
        }
    }
    // Local signing: the runtime validates the container against this
    // executable and refuses it after Developer service was selected.
    if (container) {
        NSString *shown=TKHomeDisplayPath(container,NSHomeDirectory());
        char reason[256]={0};
        if(!ng_use_signed_image(container.fileSystemRepresentation,reason,sizeof reason)) {
            fprintf(log,"[host] signed-image rejected: %s (container=%s)\n",reason[0]?reason:"backend unavailable",shown.UTF8String); fflush(log);
            // One startup attempt per process, as for Developer service.
            NSString *retry=@"Close and reopen the app to retry.";
            if(self.sessionUsed) retry=@"Close and reopen the app to retry or to change the execution mode.";
            self.status.text=[NSString stringWithFormat:@"Local signing could not start: %s\n%@",reason[0]?reason:"see runtime log",retry];
            [self showStartStopped];
            return;
        }
        fprintf(log,"[host] signed-image container=%s\n",shown.UTF8String); fflush(log);
    }
    BOOL ok = ng_initialize(path.fileSystemRepresentation, NSBundle.mainBundle.privateFrameworksPath.fileSystemRepresentation, map.fileSystemRepresentation, log, fullStartup);
    // The outcome as the host saw it (tools/run.sh requires "returned").
    fprintf(log,"[host] native %s %s\n",fullStartup?"startup":"first initializer",ok?"returned":"stopped"); fflush(log);
    self.status.text = ok ? (fullStartup ? [app.name stringByAppendingString:@" closed."] : @"Original client first initializer returned.") : @"Native startup stopped. See runtime log.";
    [self showStartStopped];
    // A cleanly closed game was the whole session in a library launch. End the
    // process after a short note: the next tap on Tolkara opens the library
    // ready to start another app (one guest startup per process).
    if (ok && fullStartup && self.uiSession) {
        [self.steamCloud flush];
        fprintf(log,"[host] %s closed; ending this session\n",app.name.UTF8String); fflush(log);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ exit(0); });
    }
    // Runtime callbacks retain this log for the life of the guest.
}

#pragma mark Development runs (launch arguments)

- (void)startGuest {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if([arguments containsObject:@"--local-shader-probe"]) {
        self.status.text=@"Testing the local shader compiler…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKLocalShaderProbeReport();
            dispatch_async(dispatch_get_main_queue(),^{self.status.text=report;});
        });
        return;
    }
    if([arguments containsObject:@"--captured-shader-probe"]) {
        self.status.text=@"Compiling the captured shader libraries on this iPad…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKCapturedShaderProbeReport();
            dispatch_async(dispatch_get_main_queue(),^{self.status.text=report;});
        });
        return;
    }
    // Tolkara Management (the Mac app) removes an application's files from
    // Documents; the result goes to Documents/management-result.txt.
    NSUInteger removal=[arguments indexOfObject:@"--remove-app-folder"];
    if(removal!=NSNotFound) {
        NSString *result=@"Not removed: --remove-app-folder needs a folder.";
        if(removal+1<arguments.count) {
            NSError *error=nil;
            NSArray<NSString *> *names=[self.library removeApplicationFolder:arguments[removal+1] error:&error];
            result=names ? [NSString stringWithFormat:@"Removed %@ (%@).",arguments[removal+1],[names componentsJoinedByString:@", "]]
                : [@"Not removed: " stringByAppendingString:error.localizedDescription];
        }
        self.status.text=result;
        [result writeToFile:TKDocumentsPath(@"management-result.txt") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
#if TOLKARA_INTEGRATED_AUTH
    if([arguments containsObject:@"--prepare-authorization-import"]) {
        self.status.text=[TKEnrollmentImport prepare]?@"Protected enrollment handoff directory ready.":@"Enrollment handoff directory unavailable.";
        return;
    }
    if([arguments containsObject:@"--import-authorization-enrollment"]) {
        NSUInteger device=[arguments indexOfObject:@"--expected-device"];
        NSUInteger fingerprint=[arguments indexOfObject:@"--expected-enrollment-fingerprint"];
        NSString *result=@"Enrollment import arguments missing.";
        if(device!=NSNotFound && device+1<arguments.count && fingerprint!=NSNotFound && fingerprint+1<arguments.count)
            result=[TKEnrollmentImport importPendingWithDevice:arguments[device+1] fingerprint:arguments[fingerprint+1]];
        self.status.text=result;
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/authorization-import-result.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    if([arguments containsObject:@"--native-retry-probe"]) {
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-retry-probe.txt"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open retry probe log.";return; }
        NSString *absent=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        BOOL first=ng_initialize(absent.fileSystemRepresentation,"","",log,false);
        BOOL second=ng_initialize(absent.fileSystemRepresentation,"","",log,false);
        BOOL passed=!first && !second && [NSProcessInfo.processInfo.arguments containsObject:@"--native-retry-probe"];
        fprintf(log,"Native retry guard %s; no guest executable loaded or run.\n",passed?"PASS":"FAIL");
        fclose(log);self.status.text=passed?@"Native retry guard passed; no game code executed.":@"Native retry guard failed.";
        return;
    }
    if([arguments containsObject:@"--local-connected-arena-probe"] || [arguments containsObject:@"--local-execution-probe"]) {
        BOOL executeProbe=[arguments containsObject:@"--local-execution-probe"];

        self.status.text=@"Preparing the authenticated local debugger…";
        [self.localAuthorization startAndPrepareLocalAuthorization:^(NSString *setup) {
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:executeProbe?@"Documents/local-execution-probe.txt":@"Documents/local-connected-arena-probe.txt"];
            [setup writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            // Run outside the main queue: the target can be paused by its helper
            // while UIKit and provider IPC still need normal run-loop servicing.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                static NativeCodeMemory memory,quarantine;
                BOOL prepared=nc_create_managed(&memory,16384,TKPrepareLocalArena,NULL,&quarantine);
                NSString *outcome=prepared?@"Prepared and detached; no code executed.":
                    quarantine.quarantined?@"Preparation uncertain; memory retained, guest entry blocked, restart required.":
                    @"Preparation rejected; guest entry blocked.";
                if(prepared && executeProbe) {
                    // Our own two-instruction fixture: mov w0,#42; ret. No
                    // proprietary module is loaded, modified, signed or run.
                    const uint32_t fixture[]={0x52800540,0xd65f03c0};
                    if(nc_write(&memory,0,fixture,sizeof fixture)) {
                        [[setup stringByAppendingString:@"\nPrepared and detached; executing our return-42 fixture…"]
                            writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        int answer=((int (*)(void))memory.executable)();
                        outcome=answer==42?@"PASS: locally prepared memory executed our return-42 function after confirmed detach.":@"FAIL: fixture returned an unexpected value.";
                    } else outcome=@"FAIL: prepared memory could not receive our fixture.";
                }
                nc_destroy(&memory);
                NSString *result=[setup stringByAppendingFormat:@"\n%@",outcome];
                [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_main_queue(),^{self.status.text=result;});
            });
        }];
        return;
    }
    if([arguments containsObject:@"--local-arena-probe"]) {
        self.status.text=@"Checking local memory preparation…";
        static NativeCodeMemory memory,quarantine;
        BOOL prepared=nc_create_managed(&memory,16384,TKPrepareLocalArena,NULL,&quarantine);
        NSString *result=prepared?@"Prepared and detached; no code executed.":
            quarantine.quarantined?@"Preparation uncertain; memory retained, guest entry blocked, restart required.":
            @"Preparation rejected; memory released, guest entry blocked. Local authorization is not configured.";
        nc_destroy(&memory);
        self.status.text=result;
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-arena-probe.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    if([arguments containsObject:@"--start-local-route-probe"]) {
        self.status.text=@"Starting the approved local route…";
        [self.localAuthorization startAndProbeLocalRoute:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/start-local-route-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-pairing-probe"]) {
        self.status.text=@"Verifying the enrolled local identity…";
        [self.localAuthorization startAndVerifyPairing:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-pairing-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-tunnel-probe"]) {
        self.status.text=@"Verifying the encrypted local developer tunnel…";
        [self.localAuthorization startAndVerifyTunnel:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-tunnel-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-route-service-probe"]) {
        [TKLocalAuthorization probeLocalRouteService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-route-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--remote-pairing-service-probe"]) {
        [TKLocalAuthorization probeRemotePairingService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/remote-pairing-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--direct-service-probe"]) {
        [TKLocalAuthorization probeDirectService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/direct-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--direct-authorization-probe"]) {
        [TKLocalAuthorization probeDirectAccess:^(NSString *result) {
            self.status.text=result;
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/direct-authorization-probe.txt"];
            [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            fprintf(stderr,"[local-authorization] %s\n",result.UTF8String);
        }];
        return;
    }
#endif
    // Experimental development probe: what iPadOS lets this app reserve.
    if ([arguments containsObject:@"--vm-probe"]) {
        self.status.text=@"Probing virtual-memory reservations…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKVMProbeReport();
            dispatch_async(dispatch_get_main_queue(),^{ self.status.text=report; });
        });
        return;
    }
    if ([arguments containsObject:@"--sparse-memory-probe"]) {
        self.status.text=@"Testing software address space with our own code…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKSparseMemoryProbeReport();
            dispatch_async(dispatch_get_main_queue(),^{ self.status.text=report; });
        });
        return;
    }
    if ([arguments containsObject:@"--cpu-probe"]) {
        self.status.text=@"Measuring execution through the signed runtime…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKCPUProbeReport();
            dispatch_async(dispatch_get_main_queue(),^{ self.status.text=report; });
        });
        return;
    }
    NSString *signedFilePath=nil, *signedFileMode=@"exec";
    unsigned signedFileExpect=0x12345678; BOOL signedFileExpectBad=NO;
    for (NSString *argument in arguments) {
        if ([argument hasPrefix:@"--signed-file-probe="]) signedFilePath=[argument substringFromIndex:20];
        if ([argument hasPrefix:@"--signed-file-probe-mode="]) signedFileMode=[argument substringFromIndex:25];
        if ([argument hasPrefix:@"--signed-file-probe-expect="]) {
            // Strict: reject garbage and values above UINT32_MAX instead of
            // silently probing against a wrong (or 0) expected value. Require a
            // leading digit: strtoul otherwise silently accepts a sign or
            // leading whitespace ('+5', '-0', ' 5'). A leading '0' still admits
            // hex 0x...; the errno/end/UINT32_MAX checks stay.
            const char *text=[argument substringFromIndex:27].UTF8String; char *end=NULL;
            errno=0; unsigned long parsed=strtoul(text,&end,0);
            if(text[0]>='0'&&text[0]<='9' && !*end && !errno && parsed<=UINT32_MAX) signedFileExpect=(unsigned)parsed;
            else signedFileExpectBad=YES;
        }
    }
    if(signedFilePath) {
        if(signedFileExpectBad) { self.status.text=@"--signed-file-probe-expect must be an integer in [0, 0xFFFFFFFF]."; return; }
        if(![signedFilePath isAbsolutePath]) signedFilePath=[NSHomeDirectory() stringByAppendingPathComponent:signedFilePath];
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/signed-file-probe.log"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open signed-file probe log.";return; }
        for (NSString *argument in arguments) if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log,"%s\n",argument.UTF8String);
        BOOL ok=HostSignedFileProbe(signedFilePath.fileSystemRepresentation,signedFileMode.UTF8String,signedFileExpect,log);
        fclose(log);
        self.status.text=ok?@"Signed file-mapped code executed natively.":@"Signed file probe failed. See probe log.";
        return;
    }
    for(NSString *argument in arguments) if([argument hasPrefix:@"--steam-cloud-sync="]) {
        NSString *profile=[argument substringFromIndex:19];
        self.steamCloud=[[TKSteamCloudCoordinator alloc] initWithProfile:profile documents:TKDocumentsPath(@"")];
        self.status.text=@"Synchronizing Steam Cloud saves…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSError *error=nil;NSString *report=nil;BOOL ready=[self.steamCloud prepareWithReport:&report error:&error];
            dispatch_async(dispatch_get_main_queue(),^{self.status.text=ready?report:(report?:[NSString stringWithFormat:@"Steam Cloud sync failed (%@:%ld). Saves preserved.",error.domain,(long)error.code]);});
        });return;
    }
    if([arguments containsObject:@"--signed-cache-probe"]) { self.status.text=TKSignedCacheProbeReport();return; }
    if([arguments containsObject:@"--shader-pause-probe"]) { self.status.text=TKShaderPauseProbeReport();return; }
    for (NSString *mode in @[@"wx",@"dual",@"rwx"]) if ([arguments containsObject:[@"--execution-probe=" stringByAppendingString:mode]]) {
        HPMode probe=[mode isEqual:@"dual"] ? HP_DUAL_MAPPING : [mode isEqual:@"rwx"] ? HP_READ_WRITE_EXECUTE : HP_WRITE_THEN_EXECUTE;
        self.status.text=TKExecutionProbeReport(probe,arguments);
        return;
    }
#if TOLKARA_INTEGRATED_AUTH
    if([arguments containsObject:@"--local-game-startup"]) {
        // Always Developer service: it replaces a saved choice or preselection
        // (logged); an unusable or contradicting --execution-mode and any
        // --signed-image are refused.
        if([self refuseInvalidModeArgument] || ![self forceExecutionMode:TKExecutionModeDeveloperService by:@"--local-game-startup"]) return;
        NSString *problem=nil;
        if(TKSignedImagePath(arguments,NSHomeDirectory(),&problem) || problem) {
            [self refuseNativeGame:@"--signed-image is a Local signing container, but --local-game-startup always uses Developer service. Pass only one of them."];
            return;
        }
        [self launchLocalApp:[self appFromArguments]];return;
    }
#endif
    if ([arguments containsObject:@"--native-initializer"] || [arguments containsObject:@"--native-startup"]) {
        [self startNativeDiagnostic:[arguments containsObject:@"--native-startup"]];return;
    }
    NSString *runtime = [NSBundle.mainBundle objectForInfoDictionaryKey:@"TolkaraGuestRuntime"];
    if ([runtime isEqualToString:@"emulated"]) {
        BOOL importFromArguments=!self.consumedImportArgument;
        self.consumedImportArgument=YES;
        TKAppLibrary *library=self.library;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error=nil;
            TKApp *app=nil;
            // Simulator/developer staging is separate from the installed app:
            // keep a copy, as the file is replaced by the next staging run.
            if (importFromArguments) for (NSString *argument in arguments) if ([argument hasPrefix:@"--import-module="]) {
                NSString *source=[argument substringFromIndex:16];
                if (!source.isAbsolutePath) source=[NSHomeDirectory() stringByAppendingPathComponent:source];
                app=[library importExecutable:source copy:YES error:&error];
            }
            if (!app && !error) app=library.defaultApp;
            NSString *path=app ? [library executablePathForApp:app error:&error] : nil;
            NSString *message=TKLoaderCheck(path,error.localizedDescription?:@"Import an app into the library to begin.");
            dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = message; });
        });
        return;
    }
    self.status.text = @"Unknown guest runtime configuration.";
}
@end

@interface AKHostAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AKHostAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = AKHostSceneDelegate.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AKHostAppDelegate.class)); }
}
