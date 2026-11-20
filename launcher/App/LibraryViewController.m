#import "LibraryViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "GameDownload.h"

@interface TKLibraryViewController () <UIDocumentPickerDelegate>
@end

// The AppKit adapter's AKTouchControlsDefaultsKey (translation/AppKit/TouchControls.h):
// the adapter loads with a game, so the launcher names the setting itself.
static NSString *const TKTouchControlsKey=@"AKTouchControls";
static BOOL TKTouchControlsShown(void) {
    NSNumber *saved=[NSUserDefaults.standardUserDefaults objectForKey:TKTouchControlsKey];
    return [saved isKindOfClass:NSNumber.class] ? saved.boolValue : UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPhone;
}

// AKPointerAccelerationDefaultsKey and AKPointerSpeedDefaultsKey, likewise.
static NSString *const TKPointerAccelerationKey=@"AKPointerAcceleration";
static NSString *const TKPointerSpeedKey=@"AKPointerSpeed";
static BOOL TKPointerAccelerated(void) {
    NSNumber *saved=[NSUserDefaults.standardUserDefaults objectForKey:TKPointerAccelerationKey];
    return ![saved isKindOfClass:NSNumber.class] || saved.boolValue;
}
static double TKPointerSpeed(void) {
    NSNumber *saved=[NSUserDefaults.standardUserDefaults objectForKey:TKPointerSpeedKey];
    return [saved isKindOfClass:NSNumber.class] ? saved.doubleValue : 1;
}

@implementation TKLibraryViewController {
    TKAppLibrary *_library;
    NSArray<TKApp *> *_apps;
    dispatch_queue_t _queue;
    BOOL _discovered, _importing;
    UIBarButtonItem *_addItem, *_controlsItem;
    // The experimental download in progress, its alert and the bar in it.
    TKGameDownload *_download;
    UIAlertController *_downloadAlert;
    UIProgressView *_downloadBar;
    // Blizzard games whose installed build is older than the version
    // server's current one, by app identifier: {profile, region, locale,
    // installed, current}. Checked at each refresh.
    NSDictionary<NSString *, NSDictionary *> *_updates;
    BOOL _checkingUpdates, _updating;
    // The build each such game has installed (.build.info), by app
    // identifier, read from the device alone and shown on its row.
    NSDictionary<NSString *, NSString *> *_builds;
}

- (instancetype)initWithLibrary:(TKAppLibrary *)library {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _library=library; _apps=library.apps;
    _queue=dispatch_queue_create("tolkara.library",DISPATCH_QUEUE_SERIAL);
    self.title=@"Tolkara";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.prefersLargeTitles=YES;
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"app"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"notice"];
    _addItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importApp)];
    _addItem.accessibilityLabel=@"Add App";
    self.navigationItem.rightBarButtonItem=_addItem;
    UIBarButtonItem *diagnostics=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"stethoscope"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showDiagnostics)];
    diagnostics.accessibilityLabel=@"Diagnostics";
    UIBarButtonItem *mode=[[UIBarButtonItem alloc] initWithTitle:@"Execution Mode"
        style:UIBarButtonItemStylePlain target:self action:@selector(showExecutionMode)];
    _controlsItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"hand.tap"] menu:nil];
    _controlsItem.accessibilityLabel=@"Controls";
    [self updateControlsMenu];
    self.navigationItem.leftBarButtonItems=@[diagnostics,mode,_controlsItem];
    // Files copied in with the Files app or a profile's install script appear
    // when Tolkara returns to the foreground.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh)
        name:UISceneWillEnterForegroundNotification object:nil];
    [self refresh];
}

- (void)refresh {
    dispatch_async(_queue,^{
        [self->_library discover];
        dispatch_async(dispatch_get_main_queue(),^{ self->_discovered=YES; [self reload]; [self checkForUpdates]; });
    });
}
- (void)reload {
    _apps=_library.apps;
    _addItem.enabled=!_importing;
    [self updateAddMenu];
    [self.tableView reloadData];
    [self updateEmptyState];
}
- (void)setNotice:(NSString *)notice { _notice=notice.copy; [self reload]; }
- (NSString *)effectiveNotice { return _notice?:_library.loadWarning; }

