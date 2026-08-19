#import "MTSettingsViewController.h"

#import "MTDesignSystem.h"
#import "MTDiagnosticsViewController.h"
#import "MTManagerController.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeManifest.h"

typedef NS_ENUM(NSInteger, MTSettingsSection) {
    MTSettingsSectionGeneral,
    MTSettingsSectionDevice,
    MTSettingsSectionAbout,
};

static NSString *MTSettingsLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static UIView *MTSettingsSectionHeaderView(NSString *title) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = MTCanvasColor();
    UILabel *label = MTLabel(UIFontTextStyleCaption1,
                             UIFontWeightSemibold,
                             UIColor.secondaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:22],
        [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
        [label.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-5],
    ]];
    return view;
}

static NSString *MTInterfaceStyleDisplayName(NSString *preference) {
    if ([preference isEqualToString:MTInterfaceStyleLight]) {
        return MTSettingsLocalized(@"settings.appearance.light");
    }
    if ([preference isEqualToString:MTInterfaceStyleDark]) {
        return MTSettingsLocalized(@"settings.appearance.dark");
    }
    return MTSettingsLocalized(@"settings.appearance.system");
}

@interface MTSettingsActionCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *iconBackground;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) UIImageView *chevron;
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                    symbol:(NSString *)symbol
                     color:(UIColor *)color
                disclosure:(BOOL)disclosure;
@end

@implementation MTSettingsActionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.isAccessibilityElement = YES;

    _card = MTCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 19.0;
    [self.contentView addSubview:_card];

    _iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBackground.layer.cornerRadius = 14.0;
    _iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconBackground];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBackground addSubview:_iconView];

    _titleLabel = MTLabel(UIFontTextStyleBody,
                          UIFontWeightSemibold, UIColor.labelColor);
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    [_card addSubview:_titleLabel];

    _subtitleLabel = MTLabel(UIFontTextStyleFootnote,
                             UIFontWeightRegular,
                             UIColor.secondaryLabelColor);
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.numberOfLines = 2;
    [_card addSubview:_subtitleLabel];

    _chevron = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.tintColor = UIColor.tertiaryLabelColor;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    [_card addSubview:_chevron];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                            constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                             constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        [_iconBackground.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor
                                                       constant:14],
        [_iconBackground.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconBackground.widthAnchor constraintEqualToConstant:42],
        [_iconBackground.heightAnchor constraintEqualToConstant:42],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:21],
        [_iconView.heightAnchor constraintEqualToConstant:21],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor
                                                   constant:13],
        [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:13],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                               constant:-10],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                                  constant:-10],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-12],
        [_card.heightAnchor constraintGreaterThanOrEqualToConstant:68],

        [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
        [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:11],
        [_chevron.heightAnchor constraintEqualToConstant:17],
    ]];
    return self;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                    symbol:(NSString *)symbol
                     color:(UIColor *)color
                disclosure:(BOOL)disclosure {
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
    self.iconView.image = [UIImage systemImageNamed:symbol];
    self.iconView.tintColor = color;
    self.iconBackground.backgroundColor = MTTintedBackground(color);
    self.chevron.image = [UIImage systemImageNamed:@"chevron.right"];
    self.chevron.hidden = !disclosure;
    self.accessibilityLabel = title;
    self.accessibilityValue = subtitle;
    self.accessibilityTraits = disclosure
        ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled()
        ? 0.13 : 0.0;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.card.transform = highlighted
            ? CGAffineTransformMakeScale(0.985, 0.985)
            : CGAffineTransformIdentity;
        self.card.alpha = highlighted ? 0.86 : 1.0;
    }
                     completion:nil];
}

@end

@interface MTAppearanceSelectionViewController : UITableViewController
@property(nonatomic, copy) dispatch_block_t changeHandler;
@property(nonatomic, copy) NSArray<NSString *> *preferences;
- (instancetype)initWithChangeHandler:(dispatch_block_t)changeHandler;
@end

@implementation MTAppearanceSelectionViewController

