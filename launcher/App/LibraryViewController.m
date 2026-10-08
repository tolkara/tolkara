#import "LibraryViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TKLibraryViewController () <UIDocumentPickerDelegate>
@end

// The AppKit adapter's AKTouchControlsDefaultsKey (translation/AppKit/TouchControls.h):
// the adapter loads with a game, so the launcher names the setting itself.
static NSString *const TKTouchControlsKey=@"AKTouchControls";
static BOOL TKTouchControlsShown(void) {
    NSNumber *saved=[NSUserDefaults.standardUserDefaults objectForKey:TKTouchControlsKey];
    return [saved isKindOfClass:NSNumber.class] ? saved.boolValue : UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPhone;
}

@implementation TKLibraryViewController {
    TKAppLibrary *_library;
    NSArray<TKApp *> *_apps;
    dispatch_queue_t _queue;
    BOOL _discovered, _importing;
    UIBarButtonItem *_addItem, *_controlsItem;
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
    _controlsItem.accessibilityLabel=@"On-Screen Controls";
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
        dispatch_async(dispatch_get_main_queue(),^{ self->_discovered=YES; [self reload]; });
    });
}
- (void)reload {
    _apps=_library.apps;
    _addItem.enabled=!_importing;
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
    if (app) [self.delegate libraryViewController:self startApp:app];
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
        return [UIMenu menuWithChildren:@[
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
    }];
}

#pragma mark Actions

- (void)showDiagnostics { [self.delegate libraryViewControllerShowDiagnostics:self]; }
- (void)showExecutionMode { [self.delegate libraryViewControllerShowExecutionMode:self]; }
// Optional keyboard and touch-trackpad buttons over a game, read when it starts.
- (void)updateControlsMenu {
    __weak TKLibraryViewController *weakSelf=self;
    UIAction *toggle=[UIAction actionWithTitle:@"On-Screen Controls" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a;
        [NSUserDefaults.standardUserDefaults setBool:!TKTouchControlsShown() forKey:TKTouchControlsKey];
        [weakSelf updateControlsMenu];
    }];
    toggle.state=TKTouchControlsShown()?UIMenuElementStateOn:UIMenuElementStateOff;
    _controlsItem.menu=[UIMenu menuWithTitle:@"Keyboard and touch-trackpad buttons over the game, from its next start"
        children:@[toggle]];
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
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:app.name message:message preferredStyle:UIAlertControllerStyleActionSheet];
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