- (void)updateEmptyState {
    if (_apps.count) { self.tableView.backgroundView=nil; return; }
    UILabel *label=[UILabel new];
    label.numberOfLines=0;
    label.textAlignment=NSTextAlignmentCenter;
    label.textColor=UIColor.secondaryLabelColor;
    NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:_discovered ? @"No apps yet\n" : @"Looking for apps…\n"
        attributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2],NSForegroundColorAttributeName:UIColor.labelColor}];
    if (_discovered) [text appendAttributedString:[[NSAttributedString alloc] initWithString:
        @"\nCopy a macOS app you own into Tolkara's folder (Files > On My iPad > Tolkara), then tap + and choose its executable or its .app. "
        "It runs from there, next to its files.\n\nAn executable picked from anywhere else is copied into Tolkara on its own."
        attributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]}]];
    label.attributedText=text;
    label.translatesAutoresizingMaskIntoConstraints=NO;
    UIView *background=[UIView new];
    [background addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [label.widthAnchor constraintLessThanOrEqualToConstant:520],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:background.leadingAnchor constant:32],
    ]];
    self.tableView.backgroundView=background;
}

#pragma mark Table

- (BOOL)hasNotice { return self.effectiveNotice.length>0; }
- (BOOL)isNoticeSection:(NSInteger)section { return self.hasNotice && section==0; }
- (TKApp *)appAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isNoticeSection:indexPath.section] || indexPath.row>=(NSInteger)_apps.count) return nil;
    return _apps[(NSUInteger)indexPath.row];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (self.hasNotice ? 1 : 0)+(_apps.count ? 1 : 0);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return [self isNoticeSection:section] ? 1 : (NSInteger)_apps.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return [self isNoticeSection:section] ? nil : @"Apps";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return [self isNoticeSection:section] ? nil : @"Tap an app to start it. Tap ⓘ for details, renaming and removal. Tap + to add another app.";
}
- (NSString *)locationOfApp:(TKApp *)app {
    if (app.source==TKAppSourceCopy) return @"Tolkara's copy of the executable";
    return app.workingDirectory.length ? [@"Documents/" stringByAppendingString:app.workingDirectory] : @"Documents";
}
- (NSString *)lastStartedOfApp:(TKApp *)app {
    if (!app.lastLaunched) return @"Never started";
    NSRelativeDateTimeFormatter *formatter=[NSRelativeDateTimeFormatter new];
    return [@"Started " stringByAppendingString:[formatter localizedStringForDate:app.lastLaunched relativeToDate:NSDate.date]];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isNoticeSection:indexPath.section]) {
        UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"notice" forIndexPath:indexPath];
        UIListContentConfiguration *content=UIListContentConfiguration.cellConfiguration;
        content.text=self.effectiveNotice;
        content.textProperties.color=UIColor.secondaryLabelColor;
        content.image=[UIImage systemImageNamed:@"info.circle"];
        cell.contentConfiguration=content;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
        return cell;
    }
    TKApp *app=[self appAtIndexPath:indexPath];
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"app" forIndexPath:indexPath];
    UIListContentConfiguration *content=UIListContentConfiguration.subtitleCellConfiguration;
    content.text=app.name;
    content.textProperties.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    content.secondaryText=[NSString stringWithFormat:@"%@ · %@",[self locationOfApp:app],[self lastStartedOfApp:app]];
    content.secondaryTextProperties.color=UIColor.secondaryLabelColor;
    // A Blizzard game's installed build always shows; a newer one beside it.
    NSDictionary *update=_updates[app.identifier];
    NSString *build=_builds[app.identifier];
    if (build || update) {
        UIFont *font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:[content.secondaryText stringByAppendingString:@"\n"]
            attributes:@{NSForegroundColorAttributeName:UIColor.secondaryLabelColor}];
        if (build) [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"Build " stringByAppendingString:build]
            attributes:@{NSForegroundColorAttributeName:UIColor.secondaryLabelColor,NSFontAttributeName:font}]];
        if (update) [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@Update available: %@",build ? @" · " : @"",update[@"current"]]
            attributes:@{NSForegroundColorAttributeName:self.view.tintColor,NSFontAttributeName:font}]];
        content.secondaryAttributedText=text;
    }
    content.image=[UIImage systemImageNamed:app.source==TKAppSourceCopy ? @"doc.badge.gearshape" : @"gamecontroller.fill"];
    content.imageProperties.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2];
    content.imageToTextPadding=16;
    content.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(12,0,12,0);
    cell.contentConfiguration=content;
    cell.accessoryType=UITableViewCellAccessoryDetailButton;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    TKApp *app=[self appAtIndexPath:indexPath];
    if (!app) return;
    if (_updates[app.identifier]) [self offerUpdateOfApp:app from:[tableView cellForRowAtIndexPath:indexPath]];
    else [self.delegate libraryViewController:self startApp:app];
}
- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    TKApp *app=[self appAtIndexPath:indexPath];
    if (app) [self showDetailsOfApp:app from:[tableView cellForRowAtIndexPath:indexPath]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    TKApp *app=[self appAtIndexPath:indexPath];
    if (!app) return nil;
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
        handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
            (void)action;
            [self confirmRemovingApp:app from:view];
            completion(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)point;
    TKApp *app=[self appAtIndexPath:indexPath];
    if (!app) return nil;
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        (void)suggested;
        NSMutableArray<UIMenuElement *> *items=[NSMutableArray new];
        if (self->_updates[app.identifier]) [items addObject:[UIAction actionWithTitle:@"Update" image:[UIImage systemImageNamed:@"arrow.down.circle"]
            identifier:nil handler:^(UIAction *a) { (void)a; [self updateApp:app]; }]];
        [items addObjectsFromArray:@[
            [UIAction actionWithTitle:@"Start" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *a) {
                (void)a; [self.delegate libraryViewController:self startApp:app]; }],
            [UIAction actionWithTitle:@"Rename…" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) {
                (void)a; [self renameApp:app]; }],
            [UIAction actionWithTitle:@"Details" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) {
                (void)a; [self showDetailsOfApp:app from:cell]; }],
            [UIAction actionWithTitle:@"Check Loader" image:[UIImage systemImageNamed:@"stethoscope"] identifier:nil handler:^(UIAction *a) {
                (void)a; [self.delegate libraryViewController:self checkApp:app]; }],
            [UIAction actionWithTitle:@"Remove from Library" image:[UIImage systemImageNamed:@"trash"] identifier:nil
                handler:^(UIAction *a) { (void)a; [self confirmRemovingApp:app from:cell]; }],
        ]];
        return [UIMenu menuWithChildren:items];
    }];
}