- (instancetype)initWithChangeHandler:(dispatch_block_t)changeHandler {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _changeHandler = [changeHandler copy];
        _preferences = @[
            MTInterfaceStyleSystem,
            MTInterfaceStyleLight,
            MTInterfaceStyleDark,
        ];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MTSettingsLocalized(@"settings.appearance.title");
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.backButtonDisplayMode =
        UINavigationItemBackButtonDisplayModeMinimal;
    self.tableView.backgroundColor = MTCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 78.0;
    self.tableView.contentInset = UIEdgeInsetsMake(12, 0, 16, 0);
    self.tableView.accessibilityIdentifier = @"marktheme.settings.appearance";
    [self.tableView registerClass:MTSettingsActionCell.class
           forCellReuseIdentifier:@"AppearanceOptionCell"];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)self.preferences.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *preference = self.preferences[(NSUInteger)indexPath.row];
    BOOL selected = [preference isEqualToString:MTInterfaceStylePreference()];
    NSString *detail = nil;
    NSString *symbol = nil;
    if ([preference isEqualToString:MTInterfaceStyleLight]) {
        detail = MTSettingsLocalized(@"settings.appearance.light-detail");
        symbol = @"sun.max.fill";
    } else if ([preference isEqualToString:MTInterfaceStyleDark]) {
        detail = MTSettingsLocalized(@"settings.appearance.dark-detail");
        symbol = @"moon.stars.fill";
    } else {
        detail = MTSettingsLocalized(@"settings.appearance.system-detail");
        symbol = @"circle.lefthalf.filled";
    }
    MTSettingsActionCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"AppearanceOptionCell"
                              forIndexPath:indexPath];
    [cell configureWithTitle:MTInterfaceStyleDisplayName(preference)
                    subtitle:detail
                      symbol:symbol
                       color:MTAccentColor()
                  disclosure:NO];
    cell.chevron.image = [UIImage systemImageNamed:@"checkmark"];
    cell.chevron.tintColor = MTAccentColor();
    cell.chevron.hidden = !selected;
    cell.accessibilityTraits = UIAccessibilityTraitButton |
        (selected ? UIAccessibilityTraitSelected : 0);
    cell.accessibilityIdentifier =
        [@"marktheme.settings.appearance." stringByAppendingString:preference];
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    NSString *preference = self.preferences[(NSUInteger)indexPath.row];
    if ([preference isEqualToString:MTInterfaceStylePreference()]) return;
    MTSetInterfaceStylePreference(preference);
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    [self.tableView reloadData];
    if (self.changeHandler != nil) self.changeHandler();
}

@end

@interface MTSettingsInfoViewController : UIViewController
@property(nonatomic, copy) NSString *pageTitle;
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, copy) NSString *headline;
@property(nonatomic, copy) NSString *intro;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *sections;
- (instancetype)initWithTitle:(NSString *)title
                        symbol:(NSString *)symbol
                      headline:(NSString *)headline
                         intro:(NSString *)intro
                      sections:
                          (NSArray<NSDictionary<NSString *, NSString *> *> *)sections;
@end

@implementation MTSettingsInfoViewController

- (instancetype)initWithTitle:(NSString *)title
                        symbol:(NSString *)symbol
                      headline:(NSString *)headline
                         intro:(NSString *)intro
                      sections:
                          (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _pageTitle = [title copy];
        _symbol = [symbol copy];
        _headline = [headline copy];
        _intro = [intro copy];
        _sections = [sections copy];
    }
    return self;
}