#pragma mark Actions

- (void)showDiagnostics { [self.delegate libraryViewControllerShowDiagnostics:self]; }
- (void)showExecutionMode { [self.delegate libraryViewControllerShowExecutionMode:self]; }
// Optional movement-stick, touch-trackpad and keyboard buttons over a game, read when it starts.
- (void)updateControlsMenu {
    __weak TKLibraryViewController *weakSelf=self;
    UIAction *toggle=[UIAction actionWithTitle:@"On-Screen Controls" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a;
        [NSUserDefaults.standardUserDefaults setBool:!TKTouchControlsShown() forKey:TKTouchControlsKey];
        [weakSelf updateControlsMenu];
    }];
    toggle.state=TKTouchControlsShown()?UIMenuElementStateOn:UIMenuElementStateOff;
    UIMenu *controls=[UIMenu menuWithTitle:@"Movement stick, touch trackpad and keyboard buttons over the game, from its next start"
        image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[toggle]];
    // Off: a mouse's pointer follows its raw motion at a constant speed, and
    // the touch trackpad's pointer no longer speeds up with the finger.
    UIAction *acceleration=[UIAction actionWithTitle:@"Pointer Acceleration" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a;
        [NSUserDefaults.standardUserDefaults setBool:!TKPointerAccelerated() forKey:TKPointerAccelerationKey];
        [weakSelf updateControlsMenu];
    }];
    acceleration.state=TKPointerAccelerated()?UIMenuElementStateOn:UIMenuElementStateOff;
    NSMutableArray<UIMenuElement *> *pointer=[NSMutableArray arrayWithObject:acceleration];
    if (!TKPointerAccelerated()) {
        NSMutableArray<UIAction *> *speeds=[NSMutableArray new];
        for (NSNumber *speed in @[@0.5,@0.75,@1,@1.5,@2]) {
            UIAction *choice=[UIAction actionWithTitle:[NSString stringWithFormat:@"%@×",speed] image:nil identifier:nil handler:^(UIAction *a) {
                (void)a;
                [NSUserDefaults.standardUserDefaults setDouble:speed.doubleValue forKey:TKPointerSpeedKey];
                [weakSelf updateControlsMenu];
            }];
            choice.state=speed.doubleValue==TKPointerSpeed()?UIMenuElementStateOn:UIMenuElementStateOff;
            [speeds addObject:choice];
        }
        [pointer addObject:[UIMenu menuWithTitle:@"Mouse Pointer Speed" children:speeds]];
    }
    UIMenu *pointerMenu=[UIMenu menuWithTitle:@"Off: a mouse or the touch trackpad moves the pointer at a constant speed, from the game's next start. With a mouse, the game must fill the screen."
        image:nil identifier:nil options:UIMenuOptionsDisplayInline children:pointer];
    _controlsItem.menu=[UIMenu menuWithChildren:@[controls,pointerMenu]];
}

- (void)showDetailsOfApp:(TKApp *)app from:(UIView *)view {
    NSMutableString *message=[NSMutableString new];
    if (app.source==TKAppSourceDocuments) {
        [message appendFormat:@"Executable: Documents/%@\n\nWorking folder: %@",app.executable,[self locationOfApp:app]];
    } else {
        [message appendString:@"Tolkara keeps its own verified copy of this executable. Only the executable was imported."];
    }
    if (app.sha256.length) [message appendFormat:@"\n\nSHA-256 when added:\n%@",app.sha256];
    if (app.profile) [message appendFormat:@"\n\nProfile: %@",app.profile];
    [message appendFormat:@"\n\nAdded %@\n%@",
        [NSDateFormatter localizedStringFromDate:app.added dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle],[self lastStartedOfApp:app]];
    NSDictionary *update=_updates[app.identifier];
    if (update) [message appendFormat:@"\n\nInstalled build: %@\nAvailable: %@",update[@"installed"],update[@"current"]];
    else if (_builds[app.identifier]) [message appendFormat:@"\n\nInstalled build: %@",_builds[app.identifier]];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:app.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
    if (update) [sheet addAction:[UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self updateApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Start" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self.delegate libraryViewController:self startApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self renameApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Check Loader" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self.delegate libraryViewController:self checkApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Remove from Library" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a; [self confirmRemovingApp:app from:view]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=view;
    sheet.popoverPresentationController.sourceRect=view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)renameApp:(TKApp *)app {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Rename App" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text=app.name; field.clearButtonMode=UITextFieldViewModeWhileEditing;
        field.autocapitalizationType=UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSError *error=nil;
        if (![self->_library renameApp:app to:weakAlert.textFields.firstObject.text error:&error]) [self showError:error title:@"Cannot Rename"];
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRemovingApp:(TKApp *)app from:(UIView *)view {
    NSString *message=app.source==TKAppSourceCopy ?
        @"Tolkara's copy of the executable is deleted. You can import it again later." :
        @"Its files stay in Tolkara's Documents folder. You can add it again with +.";
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Remove %@ from the library?",app.name]
        message:message preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a;
        NSError *error=nil;
        if (![self->_library removeApp:app error:&error]) [self showError:error title:@"Cannot Remove"];
        [self reload];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=view;
    sheet.popoverPresentationController.sourceRect=view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// The + button adds an app from Files. With a profile whose application can
// be downloaded and is not here yet, it is a menu that offers that too.
- (void)updateAddMenu {
    NSArray<NSDictionary *> *offers=_library.downloadableProfiles;
    // A bar button with an action shows its menu only on a long press: with
    // something to offer, a tap opens the menu.
    _addItem.action=offers.count ? nil : @selector(importApp);
    if (!offers.count) { _addItem.menu=nil; return; }
    __weak TKLibraryViewController *weakSelf=self;
    NSMutableArray<UIMenuElement *> *items=[NSMutableArray arrayWithObject:
        [UIAction actionWithTitle:@"Add from Files…" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
            (void)a; [weakSelf importApp];
        }]];
    for (NSDictionary *profile in offers) {
        [items addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Download %@… (Experimental)",profile[@"name"]]
            image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(UIAction *a) {
                (void)a; [weakSelf offerDownloadOfProfile:profile];
            }]];
    }
    _addItem.menu=[UIMenu menuWithChildren:items];
}

#pragma mark Download (experimental)

// Development runs (docs/BUILDING.md): --download-profile=<id> starts that
// profile's download as the menu would after its questions, once, when the
// library appears; --download-region=<id> and --download-locale=<locale>
// answer the questions of a download that asks them. For a download with a
// runtime archive, --download-runtime-url=<https address>,
// --download-runtime-sha256= and --download-runtime-size= each replace that
// value of the profile for this launch: an archive that is not published yet.
// --download-root=<folder> puts such a download under another top folder of
// Documents, also when the application is in place: a trial beside it.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL asked;
    if (asked) return;
    asked=YES;
    NSString *wanted=nil, *region=nil, *locale=nil, *root=nil;
    NSMutableDictionary *archive=[NSMutableDictionary new];
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument hasPrefix:@"--download-profile="]) wanted=[argument substringFromIndex:19];
        if ([argument hasPrefix:@"--download-region="]) region=[argument substringFromIndex:18];
        if ([argument hasPrefix:@"--download-locale="]) locale=[argument substringFromIndex:18];
        if ([argument hasPrefix:@"--download-root="]) root=[argument substringFromIndex:16];
        if ([argument hasPrefix:@"--download-runtime-url="]) archive[@"url"]=[argument substringFromIndex:23];
        if ([argument hasPrefix:@"--download-runtime-sha256="]) archive[@"sha256"]=[argument substringFromIndex:26];
        if ([argument hasPrefix:@"--download-runtime-size="]) archive[@"size"]=@(strtoull([argument substringFromIndex:24].UTF8String,NULL,10));
    }
    if (!wanted) return;
    for (NSDictionary *profile in root ? _library.downloadProfiles : _library.downloadableProfiles) {
        if (![profile[@"id"] isEqual:wanted]) continue;
        NSString *top=profile[@"download"][@"root"];
        if (root && (![top isKindOfClass:NSString.class] || !root.length || [root containsString:@"/"] || [root hasPrefix:@"."] || [root isEqual:top])) continue;
        BOOL asks=[TKGameDownload regionsOfConfiguration:profile[@"download"]].count>0;
        if (asks && (!region || !locale)) continue;
        NSMutableDictionary *changed=[profile mutableCopy];
        if (archive.count && [profile[@"download"][@"runtime"] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *block=[profile[@"download"] mutableCopy], *runtime=[block[@"runtime"] mutableCopy];
            [runtime addEntriesFromDictionary:archive];
            block[@"runtime"]=runtime; changed[@"download"]=block;
        }
        if (root) {
            // The profile's folders are inside its top folder (the downloader checks that).
            NSMutableDictionary *block=[changed[@"download"] mutableCopy];
            block[@"root"]=root; changed[@"download"]=block;
            for (NSString *key in @[@"runtime",@"workingDirectory"]) {
                NSString *path=profile[key];
                if ([path hasPrefix:[top stringByAppendingString:@"/"]]) changed[key]=[root stringByAppendingString:[path substringFromIndex:top.length]];
            }
        }
        // Values the downloader does not accept start nothing.
        [self downloadProfile:changed region:asks ? region : nil locale:asks ? locale : nil];
    }
}