- (UIView *)sectionCard:(NSDictionary<NSString *, NSString *> *)section {
    UIView *card = MTCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:section[@"symbol"]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = MTAccentColor();
    [card addSubview:icon];
    UILabel *title = MTLabel(UIFontTextStyleHeadline,
                             UIFontWeightSemibold, UIColor.labelColor);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = section[@"title"];
    [card addSubview:title];
    UILabel *detail = MTLabel(UIFontTextStyleSubheadline,
                              UIFontWeightRegular,
                              UIColor.secondaryLabelColor);
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.text = section[@"detail"];
    [card addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:19],
        [icon.widthAnchor constraintEqualToConstant:23],
        [icon.heightAnchor constraintEqualToConstant:23],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:13],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:17],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTCanvasColor();
    self.title = self.pageTitle;
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.backButtonDisplayMode =
        UINavigationItemBackButtonDisplayModeMinimal;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12.0;
    [scroll addSubview:stack];

    MTGradientView *hero = [[MTGradientView alloc] initWithFrame:CGRectZero];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    hero.gradientColors = MTThemeGradientColors(self.pageTitle);
    [stack addArrangedSubview:hero];

    UIImageView *heroIcon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:self.symbol
            withConfiguration:[UIImageSymbolConfiguration
                configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold]]];
    heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    heroIcon.tintColor = MTSpecimenInkColor();
    [hero addSubview:heroIcon];
    UILabel *headline = [[UILabel alloc] initWithFrame:CGRectZero];
    headline.translatesAutoresizingMaskIntoConstraints = NO;
    headline.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
    headline.textColor = MTSpecimenInkColor();
    headline.numberOfLines = 0;
    headline.text = self.headline;
    [hero addSubview:headline];
    UILabel *intro = [[UILabel alloc] initWithFrame:CGRectZero];
    intro.translatesAutoresizingMaskIntoConstraints = NO;
    intro.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    intro.textColor = MTSpecimenSecondaryInkColor();
    intro.numberOfLines = 0;
    intro.text = self.intro;
    [hero addSubview:intro];

    [NSLayoutConstraint activateConstraints:@[
        [hero.heightAnchor constraintGreaterThanOrEqualToConstant:178],
        [heroIcon.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:22],
        [heroIcon.topAnchor constraintEqualToAnchor:hero.topAnchor constant:24],
        [heroIcon.widthAnchor constraintEqualToConstant:36],
        [heroIcon.heightAnchor constraintEqualToConstant:36],
        [headline.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:22],
        [headline.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-22],
        [headline.topAnchor constraintEqualToAnchor:heroIcon.bottomAnchor constant:17],
        [intro.leadingAnchor constraintEqualToAnchor:headline.leadingAnchor],
        [intro.trailingAnchor constraintEqualToAnchor:headline.trailingAnchor],
        [intro.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:7],
        [intro.bottomAnchor constraintLessThanOrEqualToAnchor:hero.bottomAnchor constant:-22],
    ]];
    for (NSDictionary<NSString *, NSString *> *section in self.sections) {
        [stack addArrangedSubview:[self sectionCard:section]];
    }

    UILayoutGuide *contentGuide = scroll.contentLayoutGuide;
    UILayoutGuide *frameGuide = scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:contentGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor constant:-40],
    ]];
}

@end

@interface MTSettingsViewController ()
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, assign) BOOL runtimeLoaded;
@property(nonatomic, assign) BOOL runtimeAvailable;
@property(nonatomic, assign) BOOL runtimeEnabled;
@property(nonatomic, assign) BOOL runtimeCanRollback;
@property(nonatomic, assign) BOOL runtimeBusy;
@property(nonatomic, assign) NSUInteger runtimeResourceCount;
@property(nonatomic, assign) NSUInteger runtimeModuleCount;
@property(nonatomic, copy) NSString *runtimeThemeName;
@property(nonatomic, assign) BOOL hasRuntimeProjection;
@property(nonatomic, copy) NSString *interfaceStylePreference;
@property(nonatomic, assign) BOOL managerProjectionPending;
@end

@implementation MTSettingsViewController

- (instancetype)initWithManagerController:
        (MTManagerController *)managerController {
    NSParameterAssert(managerController != nil);
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) _managerController = managerController;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MTSettingsLocalized(@"settings.title");
    self.navigationItem.backButtonDisplayMode =
        UINavigationItemBackButtonDisplayModeMinimal;
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
    self.runtimeThemeName = MTSettingsLocalized(@"theme.stock.name");
    self.interfaceStylePreference = MTInterfaceStylePreference();

    MTPressableButton *closeButton =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    closeButton.accessibilityLabel = MTSettingsLocalized(@"settings.close");
    UIButtonConfiguration *closeConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    closeConfiguration.image = [UIImage systemImageNamed:@"xmark"];
    closeConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    closeConfiguration.baseForegroundColor = MTAccentColor();
    closeConfiguration.baseBackgroundColor = MTAccentColor();
    closeButton.configuration = closeConfiguration;
    [closeButton addTarget:self action:@selector(closeSettings:)
           forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.widthAnchor constraintEqualToConstant:36],
        [closeButton.heightAnchor constraintEqualToConstant:36],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:closeButton];

    self.tableView.backgroundColor = MTCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78.0;
    self.tableView.sectionHeaderHeight = 34.0;
    self.tableView.sectionHeaderTopPadding = 0.0;
    self.tableView.sectionFooterHeight = 8.0;
    self.tableView.accessibilityIdentifier = @"marktheme.settings";
    [self.tableView registerClass:MTSettingsActionCell.class
           forCellReuseIdentifier:@"SettingsActionCell"];
    self.tableView.tableFooterView = [self makeAboutFooter];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(managerControllerDidChange:)
               name:MTManagerControllerDidChangeNotification
             object:self.managerController];
    [self consumeManagerSnapshot];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAppearanceProjection];
    if (self.managerProjectionPending) {
        self.managerProjectionPending = NO;
        [self consumeManagerSnapshot];
    }
}