// What is fetched and from whom, with the profile's own notice about the
// application; then the region and language the game is set up for, when
// the download asks for them.
- (void)offerDownloadOfProfile:(NSDictionary *)profile {
    BOOL steam=[profile[@"download"][@"service"] isEqual:@"steam"];
    NSString *risk=[profile[@"setup"] isKindOfClass:NSDictionary.class] && [profile[@"setup"][@"risk"] isKindOfClass:NSDictionary.class]
        ? profile[@"setup"][@"risk"][@"summary"] : nil;
    NSMutableString *message=[NSMutableString stringWithFormat:@"Tolkara fetches %@'s own application from its publisher's servers, into Tolkara's folder on this device. "
        @"Tolkara does not host or change it. The game then downloads its data itself when it first starts, which can be tens of gigabytes: "
        @"use Wi-Fi and keep Tolkara open.\n\nThis is experimental.",profile[@"name"]];
    if (steam) message=[@"Steam is Valve's. Tolkara fetches it from Valve's public update server, into Tolkara's folder on this device, "
        @"and checks each file against Valve's own list. The Windows runtime Steam runs in (Wine and FEX, both open source) comes from Tolkara's release page. "
        @"Nothing of Steam is hosted by Tolkara or included in it. You sign in inside Steam.\n\n"
        @"About 2 GB of free space is needed: use Wi-Fi and keep Tolkara open.\n\nThis is experimental." mutableCopy];
    if ([risk isKindOfClass:NSString.class] && risk.length) [message appendFormat:@"\n\n%@",risk];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Download %@?",profile[@"name"]]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        if ([TKGameDownload regionsOfConfiguration:profile[@"download"]].count) [self chooseRegionForProfile:profile];
        else [self downloadProfile:profile region:nil locale:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseRegionForProfile:(NSDictionary *)profile {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Region" message:@"The region your account plays in."
        preferredStyle:UIAlertControllerStyleAlert];
    for (NSDictionary<NSString *,NSString *> *region in [TKGameDownload regionsOfConfiguration:profile[@"download"]]) {
        [alert addAction:[UIAlertAction actionWithTitle:region[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a; [self chooseLanguageForProfile:profile region:region[@"id"]];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseLanguageForProfile:(NSDictionary *)profile region:(NSString *)region {
    NSArray<NSString *> *locales=[TKGameDownload localesOfConfiguration:profile[@"download"]];
    if (locales.count==1) { [self downloadProfile:profile region:region locale:locales[0]]; return; }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Language" message:@"The game's text and speech."
        preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *locale in locales) {
        // "enUS" as "English (United States)", in the device's language.
        NSString *identifier=[NSString stringWithFormat:@"%@_%@",[locale substringToIndex:2],[locale substringFromIndex:2]];
        NSString *name=[NSLocale.currentLocale localizedStringForLocaleIdentifier:identifier]?:locale;
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a; [self downloadProfile:profile region:region locale:locale];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)downloadProfile:(NSDictionary *)profile region:(NSString *)region locale:(NSString *)locale {
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    // Room for the application; a game's own data needs far more and says so
    // itself. Steam comes with its Windows runtime, as an archive and unpacked.
    unsigned long long needed=[profile[@"download"][@"service"] isEqual:@"steam"] ? 3 : 1;
    NSNumber *room=[[NSURL fileURLWithPath:documents] resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:NULL][NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (room && room.unsignedLongLongValue<(needed<<30)) {
        [self showError:[NSError errorWithDomain:TKGameDownloadErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"There is less than %llu GB free on this device.",needed]}] title:@"Cannot Download"];
        return;
    }
    TKGameDownload *download=[[TKGameDownload alloc] initWithConfiguration:profile[@"download"] documents:documents
        workingDirectory:profile[@"workingDirectory"] runtime:profile[@"runtime"] region:region locale:locale];
    if (!download || _download) return;
    _download=download;
    _downloadAlert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:_updating ? @"Updating %@" : @"Downloading %@",profile[@"name"]]
        message:@"Starting…\n\n" preferredStyle:UIAlertControllerStyleAlert];
    [_downloadAlert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        (void)a; [download cancel];
    }]];
    _downloadBar=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _downloadBar.translatesAutoresizingMaskIntoConstraints=NO;
    [_downloadAlert.view addSubview:_downloadBar];
    [NSLayoutConstraint activateConstraints:@[
        [_downloadBar.leadingAnchor constraintEqualToAnchor:_downloadAlert.view.leadingAnchor constant:20],
        [_downloadBar.trailingAnchor constraintEqualToAnchor:_downloadAlert.view.trailingAnchor constant:-20],
        [_downloadBar.bottomAnchor constraintEqualToAnchor:_downloadAlert.view.bottomAnchor constant:-64]]];
    [self presentViewController:_downloadAlert animated:YES completion:nil];
    __weak TKLibraryViewController *weakSelf=self;
    download.progress=^(NSString *phase,double fraction) {
        dispatch_async(dispatch_get_main_queue(),^{
            TKLibraryViewController *controller=weakSelf;
            if (!controller || controller->_download!=download) return;
            controller->_downloadAlert.message=[phase stringByAppendingString:@"\n\n"];
            controller->_downloadBar.progress=(float)fraction;
        });
    };
    // A long download: the screen stays on, as it does while a game runs.
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil;
        BOOL done=[download run:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            UIApplication.sharedApplication.idleTimerDisabled=NO;
            UIAlertController *alert=self->_downloadAlert;
            self->_download=nil; self->_downloadAlert=nil; self->_downloadBar=nil;
            BOOL updating=self->_updating;
            self->_updating=NO;
            if (done && updating) self->_updates=nil;
            BOOL stopped=[error.domain isEqual:NSCocoaErrorDomain] && error.code==NSUserCancelledError;
            void (^after)(void)=^{
                if (done) [self addDownloadedProfile:profile updated:updating];
                else { [self refresh]; if (!stopped) [self showError:error title:updating ? @"Update Failed" : @"Download Failed"]; }
            };
            if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:after]; else after();
        });
    });
}

// The downloaded application goes into the library at once, also when its
// profile was removed from the library before, and the user is told under
// which name: an entry that already pointed at this folder is the one.
- (void)addDownloadedProfile:(NSDictionary *)profile updated:(BOOL)updated {
    NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
        stringByAppendingPathComponent:[TKAppLibrary executableOfProfile:profile]];
    _importing=YES;
    [self reload];
    dispatch_async(_queue,^{
        NSError *error=nil;
        TKApp *app=[self->_library importExecutable:path copy:NO error:&error];
        [self->_library discover];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_importing=NO;
            [self reload];
            if (!app) { [self showError:error title:@"Downloaded, but Not Added"]; return; }
            NSUInteger row=[self->_apps indexOfObjectPassingTest:^BOOL(TKApp *item, NSUInteger index, BOOL *stop) {
                (void)index; (void)stop; return [item.identifier isEqual:app.identifier]; }];
            if (row!=NSNotFound)
                [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:self.hasNotice ? 1 : 0]
                    animated:YES scrollPosition:UITableViewScrollPositionMiddle];
            [self checkForUpdates];
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:updated ? @"%@ Is Updated" : @"%@ Is in Your Library",app.name]
                message:updated ? @"Tap it to start. The game downloads the new build's data when it starts and shows its progress; keep Tolkara open until it is done."
                : [profile[@"download"][@"service"] isEqual:@"steam"]
                    ? @"Tap it to start. Steam finishes its own installation at the first start, then asks you to sign in."
                    : @"Tap it to start. The game downloads its data when it first starts and shows its progress; keep Tolkara open until it is done."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