- (UIView *)makeAboutFooter {
    UIView *footer = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 88)];
    UILabel *label = MTLabel(UIFontTextStyleCaption1,
                             UIFontWeightMedium,
                             UIColor.tertiaryLabelColor);
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *version = [NSBundle.mainBundle
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) version = @"—";
    label.text = [NSString stringWithFormat:
        MTSettingsLocalized(@"settings.footer-format"), version];
    label.textAlignment = NSTextAlignmentCenter;
    [footer addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [label.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [label.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
    ]];
    return footer;
}

- (void)managerControllerDidChange:(NSNotification *)notification {
    (void)notification;
    if (!MTViewControllerCanApplyVisibleProjection(self)) {
        self.managerProjectionPending = YES;
        return;
    }
    [self consumeManagerSnapshot];
}

- (void)consumeManagerSnapshot {
    MTManagerSnapshot *snapshot = self.managerController.snapshot;
    BOOL preserveRuntimePresentation =
        self.hasRuntimeProjection && snapshot.isRuntimeRefreshing;
    BOOL runtimeLoaded = preserveRuntimePresentation
        ? self.runtimeLoaded : !snapshot.isRuntimeRefreshing;
    BOOL runtimeAvailable = preserveRuntimePresentation
        ? self.runtimeAvailable : snapshot.runtimeAvailable;
    BOOL runtimeEnabled = preserveRuntimePresentation
        ? self.runtimeEnabled : snapshot.runtimeEnabled;
    BOOL runtimeCanRollback = preserveRuntimePresentation
        ? self.runtimeCanRollback : snapshot.canRollbackRuntime;
    BOOL runtimeBusy = snapshot.operation != MTManagerOperationIdle;
    NSUInteger runtimeResourceCount = preserveRuntimePresentation
        ? self.runtimeResourceCount : snapshot.runtimeResourceCount;
    NSUInteger runtimeModuleCount = preserveRuntimePresentation
        ? self.runtimeModuleCount : snapshot.runtimeModuleIDs.count;
    NSString *runtimeThemeName = self.runtimeThemeName;
    if (!preserveRuntimePresentation) {
        runtimeThemeName = MTSettingsLocalized(@"theme.stock.name");
        MTThemeLibraryThemeSummary *active =
            [snapshot themeWithIdentifier:snapshot.activeThemeIdentifier];
        if (active != nil) {
            runtimeThemeName = active.currentRevision.manifest.displayName;
        }
    }
    BOOL runtimeRowChanged = self.runtimeLoaded != runtimeLoaded ||
        self.runtimeAvailable != runtimeAvailable ||
        self.runtimeEnabled != runtimeEnabled ||
        ![self.runtimeThemeName isEqualToString:runtimeThemeName];
    BOOL rollbackVisibilityChanged =
        self.runtimeCanRollback != runtimeCanRollback;
    BOOL hadProjection = self.hasRuntimeProjection;
    self.runtimeLoaded = runtimeLoaded;
    self.runtimeAvailable = runtimeAvailable;
    self.runtimeEnabled = runtimeEnabled;
    self.runtimeCanRollback = runtimeCanRollback;
    self.runtimeBusy = runtimeBusy;
    self.runtimeResourceCount = runtimeResourceCount;
    self.runtimeModuleCount = runtimeModuleCount;
    self.runtimeThemeName = runtimeThemeName;
    self.hasRuntimeProjection = YES;
    if (!hadProjection) return;
    if (rollbackVisibilityChanged) {
        [self.tableView reloadSections:
            [NSIndexSet indexSetWithIndex:MTSettingsSectionDevice]
                      withRowAnimation:UITableViewRowAnimationNone];
    } else if (runtimeRowChanged) {
        [self.tableView reloadRowsAtIndexPaths:@[
            [NSIndexPath indexPathForRow:0
                               inSection:MTSettingsSectionDevice],
        ] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)updateAppearanceProjection {
    NSString *preference = MTInterfaceStylePreference();
    if ([self.interfaceStylePreference isEqualToString:preference]) return;
    self.interfaceStylePreference = preference;
    [self.tableView reloadRowsAtIndexPaths:@[
        [NSIndexPath indexPathForRow:0
                           inSection:MTSettingsSectionGeneral],
    ] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)runtimeSubtitle {
    if (!self.runtimeLoaded) {
        return MTSettingsLocalized(@"settings.runtime.loading");
    }
    if (!self.runtimeAvailable) {
        return MTSettingsLocalized(@"settings.runtime.unavailable");
    }
    if (!self.runtimeEnabled) {
        return MTSettingsLocalized(@"settings.runtime.stock");
    }
    return [NSString stringWithFormat:
        MTSettingsLocalized(@"settings.runtime.active-format"),
        self.runtimeThemeName];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == MTSettingsSectionAbout) return 4;
    if (section == MTSettingsSectionDevice) {
        return self.runtimeCanRollback ? 2 : 1;
    }
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[
        MTSettingsLocalized(@"settings.section.general"),
        MTSettingsLocalized(@"settings.section.device"),
        MTSettingsLocalized(@"settings.section.about"),
    ][(NSUInteger)section];
}

- (UIView *)tableView:(UITableView *)tableView
 viewForHeaderInSection:(NSInteger)section {
    return MTSettingsSectionHeaderView(
        [self tableView:tableView titleForHeaderInSection:section]);
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 34.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MTSettingsActionCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"SettingsActionCell"
                              forIndexPath:indexPath];
    cell.accessibilityHint = nil;
    if (indexPath.section == MTSettingsSectionGeneral) {
        [cell configureWithTitle:MTSettingsLocalized(@"settings.appearance.title")
                        subtitle:MTInterfaceStyleDisplayName(
                            self.interfaceStylePreference)
                          symbol:@"circle.lefthalf.filled"
                           color:MTAccentColor()
                      disclosure:YES];
        cell.accessibilityIdentifier = @"marktheme.settings.appearance-row";
    } else if (indexPath.section == MTSettingsSectionDevice &&
               indexPath.row == 0) {
        [cell configureWithTitle:MTSettingsLocalized(@"settings.runtime.title")
                        subtitle:[self runtimeSubtitle]
                          symbol:!self.runtimeLoaded
                              ? @"hourglass"
                              : (self.runtimeAvailable
                                  ? @"checkmark.shield.fill"
                                  : @"shield.slash.fill")
                           color:!self.runtimeLoaded
                              ? MTAccentColor()
                              : (self.runtimeAvailable
                                  ? MTSuccessColor() : MTWarningColor())
                      disclosure:YES];
        cell.accessibilityIdentifier = @"marktheme.settings.runtime";
    } else if (indexPath.section == MTSettingsSectionDevice) {
        [cell configureWithTitle:
                  MTSettingsLocalized(@"settings.runtime.rollback-title")
                        subtitle:
                  MTSettingsLocalized(@"settings.runtime.rollback-subtitle")
                          symbol:@"arrow.uturn.backward.circle.fill"
                           color:MTWarningColor()
                      disclosure:NO];
        cell.accessibilityIdentifier = @"marktheme.settings.runtime-rollback";
    } else if (indexPath.row == 0) {
        [cell configureWithTitle:MTSettingsLocalized(@"settings.author.title")
                        subtitle:@"Hmmzzz"
                          symbol:@"person.crop.circle.fill"
                           color:MTAccentColor()
                      disclosure:NO];
        cell.accessibilityIdentifier = @"marktheme.settings.author";
    } else if (indexPath.row == 1) {
        [cell configureWithTitle:MTSettingsLocalized(@"settings.disclaimer.title")
                        subtitle:MTSettingsLocalized(@"settings.disclaimer.subtitle")
                          symbol:@"hand.raised.fill"
                           color:MTAccentColor()
                      disclosure:YES];
        cell.accessibilityIdentifier = @"marktheme.settings.disclaimer";
    } else if (indexPath.row == 2) {
        [cell configureWithTitle:MTSettingsLocalized(@"settings.credits.title")
                        subtitle:MTSettingsLocalized(@"settings.credits.subtitle")
                          symbol:@"heart.fill"
                           color:MTAccentColor()
                      disclosure:YES];
        cell.accessibilityIdentifier = @"marktheme.settings.credits";
    } else {
        [cell configureWithTitle:
                  MTSettingsLocalized(@"settings.diagnostics.title")
                        subtitle:
                  MTSettingsLocalized(@"settings.diagnostics.subtitle")
                          symbol:@"stethoscope"
                           color:MTAccentColor()
                      disclosure:YES];
        cell.accessibilityIdentifier = @"marktheme.settings.diagnostics";
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView
 shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == MTSettingsSectionDevice &&
        indexPath.row == 1 && self.runtimeBusy) {
        return NO;
    }
    return !(indexPath.section == MTSettingsSectionAbout && indexPath.row == 0);
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (indexPath.section == MTSettingsSectionAbout && indexPath.row == 0) return;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    if (indexPath.section == MTSettingsSectionGeneral) {
        __weak typeof(self) weakSelf = self;
        MTAppearanceSelectionViewController *appearance =
            [[MTAppearanceSelectionViewController alloc]
                initWithChangeHandler:^{
            if (MTViewControllerCanApplyVisibleProjection(weakSelf)) {
                [weakSelf updateAppearanceProjection];
            }
        }];
        [self.navigationController pushViewController:appearance animated:YES];
        return;
    }
    if (indexPath.section == MTSettingsSectionDevice) {
        if (indexPath.row == 1) {
            [self confirmRuntimeRollback];
            return;
        }
        [self.navigationController
            pushViewController:[self runtimeInfoController] animated:YES];
        return;
    }
    if (indexPath.row == 1) {
        [self.navigationController
            pushViewController:[self disclaimerController] animated:YES];
    } else if (indexPath.row == 2) {
        [self.navigationController
            pushViewController:[self creditsController] animated:YES];
    } else {
        [self.navigationController
            pushViewController:[[MTDiagnosticsViewController alloc] init]
                      animated:YES];
    }
}

- (void)confirmRuntimeRollback {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:
            MTSettingsLocalized(@"settings.runtime.rollback-confirm-title")
        message:MTSettingsLocalized(@"settings.runtime.rollback-confirm-detail")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTSettingsLocalized(@"common.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:MTSettingsLocalized(@"settings.runtime.rollback-action")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        [weakSelf.managerController rollbackRuntimeWithCompletion:
            ^(BOOL success, NSError *error) {
            if (success) {
                [[[UINotificationFeedbackGenerator alloc] init]
                    notificationOccurred:UINotificationFeedbackTypeSuccess];
                return;
            }
            NSLog(@"MarkTheme Runtime rollback failed (%@/%ld): %@",
                  error.domain, (long)error.code, error.localizedDescription);
            UIAlertController *failure = [UIAlertController
                alertControllerWithTitle:
                    MTSettingsLocalized(@"settings.runtime.rollback-error-title")
                message:MTSettingsLocalized(@"settings.runtime.rollback-error-detail")
                preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction
                actionWithTitle:MTSettingsLocalized(@"common.ok")
                          style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:failure animated:YES completion:nil];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (MTSettingsInfoViewController *)runtimeInfoController {
    if (!self.runtimeLoaded) {
        return [[MTSettingsInfoViewController alloc]
            initWithTitle:MTSettingsLocalized(@"settings.runtime.title")
                   symbol:@"hourglass"
                 headline:MTSettingsLocalized(@"settings.runtime.loading")
                    intro:MTSettingsLocalized(@"settings.runtime.loading-detail")
                 sections:@[]];
    }
    if (!self.runtimeAvailable) {
        return [[MTSettingsInfoViewController alloc]
            initWithTitle:MTSettingsLocalized(@"settings.runtime.title")
                   symbol:@"shield.slash.fill"
                 headline:MTSettingsLocalized(@"settings.runtime.unavailable-title")
                    intro:MTSettingsLocalized(@"settings.runtime.unavailable-detail")
                 sections:@[]];
    }
    NSString *resourceDetail = self.runtimeEnabled
        ? [NSString stringWithFormat:
            MTSettingsLocalized(@"settings.runtime.resource-format"),
            (unsigned long)self.runtimeResourceCount]
        : MTSettingsLocalized(@"settings.runtime.stock-detail");
    NSString *moduleDetail = [NSString stringWithFormat:
        MTSettingsLocalized(@"settings.runtime.module-format"),
        (unsigned long)self.runtimeModuleCount];
    return [[MTSettingsInfoViewController alloc]
        initWithTitle:MTSettingsLocalized(@"settings.runtime.title")
               symbol:@"checkmark.shield.fill"
             headline:self.runtimeEnabled
                ? MTSettingsLocalized(@"settings.runtime.ready-title")
                : MTSettingsLocalized(@"settings.runtime.stock-title")
                intro:MTSettingsLocalized(@"settings.runtime.ready-detail")
             sections:@[
        @{
            @"symbol" : @"square.grid.2x2.fill",
            @"title" : MTSettingsLocalized(@"settings.runtime.current-theme"),
            @"detail" : [NSString stringWithFormat:@"%@ · %@",
                self.runtimeThemeName, resourceDetail],
        },
        @{
            @"symbol" : @"arrow.clockwise.circle.fill",
            @"title" : MTSettingsLocalized(@"settings.runtime.refresh-title"),
            @"detail" : MTSettingsLocalized(@"settings.runtime.refresh-detail"),
        },
        @{
            @"symbol" : @"shippingbox.fill",
            @"title" : MTSettingsLocalized(@"settings.runtime.modules-title"),
            @"detail" : moduleDetail,
        },
    ]];
}

- (MTSettingsInfoViewController *)disclaimerController {
    return [[MTSettingsInfoViewController alloc]
        initWithTitle:MTSettingsLocalized(@"settings.disclaimer.title")
               symbol:@"hand.raised.fill"
             headline:MTSettingsLocalized(@"settings.disclaimer.headline")
                intro:MTSettingsLocalized(@"settings.disclaimer.intro")
             sections:@[
        @{
            @"symbol" : @"photo.on.rectangle.angled",
            @"title" : MTSettingsLocalized(@"settings.disclaimer.icons-title"),
            @"detail" : MTSettingsLocalized(@"settings.disclaimer.icons-detail"),
        },
        @{
            @"symbol" : @"iphone.gen3",
            @"title" : MTSettingsLocalized(@"settings.disclaimer.device-title"),
            @"detail" : MTSettingsLocalized(@"settings.disclaimer.device-detail"),
        },
    ]];
}

- (MTSettingsInfoViewController *)creditsController {
    return [[MTSettingsInfoViewController alloc]
        initWithTitle:MTSettingsLocalized(@"settings.credits.title")
               symbol:@"heart.fill"
             headline:MTSettingsLocalized(@"settings.credits.headline")
                intro:MTSettingsLocalized(@"settings.credits.intro")
             sections:@[
        @{
            @"symbol" : @"paintpalette.fill",
            @"title" : MTSettingsLocalized(@"settings.credits.community-title"),
            @"detail" : MTSettingsLocalized(@"settings.credits.community-detail"),
        },
        @{
            @"symbol" : @"curlybraces.square.fill",
            @"title" : MTSettingsLocalized(@"settings.credits.foundation-title"),
            @"detail" : MTSettingsLocalized(@"settings.credits.foundation-detail"),
        },
    ]];
}

- (void)closeSettings:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:^{
        dispatch_block_t handler = self.dismissalHandler;
        self.dismissalHandler = nil;
        if (handler != nil) handler();
    }];
}

@end