#pragma mark Updates

// A Blizzard game's own download block, when the app came from its profile.
- (NSDictionary *)blizzardProfileOfApp:(TKApp *)app {
    if (!app.profile || app.source!=TKAppSourceDocuments) return nil;
    for (NSDictionary *profile in _library.downloadProfiles)
        if ([profile[@"id"] isEqual:app.profile] && [profile[@"download"][@"service"] isEqual:@"blizzard"]) return profile;
    return nil;
}
// Compares each such game's installed build (its .build.info) with the build
// Blizzard's version server offers now for the same region. Only the version
// list is asked for; nothing is downloaded or changed. A game copied from a
// Mac is checked too: an update then fetches the changed application files.
- (void)checkForUpdates {
    if (_checkingUpdates || _download) return;
    NSMutableArray<NSArray *> *candidates=[NSMutableArray new];
    for (TKApp *app in _apps) {
        NSDictionary *profile=[self blizzardProfileOfApp:app];
        if (profile) [candidates addObject:@[app.identifier,profile]];
    }
    if (!candidates.count) { _updates=nil; _builds=nil; return; }
    _checkingUpdates=YES;
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        // The installed builds first, from the device alone: they show at once,
        // offline too, before the version server answers.
        NSMutableDictionary<NSString *,NSString *> *builds=[NSMutableDictionary new];
        for (NSArray *candidate in candidates) {
            NSString *version=[TKGameDownload installedBuildOfConfiguration:candidate[1][@"download"] documents:documents][@"version"];
            if (version.length) builds[candidate[0]]=version;
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if ([self->_builds isEqual:builds]) return;
            self->_builds=builds;
            [self.tableView reloadData];
        });
        NSMutableDictionary<NSString *,NSDictionary *> *found=[NSMutableDictionary new];
        for (NSArray *candidate in candidates) {
            NSDictionary *profile=candidate[1], *block=profile[@"download"];
            NSDictionary *installed=[TKGameDownload installedBuildOfConfiguration:block documents:documents];
            if (!installed) continue;
            NSString *locale=[TKGameDownload installedLocaleOfConfiguration:block documents:documents workingDirectory:profile[@"workingDirectory"]]
                ?: [TKGameDownload localesOfConfiguration:block].firstObject;
            TKGameDownload *check=[[TKGameDownload alloc] initWithConfiguration:block documents:documents
                workingDirectory:profile[@"workingDirectory"] runtime:nil region:installed[@"region"] locale:locale];
            NSDictionary *current=[check currentBuild:NULL];
            if (!current || [current[@"build"] isEqual:installed[@"build"]]) continue;
            found[candidate[0]]=@{@"profile":profile,@"region":installed[@"region"],@"locale":locale,
                                  @"installed":[installed[@"version"] length] ? installed[@"version"] : @"unknown",@"current":current[@"version"]};
        }
        dispatch_async(dispatch_get_main_queue(),^{
            self->_checkingUpdates=NO;
            if (self->_download) return;
            self->_updates=found;
            [self.tableView reloadData];
        });
    });
}
- (void)offerUpdateOfApp:(TKApp *)app from:(UIView *)view {
    NSDictionary *update=_updates[app.identifier];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Update %@?",app.name]
        message:[NSString stringWithFormat:@"Build %@ is out; this copy is %@. An online game usually refuses an older build.\n\n"
            "Tolkara fetches only the application files that changed, from Blizzard's servers, and keeps your settings. "
            "The game then downloads the new build's data when it starts.",update[@"current"],update[@"installed"]]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self updateApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Start Without Updating" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self.delegate libraryViewController:self startApp:app]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=view;
    sheet.popoverPresentationController.sourceRect=view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)updateApp:(TKApp *)app {
    NSDictionary *update=_updates[app.identifier];
    if (!update || _download) return;
    _updating=YES;
    [self downloadProfile:update[@"profile"] region:update[@"region"] locale:update[@"locale"]];
    if (!_download) _updating=NO;
}

- (void)importApp {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem,UTTypeApplicationBundle] asCopy:NO];
    picker.delegate=self;
    // Start where in-place apps live: On My iPad > Tolkara.
    picker.directoryURL=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url=urls.firstObject;
    if (!url) return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    _importing=YES;
    self.navigationItem.prompt=[NSString stringWithFormat:@"Verifying %@…",url.lastPathComponent];
    [self reload];
    dispatch_async(_queue,^{
        NSError *error=nil;
        TKApp *app=[self->_library importExecutable:url.path copy:NO error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(),^{
            self->_importing=NO;
            self.navigationItem.prompt=nil;
            [self reload];
            if (!app) { [self showError:error title:@"Cannot Add App"]; return; }
            NSUInteger row=[self->_apps indexOfObjectPassingTest:^BOOL(TKApp *item, NSUInteger index, BOOL *stop) {
                (void)index; (void)stop; return [item.identifier isEqual:app.identifier]; }];
            if (row!=NSNotFound)
                [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:self.hasNotice ? 1 : 0]
                    animated:YES scrollPosition:UITableViewScrollPositionMiddle];
            if (app.source==TKAppSourceCopy) {
                UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Added %@",app.name]
                    message:@"The executable was outside Tolkara's folder, so Tolkara keeps its own copy of it. An app that needs its other files must be copied into Tolkara's folder (Files > On My iPad > Tolkara) and added from there."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

- (void)showError:(NSError *)error title:(NSString *)title {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
