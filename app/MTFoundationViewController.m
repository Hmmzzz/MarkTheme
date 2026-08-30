#import "MTFoundationViewController.h"

#import "MTDesignSystem.h"
#import "MTApplyResultViewController.h"
#import "MTImportDiagnostics.h"
#import "MTImportViewController.h"
#import "MTManagerController.h"
#import "MTSettingsViewController.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeLibraryViewController.h"
#import "MTThemeDetailViewController.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"
#import "MTThemePreviewProvider.h"
#import "MTThemePreviewRepository.h"

static NSString *MTLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static BOOL MTThemeIdentifiersEqual(NSString *_Nullable left,
                                    NSString *_Nullable right) {
    return left == right || [left isEqualToString:right];
}

static NSString *const MTThemeChoiceCardReuseIdentifier =
    @"MTThemeChoiceCard";

static NSString *MTThemeSecondaryText(MTThemeManifest *manifest) {
    if (manifest.author.length > 0 && manifest.themeVersion.length > 0) {
        return [NSString stringWithFormat:MTLocalized(@"theme.meta.author-version"),
                                          manifest.author,
                                          manifest.themeVersion];
    }
    if (manifest.author.length > 0) return manifest.author;
    if (manifest.themeVersion.length > 0) {
        return [NSString stringWithFormat:MTLocalized(@"theme.meta.version"),
                                          manifest.themeVersion];
    }
    return MTLocalized(@"theme.meta.system-theme");
}

@interface MTThemeHeroView : MTGradientView
@property(nonatomic, copy, nullable) NSString *themeIdentifier;
@property(nonatomic, copy, nullable) NSString *previewRevisionIdentifier;
@property(nonatomic, strong) UILabel *badgeLabel;
@property(nonatomic, strong) MTPressableButton *detailButton;
@property(nonatomic, strong) MTIconGridView *iconGrid;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *countLabel;
- (void)configureWithThemeIdentifier:(nullable NSString *)themeIdentifier
           previewRevisionIdentifier:(nullable NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                       resourceCount:(NSUInteger)resourceCount
                          iconImages:(nullable NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                            animated:(BOOL)animated;
@end

@implementation MTThemeHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.isAccessibilityElement = NO;

    _badgeLabel = MTLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                          [UIColor colorWithWhite:0.12 alpha:0.88]);
    _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.54];
    _badgeLabel.layer.cornerRadius = 12.0;
    _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _badgeLabel.layer.masksToBounds = YES;
    _badgeLabel.isAccessibilityElement = NO;
    [self addSubview:_badgeLabel];

    _detailButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    _detailButton.translatesAutoresizingMaskIntoConstraints = NO;
    _detailButton.accessibilityIdentifier = @"marktheme.theme-details";
    UIButtonConfiguration *detailConfiguration =
        [UIButtonConfiguration plainButtonConfiguration];
    detailConfiguration.attributedTitle = [[NSAttributedString alloc]
        initWithString:MTLocalized(@"home.theme-details")
        attributes:@{
            NSFontAttributeName : [[UIFontMetrics
                metricsForTextStyle:UIFontTextStyleCaption2]
                scaledFontForFont:[UIFont systemFontOfSize:11
                                                    weight:UIFontWeightSemibold]],
        }];
    detailConfiguration.image = [UIImage
        systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration
            configurationWithPointSize:9 weight:UIImageSymbolWeightSemibold]];
    detailConfiguration.imagePlacement = NSDirectionalRectEdgeTrailing;
    detailConfiguration.imagePadding = 4;
    detailConfiguration.contentInsets =
        NSDirectionalEdgeInsetsMake(0, 4, 0, 3);
    detailConfiguration.baseForegroundColor = MTSpecimenInkColor();
    _detailButton.configuration = detailConfiguration;
    _detailButton.hidden = YES;
    [self addSubview:_detailButton];

    _iconGrid = [[MTIconGridView alloc] initWithFrame:CGRectZero];
    _iconGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_iconGrid];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:29 weight:UIFontWeightBold];
    _nameLabel.textColor = MTSpecimenInkColor();
    _nameLabel.numberOfLines = 2;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.72;
    _nameLabel.isAccessibilityElement = YES;
    [self addSubview:_nameLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _detailLabel.textColor = MTSpecimenSecondaryInkColor();
    _detailLabel.numberOfLines = 2;
    _detailLabel.isAccessibilityElement = NO;
    [self addSubview:_detailLabel];

    _countLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _countLabel.textColor = MTSpecimenSecondaryInkColor();
    _countLabel.isAccessibilityElement = NO;
    [self addSubview:_countLabel];

    self.accessibilityElements = @[ _nameLabel ];

    [NSLayoutConstraint activateConstraints:@[
        [_badgeLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:20],
        [_badgeLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
        [_badgeLabel.heightAnchor constraintEqualToConstant:25],
        [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_detailButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                     constant:-16],
        [_detailButton.centerYAnchor constraintEqualToAnchor:_badgeLabel.centerYAnchor],
        [_detailButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:
            _badgeLabel.trailingAnchor constant:12],
        [_detailButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],

        [_iconGrid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                constant:18],
        [_iconGrid.topAnchor constraintEqualToAnchor:_badgeLabel.bottomAnchor
                                            constant:15],
        [_iconGrid.widthAnchor constraintEqualToConstant:142],
        [_iconGrid.heightAnchor constraintEqualToConstant:142],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconGrid.trailingAnchor
                                                 constant:17],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-20],
        [_nameLabel.topAnchor constraintEqualToAnchor:_iconGrid.topAnchor
                                             constant:10],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor
                                               constant:8],

        [_countLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_countLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_countLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor
                                              constant:8],
        [_countLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor
                                                           constant:-18],
    ]];
    return self;
}

- (void)configureWithThemeIdentifier:(NSString *)themeIdentifier
           previewRevisionIdentifier:(NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                       resourceCount:(NSUInteger)resourceCount
                          iconImages:(NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                            animated:(BOOL)animated {
    BOOL previewChanged =
        !MTThemeIdentifiersEqual(self.themeIdentifier, themeIdentifier) ||
        !MTThemeIdentifiersEqual(self.previewRevisionIdentifier,
                                 previewRevisionIdentifier);
    self.themeIdentifier = themeIdentifier;
    self.previewRevisionIdentifier = previewRevisionIdentifier;
    void (^updates)(void) = ^{
        self.gradientColors = MTThemeGradientColors(themeIdentifier);
        self.badgeLabel.text = current
            ? MTLocalized(@"theme.state.current")
            : MTLocalized(@"theme.state.preview");
        self.nameLabel.text = name;
        self.detailLabel.text = detail;
        self.countLabel.text = themeIdentifier == nil
            ? MTLocalized(@"theme.stock.count")
            : [NSString stringWithFormat:MTLocalized(@"theme.resource-count"),
                                          (unsigned long)resourceCount];
        self.detailButton.hidden = themeIdentifier.length == 0;
        self.detailButton.enabled = themeIdentifier.length > 0;
        self.accessibilityElements = themeIdentifier.length > 0
            ? @[ self.nameLabel, self.detailButton ]
            : @[ self.nameLabel ];
        if (iconImages != nil) {
            [self.iconGrid setIconImages:iconImages animated:animated];
        } else if (previewChanged) {
            [self.iconGrid setIconImages:@[] animated:NO];
        }
        self.nameLabel.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@",
            self.badgeLabel.text, name, detail];
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:self
                          duration:0.24
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState |
                                   UIViewAnimationOptionAllowUserInteraction
                        animations:updates
                        completion:nil];
    } else {
        updates();
    }
}

@end

@interface MTThemeChoiceCard : UICollectionViewCell
@property(nonatomic, copy, nullable) NSString *themeIdentifier;
@property(nonatomic, copy, nullable) NSString *previewRevisionIdentifier;
@property(nonatomic, strong) MTIconGridView *iconGrid;
@property(nonatomic, strong) UIImageView *checkBadge;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *stateLabel;
@property(nonatomic, strong, nullable) MTThemePreviewRequest *previewRequest;
- (void)configureWithThemeIdentifier:(nullable NSString *)themeIdentifier
           previewRevisionIdentifier:(nullable NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                          iconImages:(nullable NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                              chosen:(BOOL)chosen
                            animated:(BOOL)animated;
@end

@implementation MTThemeChoiceCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = MTCardColor();
    self.contentView.layer.cornerRadius = 20.0;
    self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentView.layer.borderWidth = 1.0;
    self.contentView.layer.borderColor = MTHairlineColor().CGColor;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    _iconGrid = [[MTIconGridView alloc] initWithFrame:CGRectZero];
    _iconGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_iconGrid];

    _checkBadge = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark"
            withConfiguration:[UIImageSymbolConfiguration
                configurationWithPointSize:12 weight:UIImageSymbolWeightBold]]];
    _checkBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _checkBadge.tintColor = MTAccentColor();
    _checkBadge.contentMode = UIViewContentModeCenter;
    _checkBadge.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.92];
    _checkBadge.layer.cornerRadius = 11.0;
    _checkBadge.layer.cornerCurve = kCACornerCurveContinuous;
    _checkBadge.layer.masksToBounds = YES;
    _checkBadge.hidden = YES;
    [_iconGrid addSubview:_checkBadge];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.70;
    [self.contentView addSubview:_nameLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 1;
    [self.contentView addSubview:_detailLabel];

    _stateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _stateLabel.textAlignment = NSTextAlignmentCenter;
    _stateLabel.layer.cornerRadius = 10.5;
    _stateLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _stateLabel.layer.masksToBounds = YES;
    [self.contentView addSubview:_stateLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_iconGrid.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                constant:12],
        [_iconGrid.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                 constant:-12],
        [_iconGrid.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                            constant:10],
        [_iconGrid.heightAnchor constraintEqualToAnchor:_iconGrid.widthAnchor],

        [_checkBadge.trailingAnchor constraintEqualToAnchor:_iconGrid.trailingAnchor
                                                  constant:-6],
        [_checkBadge.topAnchor constraintEqualToAnchor:_iconGrid.topAnchor constant:6],
        [_checkBadge.widthAnchor constraintEqualToConstant:22],
        [_checkBadge.heightAnchor constraintEqualToConstant:22],

        [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                 constant:14],
        [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                  constant:-14],
        [_nameLabel.topAnchor constraintEqualToAnchor:_iconGrid.bottomAnchor
                                             constant:9],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor
                                               constant:2],

        [_stateLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_stateLabel.topAnchor constraintGreaterThanOrEqualToAnchor:_detailLabel.bottomAnchor
                                                            constant:6],
        [_stateLabel.heightAnchor constraintEqualToConstant:21],
        [_stateLabel.widthAnchor constraintGreaterThanOrEqualToConstant:52],
        [_stateLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                 constant:-12],
    ]];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.14;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.contentView.transform = highlighted
            ? CGAffineTransformMakeScale(0.97, 0.97)
            : CGAffineTransformIdentity;
    }
                     completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.previewRequest cancel];
    self.previewRequest = nil;
    self.themeIdentifier = nil;
    self.previewRevisionIdentifier = nil;
    self.contentView.transform = CGAffineTransformIdentity;
    [self.iconGrid setIconImages:@[] animated:NO];
}

- (void)configureWithThemeIdentifier:(NSString *)themeIdentifier
           previewRevisionIdentifier:(NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                          iconImages:(NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                              chosen:(BOOL)chosen
                            animated:(BOOL)animated {
    BOOL previewChanged =
        !MTThemeIdentifiersEqual(self.themeIdentifier, themeIdentifier) ||
        !MTThemeIdentifiersEqual(self.previewRevisionIdentifier,
                                 previewRevisionIdentifier);
    if (previewChanged) {
        [self.previewRequest cancel];
        self.previewRequest = nil;
    }
    self.themeIdentifier = themeIdentifier;
    self.previewRevisionIdentifier = previewRevisionIdentifier;
    self.selected = chosen;
    self.nameLabel.text = name;
    self.detailLabel.text = detail;
    if (iconImages != nil) {
        [self.iconGrid setIconImages:iconImages animated:animated];
    } else if (previewChanged) {
        [self.iconGrid setIconImages:@[] animated:NO];
    }
    self.checkBadge.hidden = !chosen;
    self.stateLabel.text = [NSString stringWithFormat:@"  %@  ",
        current ? MTLocalized(@"theme.card.current")
                : (chosen ? MTLocalized(@"theme.card.previewing")
                          : MTLocalized(@"theme.card.available"))];
    self.stateLabel.textColor = current
        ? MTSuccessColor()
        : (chosen ? MTAccentColor() : UIColor.secondaryLabelColor);
    self.stateLabel.backgroundColor = current
        ? MTTintedBackground(MTSuccessColor())
        : (chosen ? MTTintedBackground(MTAccentColor())
                  : UIColor.tertiarySystemFillColor);
    self.contentView.layer.borderWidth = chosen ? 2.0 : 1.0;
    self.contentView.layer.borderColor =
        (chosen ? MTAccentColor() : MTHairlineColor()).CGColor;
    self.accessibilityLabel = name;
    self.accessibilityValue = current
        ? MTLocalized(@"theme.state.current")
        : (chosen ? MTLocalized(@"theme.state.preview")
                  : MTLocalized(@"theme.card.available"));
    self.accessibilityTraits = UIAccessibilityTraitButton |
        (chosen ? UIAccessibilityTraitSelected : 0);
}

@end

@interface MTFoundationViewController () <UICollectionViewDataSource,
                                           UICollectionViewDelegate,
                                           UICollectionViewDataSourcePrefetching,
                                           UIAdaptivePresentationControllerDelegate>
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, strong) MTThemePreviewRepository *previewRepository;
@property(nonatomic, copy) NSArray<MTThemeLibraryThemeSummary *> *themes;
@property(nonatomic, copy, nullable) NSString *selectedThemeIdentifier;
@property(nonatomic, copy, nullable) NSString *activeThemeIdentifier;
@property(nonatomic, copy, nullable) NSString *activeRevisionIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeMixSelection *> *mixSelections;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *activeComponentSelection;
@property(nonatomic, strong, nullable) MTThemeMixSelection *activeMixSelection;
@property(nonatomic, strong, nullable) NSError *libraryError;
@property(nonatomic, assign) BOOL loadingLibrary;
@property(nonatomic, assign) BOOL applying;
@property(nonatomic, assign) BOOL runtimeControlAvailable;
@property(nonatomic, assign) BOOL hasAnimatedEntrance;
@property(nonatomic, assign) BOOL scrollToTopAfterNextReload;
@property(nonatomic, assign) BOOL presentingExternalImport;
@property(nonatomic, assign) BOOL managerProjectionPending;
@property(nonatomic, assign) BOOL visibleProjectionResumePending;

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) MTThemeHeroView *heroView;
@property(nonatomic, strong) UILabel *sectionTitleLabel;
@property(nonatomic, strong) UILabel *countLabel;
@property(nonatomic, strong) UICollectionView *themeCollectionView;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *themeItemByIdentifier;
@property(nonatomic, strong, nullable)
    MTThemePreviewRequest *selectedPreviewRequest;
@property(nonatomic, copy, nullable) NSString *selectedPreviewIdentity;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, MTThemePreviewRequest *> *prefetchRequests;
@property(nonatomic, strong) MTFloatingActionDockView *actionDock;
@property(nonatomic, strong) MTPressableButton *applyButton;
- (void)openSelectedThemeDetail:(id)sender;
- (void)closePresentedThemeDetail:(id)sender;
- (void)scheduleVisiblePreviewResumeAfterCatalogChange;
- (void)loadVisiblePreviewForCard:(MTThemeChoiceCard *)card
                  themeIdentifier:(NSString *)themeIdentifier;
@end

@implementation MTFoundationViewController

- (instancetype)init {
    NSError *error = nil;
    MTManagerController *controller =
        [MTManagerController defaultControllerWithError:&error];
    NSAssert(controller != nil, @"Unable to create Manager controller: %@",
             error);
    return [self initWithManagerController:controller];
}

- (instancetype)initWithManagerController:
        (MTManagerController *)managerController {
    NSParameterAssert(managerController != nil);
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _managerController = managerController;
        _previewRepository = [[MTThemePreviewRepository alloc]
            initWithLibraryStore:managerController.libraryStore];
        // The first Library snapshot normally arrives before the root page is
        // visible. Treat the initial appearance like every later resume so the
        // currently visible cards start their preview requests immediately;
        // otherwise only selecting a card would promote its placeholder.
        _visibleProjectionResumePending = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTCanvasColor();
    self.navigationItem.title = @"";
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.themes = @[];
    self.themeItemByIdentifier = @{};
    self.prefetchRequests = [NSMutableDictionary dictionary];

    MTPressableButton *settingsButton =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    settingsButton.accessibilityLabel = MTLocalized(@"home.open-settings");
    settingsButton.accessibilityIdentifier = @"marktheme.open-settings";
    UIButtonConfiguration *settingsConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    settingsConfiguration.image = [UIImage systemImageNamed:@"gearshape.fill"];
    settingsConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    settingsConfiguration.baseForegroundColor = MTAccentColor();
    settingsConfiguration.baseBackgroundColor = MTAccentColor();
    settingsButton.configuration = settingsConfiguration;
    [settingsButton addTarget:self action:@selector(openSettings:)
              forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [settingsButton.widthAnchor constraintEqualToConstant:36],
        [settingsButton.heightAnchor constraintEqualToConstant:36],
    ]];
    UIBarButtonItem *settingsItem =
        [[UIBarButtonItem alloc] initWithCustomView:settingsButton];

    MTPressableButton *libraryButton =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    libraryButton.accessibilityLabel = MTLocalized(@"home.open-library");
    libraryButton.accessibilityIdentifier = @"marktheme.open-library";
    UIButtonConfiguration *libraryConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    libraryConfiguration.image =
        [UIImage systemImageNamed:@"books.vertical.fill"];
    libraryConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    libraryConfiguration.baseForegroundColor = MTAccentColor();
    libraryConfiguration.baseBackgroundColor = MTAccentColor();
    libraryButton.configuration = libraryConfiguration;
    [libraryButton addTarget:self action:@selector(openThemeLibrary:)
             forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [libraryButton.widthAnchor constraintEqualToConstant:36],
        [libraryButton.heightAnchor constraintEqualToConstant:36],
    ]];
    UIBarButtonItem *libraryItem =
        [[UIBarButtonItem alloc] initWithCustomView:libraryButton];
    self.navigationItem.rightBarButtonItems = @[ settingsItem, libraryItem ];

    [self buildInterface];
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                          withHandler:^(
                              __unused id<UITraitEnvironment> environment,
                              __unused UITraitCollection *previous) {
            if (MTViewControllerCanApplyVisibleProjection(weakSelf)) {
                [weakSelf updatePresentationAnimated:NO];
            }
        }];
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(applicationDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(managerControllerDidChange:)
               name:MTManagerControllerDidChangeNotification
             object:self.managerController];
    [self consumeManagerSnapshot];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self cancelPreviewRequests];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self resumeVisibleProjectionIfNeeded];
    [self animateEntranceIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self suspendVisibleProjection];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self resumeVisibleProjectionIfNeeded];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self.managerController refreshRuntime];
}

- (void)buildInterface {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.accessibilityIdentifier = @"marktheme.home";
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"MarkTheme";
    self.titleLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.labelColor;
    [self.contentView addSubview:self.titleLabel];

    self.subtitleLabel = MTLabel(UIFontTextStyleSubheadline,
                                 UIFontWeightRegular,
                                 UIColor.secondaryLabelColor);
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.text = MTLocalized(@"home.subtitle");
    [self.contentView addSubview:self.subtitleLabel];

    self.heroView = [[MTThemeHeroView alloc] initWithFrame:CGRectZero];
    self.heroView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.heroView.detailButton addTarget:self
                                   action:@selector(openSelectedThemeDetail:)
                         forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.heroView];

    self.sectionTitleLabel = MTLabel(UIFontTextStyleTitle3,
                                     UIFontWeightBold,
                                     UIColor.labelColor);
    self.sectionTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sectionTitleLabel.text = MTLocalized(@"home.choose-theme");
    [self.contentView addSubview:self.sectionTitleLabel];

    self.countLabel = MTLabel(UIFontTextStyleCaption1,
                              UIFontWeightSemibold,
                              UIColor.tertiaryLabelColor);
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:self.countLabel];

    UICollectionViewFlowLayout *themeLayout =
        [[UICollectionViewFlowLayout alloc] init];
    themeLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    themeLayout.itemSize = CGSizeMake(150.0, 220.0);
    themeLayout.minimumLineSpacing = 12.0;
    themeLayout.minimumInteritemSpacing = 0.0;
    themeLayout.sectionInset = UIEdgeInsetsMake(5.0, 20.0, 5.0, 20.0);
    self.themeCollectionView = [[UICollectionView alloc]
        initWithFrame:CGRectZero collectionViewLayout:themeLayout];
    self.themeCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.themeCollectionView.backgroundColor = UIColor.clearColor;
    self.themeCollectionView.showsHorizontalScrollIndicator = NO;
    self.themeCollectionView.alwaysBounceHorizontal = YES;
    self.themeCollectionView.decelerationRate = UIScrollViewDecelerationRateFast;
    self.themeCollectionView.dataSource = self;
    self.themeCollectionView.delegate = self;
    self.themeCollectionView.prefetchDataSource = self;
    self.themeCollectionView.accessibilityIdentifier =
        @"marktheme.theme-carousel";
    [self.themeCollectionView registerClass:MTThemeChoiceCard.class
                 forCellWithReuseIdentifier:MTThemeChoiceCardReuseIdentifier];
    [self.contentView addSubview:self.themeCollectionView];

    self.actionDock = [[MTFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionDock];

    self.applyButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    self.applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.applyButton.accessibilityIdentifier = @"marktheme.theme.apply";
    [self.applyButton addTarget:self action:@selector(applySelection:)
               forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.applyButton];

    UILayoutGuide *contentGuide = self.scrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = self.scrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentView.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor],
        [self.contentView.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor],
        [self.contentView.topAnchor constraintEqualToAnchor:contentGuide.topAnchor],
        [self.contentView.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                     constant:20],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                 constant:8],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:
            self.contentView.trailingAnchor constant:-20],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                          constant:-20],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor
                                                     constant:2],

        [self.heroView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:20],
        [self.heroView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                     constant:-20],
        [self.heroView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor
                                                constant:18],
        [self.heroView.heightAnchor
            constraintGreaterThanOrEqualToConstant:236],

        [self.sectionTitleLabel.leadingAnchor constraintEqualToAnchor:self.heroView.leadingAnchor],
        [self.sectionTitleLabel.topAnchor constraintEqualToAnchor:self.heroView.bottomAnchor
                                                         constant:24],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:self.heroView.trailingAnchor],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:self.sectionTitleLabel.centerYAnchor],
        [self.countLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:
            self.sectionTitleLabel.trailingAnchor constant:8],

        [self.themeCollectionView.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.themeCollectionView.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.themeCollectionView.topAnchor
            constraintEqualToAnchor:self.sectionTitleLabel.bottomAnchor
                             constant:13],
        [self.themeCollectionView.heightAnchor constraintEqualToConstant:230],
        [self.themeCollectionView.bottomAnchor constraintEqualToAnchor:
            self.contentView.bottomAnchor constant:-24],

        [self.actionDock.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.actionDock.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.actionDock.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.applyButton.leadingAnchor constraintEqualToAnchor:self.actionDock.leadingAnchor
                                                       constant:20],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:self.actionDock.trailingAnchor
                                                        constant:-20],
        [self.applyButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor
                                                   constant:14],
        [self.applyButton.heightAnchor constraintEqualToConstant:56],
        [self.applyButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                      constant:-12],
    ]];
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
    BOOL catalogChanged = self.themes != snapshot.themes;
    NSString *previousSelectedThemeIdentifier = self.selectedThemeIdentifier;
    NSString *previousActiveThemeIdentifier = self.activeThemeIdentifier;
    BOOL selectedThemeChanged = !MTThemeIdentifiersEqual(
        previousSelectedThemeIdentifier, snapshot.selectedThemeIdentifier);
    BOOL activeThemeChanged = !MTThemeIdentifiersEqual(
        previousActiveThemeIdentifier, snapshot.activeThemeIdentifier);
    BOOL componentSelectionsChanged =
        self.componentSelections !=
            snapshot.componentSelectionsByThemeIdentifier &&
        ![self.componentSelections isEqual:
            snapshot.componentSelectionsByThemeIdentifier];
    BOOL activeComponentSelectionChanged =
        self.activeComponentSelection != snapshot.activeComponentSelection &&
        ![self.activeComponentSelection isEqual:
            snapshot.activeComponentSelection];
    BOOL mixSelectionsChanged = self.mixSelections !=
            snapshot.mixSelectionsByThemeIdentifier &&
        ![self.mixSelections isEqual:
            snapshot.mixSelectionsByThemeIdentifier];
    BOOL activeMixSelectionChanged = self.activeMixSelection !=
            snapshot.activeMixSelection &&
        ![self.activeMixSelection isEqual:snapshot.activeMixSelection];
    BOOL presentationChanged = catalogChanged ||
        self.loadingLibrary != snapshot.isLibraryRefreshing ||
        self.applying !=
            (snapshot.isMutating || snapshot.isRuntimeRefreshing) ||
        self.runtimeControlAvailable != snapshot.runtimeControlAvailable ||
        self.libraryError != snapshot.libraryError ||
        selectedThemeChanged || activeThemeChanged ||
        componentSelectionsChanged || activeComponentSelectionChanged ||
        mixSelectionsChanged || activeMixSelectionChanged ||
        !MTThemeIdentifiersEqual(self.activeRevisionIdentifier,
                                 snapshot.activeRevisionIdentifier);
    self.loadingLibrary = snapshot.isLibraryRefreshing;
    self.applying = snapshot.isMutating || snapshot.isRuntimeRefreshing;
    self.runtimeControlAvailable = snapshot.runtimeControlAvailable;
    self.libraryError = snapshot.libraryError;
    self.themes = snapshot.themes;
    self.selectedThemeIdentifier = snapshot.selectedThemeIdentifier;
    self.activeThemeIdentifier = snapshot.activeThemeIdentifier;
    self.activeRevisionIdentifier = snapshot.activeRevisionIdentifier;
    self.componentSelections =
        snapshot.componentSelectionsByThemeIdentifier;
    self.activeComponentSelection = snapshot.activeComponentSelection;
    self.mixSelections = snapshot.mixSelectionsByThemeIdentifier;
    self.activeMixSelection = snapshot.activeMixSelection;
    if (catalogChanged) {
        [self reloadThemeCollection];
        [self scheduleVisiblePreviewResumeAfterCatalogChange];
    }
    if (catalogChanged) {
        [self updatePresentationAnimated:NO];
    } else if (presentationChanged) {
        [self updateHeroAndApplyPresentationAnimated:NO];
        if (selectedThemeChanged || activeThemeChanged ||
            componentSelectionsChanged || activeComponentSelectionChanged ||
            mixSelectionsChanged || activeMixSelectionChanged) {
            NSMutableOrderedSet *affectedIdentifiers =
                [NSMutableOrderedSet orderedSet];
            [affectedIdentifiers addObject:
                previousSelectedThemeIdentifier ?: NSNull.null];
            [affectedIdentifiers addObject:
                self.selectedThemeIdentifier ?: NSNull.null];
            [affectedIdentifiers addObject:
                previousActiveThemeIdentifier ?: NSNull.null];
            [affectedIdentifiers addObject:
                self.activeThemeIdentifier ?: NSNull.null];
            for (id value in affectedIdentifiers) {
                [self updateThemeCardForIdentifier:
                    value == NSNull.null ? nil : value
                                          animated:NO];
            }
        }
    }
    [self loadPreviewForSelectedThemeIfNeeded];
    if (selectedThemeChanged && previousSelectedThemeIdentifier.length > 0) {
        [self loadVisiblePreviewForThemeIdentifier:
            previousSelectedThemeIdentifier];
    }
    if (!snapshot.isLibraryRefreshing && self.scrollToTopAfterNextReload) {
        self.scrollToTopAfterNextReload = NO;
        CGPoint top = CGPointMake(0, -self.scrollView.adjustedContentInset.top);
        [self.scrollView setContentOffset:top animated:NO];
    }
}

- (BOOL)containsThemeIdentifier:(NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return NO;
    return [self summaryForThemeIdentifier:themeIdentifier] != nil;
}

- (MTThemeLibraryThemeSummary *)summaryForThemeIdentifier:
        (NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return nil;
    return [self.managerController.snapshot
        themeWithIdentifier:themeIdentifier];
}

- (void)reloadThemeCollection {
    [self cancelPreviewRequests];
    NSMutableDictionary<NSString *, NSNumber *> *items =
        [NSMutableDictionary dictionaryWithCapacity:self.themes.count];
    [self.themes enumerateObjectsUsingBlock:
        ^(MTThemeLibraryThemeSummary *summary, NSUInteger index,
          __unused BOOL *stop) {
        items[summary.themeID] = @(index + 1);
    }];
    self.themeItemByIdentifier = items;
    [self.themeCollectionView reloadData];
    self.countLabel.text = [NSString stringWithFormat:MTLocalized(@"home.theme-count"),
        (unsigned long)(self.themes.count + 1)];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.themes.count + 1;
}

- (NSString *)themeIdentifierAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.item == 0) return nil;
    NSUInteger themeIndex = (NSUInteger)indexPath.item - 1;
    return themeIndex < self.themes.count
        ? self.themes[themeIndex].themeID : nil;
}

- (NSIndexPath *)indexPathForThemeIdentifier:(NSString *)themeIdentifier {
    if (themeIdentifier == nil) {
        return [NSIndexPath indexPathForItem:0 inSection:0];
    }
    NSNumber *item = self.themeItemByIdentifier[themeIdentifier];
    return item == nil ? nil
        : [NSIndexPath indexPathForItem:item.integerValue inSection:0];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MTThemeChoiceCard *card = [collectionView
        dequeueReusableCellWithReuseIdentifier:MTThemeChoiceCardReuseIdentifier
                                  forIndexPath:indexPath];
    [self configureThemeCard:card
             themeIdentifier:[self themeIdentifierAtIndexPath:indexPath]
                    animated:NO];
    return card;
}

- (void)configureThemeCard:(MTThemeChoiceCard *)card
           themeIdentifier:(NSString *)themeIdentifier
                  animated:(BOOL)animated {
    MTThemeLibraryThemeSummary *summary =
        [self summaryForThemeIdentifier:themeIdentifier];
    NSString *name = summary == nil
        ? MTLocalized(@"theme.stock.name")
        : summary.currentRevision.manifest.displayName;
    NSString *detail = summary == nil
        ? MTLocalized(@"theme.stock.card-detail")
        : [NSString stringWithFormat:MTLocalized(@"theme.card.resource-count"),
            (unsigned long)summary.currentRevision.manifest.resources.count];
    NSArray<UIImage *> *images = themeIdentifier == nil
        ? MTSystemDefaultPreviewImages()
        : [self.previewRepository presentationImagesForThemeSummary:summary];
    card.accessibilityIdentifier = themeIdentifier == nil
        ? @"marktheme.theme.stock"
        : [@"marktheme.theme." stringByAppendingString:themeIdentifier];
    [card configureWithThemeIdentifier:themeIdentifier
             previewRevisionIdentifier:
                 summary.currentRevision.revisionIdentifier
                                  name:name
                                detail:detail
                            iconImages:images
                               current:themeIdentifier == nil
                                   ? !self.managerController.snapshot.runtimeEnabled
                                   : [self.managerController.snapshot
                                       runtimeMatchesCurrentSelectionForThemeIdentifier:
                                           themeIdentifier]
                                chosen:MTThemeIdentifiersEqual(
                                   themeIdentifier, self.selectedThemeIdentifier)
                              animated:animated];
}

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    NSString *identifier = [self themeIdentifierAtIndexPath:indexPath];
    if (MTThemeIdentifiersEqual(identifier, self.selectedThemeIdentifier)) {
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        return;
    }
    [self.managerController selectThemeIdentifier:identifier];
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
}

- (void)updateHeroAndApplyPresentationAnimated:(BOOL)animated {
    MTThemeLibraryThemeSummary *selected =
        [self summaryForThemeIdentifier:self.selectedThemeIdentifier];
    NSString *name = selected == nil
        ? MTLocalized(@"theme.stock.name")
        : selected.currentRevision.manifest.displayName;
    NSString *detail = selected == nil
        ? MTLocalized(@"theme.stock.detail")
        : MTThemeSecondaryText(selected.currentRevision.manifest);
    NSUInteger resourceCount = selected == nil
        ? 0
        : selected.currentRevision.manifest.resources.count;
    NSArray<UIImage *> *images = self.selectedThemeIdentifier == nil
        ? MTSystemDefaultPreviewImages()
        : [self.previewRepository presentationImagesForThemeSummary:selected];
    BOOL exactRevisionActive = self.selectedThemeIdentifier == nil
        ? !self.managerController.snapshot.runtimeEnabled
        : [self.managerController.snapshot
            runtimeMatchesCurrentSelectionForThemeIdentifier:
                self.selectedThemeIdentifier];
    [self.heroView configureWithThemeIdentifier:self.selectedThemeIdentifier
                      previewRevisionIdentifier:
                          selected.currentRevision.revisionIdentifier
                                           name:name
                                         detail:detail
                                  resourceCount:resourceCount
                                     iconImages:images
                                        current:exactRevisionActive
                                       animated:animated];

    UIButtonConfiguration *configuration =
        [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.imagePadding = 8;
    if (self.loadingLibrary) {
        configuration.title = MTLocalized(@"home.loading-library");
        configuration.image = [UIImage systemImageNamed:@"hourglass"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (self.applying) {
        configuration.title = MTLocalized(@"apply.preparing");
        configuration.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (!self.runtimeControlAvailable &&
               !(self.themes.count == 0 &&
                 self.selectedThemeIdentifier == nil)) {
        configuration.title = MTLocalized(@"apply.runtime-unavailable");
        configuration.image = [UIImage systemImageNamed:@"iphone.slash"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (self.libraryError != nil && self.themes.count == 0) {
        configuration.title = MTLocalized(@"home.library-unavailable");
        configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (self.themes.count == 0 && self.selectedThemeIdentifier == nil) {
        configuration.title = MTLocalized(@"home.import-first-theme");
        configuration.image = [UIImage systemImageNamed:@"plus"];
        configuration.baseBackgroundColor = MTPrimaryActionColor();
        configuration.baseForegroundColor = MTPrimaryActionForegroundColor();
        self.applyButton.enabled = YES;
    } else if (exactRevisionActive) {
        configuration.title = [NSString stringWithFormat:
            MTLocalized(@"apply.current-format"), name];
        configuration.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        configuration.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        configuration.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else {
        configuration.title = self.selectedThemeIdentifier == nil
            ? MTLocalized(@"apply.restore-stock")
            : [NSString stringWithFormat:MTLocalized(@"apply.theme-format"), name];
        configuration.image = self.selectedThemeIdentifier == nil
            ? [UIImage systemImageNamed:@"arrow.uturn.backward"]
            : [UIImage systemImageNamed:@"arrow.right"];
        configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
        configuration.baseBackgroundColor = MTPrimaryActionColor();
        configuration.baseForegroundColor = MTPrimaryActionForegroundColor();
        self.applyButton.enabled = YES;
    }
    self.applyButton.configuration = configuration;
}

- (void)updateThemeCardForIdentifier:(NSString *)themeIdentifier
                            animated:(BOOL)animated {
    NSIndexPath *indexPath =
        [self indexPathForThemeIdentifier:themeIdentifier];
    MTThemeChoiceCard *card = indexPath == nil ? nil
        : (MTThemeChoiceCard *)[self.themeCollectionView
            cellForItemAtIndexPath:indexPath];
    if (card == nil) return;
    [self configureThemeCard:card
             themeIdentifier:themeIdentifier
                    animated:animated];
}

- (void)updatePresentationAnimated:(BOOL)animated {
    [self updateHeroAndApplyPresentationAnimated:animated];
    for (MTThemeChoiceCard *card in self.themeCollectionView.visibleCells) {
        [self configureThemeCard:card
                 themeIdentifier:card.themeIdentifier
                        animated:animated];
    }
}

- (void)startPreviewRequestsForVisibleItems {
    [self loadPreviewForSelectedThemeIfNeeded];
    for (MTThemeChoiceCard *card in self.themeCollectionView.visibleCells) {
        if (!MTThemeIdentifiersEqual(card.themeIdentifier,
                                     self.selectedThemeIdentifier)) {
            [self loadVisiblePreviewForCard:card
                            themeIdentifier:card.themeIdentifier];
        }
    }
}

- (void)cancelPreviewRequests {
    [self.selectedPreviewRequest cancel];
    self.selectedPreviewRequest = nil;
    self.selectedPreviewIdentity = nil;
    for (MTThemePreviewRequest *request in self.prefetchRequests.allValues) {
        [request cancel];
    }
    [self.prefetchRequests removeAllObjects];
    for (MTThemeChoiceCard *card in self.themeCollectionView.visibleCells) {
        [card.previewRequest cancel];
        card.previewRequest = nil;
    }
}

- (void)suspendVisibleProjection {
    self.visibleProjectionResumePending = YES;
    [self cancelPreviewRequests];
}

- (void)scheduleVisiblePreviewResumeAfterCatalogChange {
    // The cold-start Catalog normally arrives after the initial appearance
    // consumed its resume flag. reloadData creates the real theme cells on the
    // next layout pass, so resume once after that pass instead of waiting for
    // a user selection to start their preview requests.
    self.visibleProjectionResumePending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil ||
            !MTViewControllerCanApplyVisibleProjection(self)) return;
        [self.themeCollectionView layoutIfNeeded];
        // viewDidLayoutSubviews may consume the pending flag before reloadData
        // has produced its new cells. This catalog-specific pass runs after
        // collection layout and does not depend on that flag.
        self.visibleProjectionResumePending = NO;
        [self updatePresentationAnimated:NO];
        [self startPreviewRequestsForVisibleItems];
    });
}

- (void)resumeVisibleProjectionIfNeeded {
    if (!MTViewControllerCanApplyVisibleProjection(self) ||
        (!self.managerProjectionPending &&
         !self.visibleProjectionResumePending)) {
        return;
    }
    BOOL consumesManagerProjection = self.managerProjectionPending;
    BOOL resumesPreviewRequests = self.visibleProjectionResumePending;
    self.managerProjectionPending = NO;
    self.visibleProjectionResumePending = NO;
    if (consumesManagerProjection) [self consumeManagerSnapshot];
    if (resumesPreviewRequests) {
        [self updatePresentationAnimated:NO];
        [self startPreviewRequestsForVisibleItems];
    }
}

- (dispatch_block_t)visibleProjectionDismissalHandler {
    __weak typeof(self) weakSelf = self;
    return ^{
        [weakSelf resumeVisibleProjectionIfNeeded];
    };
}

- (void)presentationControllerDidDismiss:
        (UIPresentationController *)presentationController {
    (void)presentationController;
    [self resumeVisibleProjectionIfNeeded];
}

- (void)loadPreviewForSelectedThemeIfNeeded {
    NSString *themeIdentifier = self.selectedThemeIdentifier;
    MTThemeLibraryThemeSummary *summary =
        [self summaryForThemeIdentifier:themeIdentifier];
    if (summary == nil) {
        [self.selectedPreviewRequest cancel];
        self.selectedPreviewRequest = nil;
        self.selectedPreviewIdentity = nil;
        return;
    }
    NSString *revisionIdentifier =
        summary.currentRevision.revisionIdentifier;
    NSString *identity = [NSString stringWithFormat:@"%@|%@",
        themeIdentifier, revisionIdentifier];
    if ([self.previewRepository cachedImagesForThemeSummary:summary] != nil) {
        [self.selectedPreviewRequest cancel];
        self.selectedPreviewRequest = nil;
        self.selectedPreviewIdentity = nil;
        return;
    }
    if (self.selectedPreviewRequest != nil &&
        [self.selectedPreviewIdentity isEqualToString:identity]) return;
    __weak typeof(self) weakSelf = self;
    MTThemePreviewRequest *previousRequest = self.selectedPreviewRequest;
    __block MTThemePreviewRequest *request = nil;
    request = [self.previewRepository loadImagesForThemeSummary:summary
        priority:MTThemePreviewPriorityHigh
        completion:^(__unused NSArray<UIImage *> *images) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        if (self.selectedPreviewRequest == request) {
            self.selectedPreviewRequest = nil;
            self.selectedPreviewIdentity = nil;
        }
        if (!MTViewControllerCanApplyVisibleProjection(self)) return;
        MTThemeLibraryThemeSummary *current =
            [self summaryForThemeIdentifier:themeIdentifier];
        if (![current.currentRevision.revisionIdentifier
                isEqualToString:revisionIdentifier]) return;
        [self updateThemeCardForIdentifier:themeIdentifier animated:YES];
        if (MTThemeIdentifiersEqual(themeIdentifier,
                                    self.selectedThemeIdentifier)) {
            [self updateHeroAndApplyPresentationAnimated:YES];
        }
    }];
    self.selectedPreviewRequest = request;
    self.selectedPreviewIdentity = identity;
    [previousRequest cancel];
    MTThemePreviewRequest *prefetch = self.prefetchRequests[themeIdentifier];
    [self.prefetchRequests removeObjectForKey:themeIdentifier];
    [prefetch cancel];
    NSIndexPath *indexPath =
        [self indexPathForThemeIdentifier:themeIdentifier];
    MTThemeChoiceCard *visibleCard = indexPath == nil ? nil
        : (MTThemeChoiceCard *)[self.themeCollectionView
            cellForItemAtIndexPath:indexPath];
    [visibleCard.previewRequest cancel];
    visibleCard.previewRequest = nil;
}

- (void)loadVisiblePreviewForThemeIdentifier:(NSString *)themeIdentifier {
    if (themeIdentifier.length == 0 ||
        MTThemeIdentifiersEqual(themeIdentifier,
                                self.selectedThemeIdentifier)) return;
    NSIndexPath *indexPath =
        [self indexPathForThemeIdentifier:themeIdentifier];
    MTThemeChoiceCard *card = indexPath == nil ? nil
        : (MTThemeChoiceCard *)[self.themeCollectionView
            cellForItemAtIndexPath:indexPath];
    if (card == nil) return;
    [self loadVisiblePreviewForCard:card themeIdentifier:themeIdentifier];
}

- (void)loadVisiblePreviewForCard:(MTThemeChoiceCard *)card
                  themeIdentifier:(NSString *)themeIdentifier {
    if (card == nil || themeIdentifier.length == 0 ||
        MTThemeIdentifiersEqual(themeIdentifier,
                                self.selectedThemeIdentifier)) return;
    MTThemeLibraryThemeSummary *summary =
        [self summaryForThemeIdentifier:themeIdentifier];
    if (summary == nil) return;
    if ([self.previewRepository cachedImagesForThemeSummary:summary] != nil) {
        [card.previewRequest cancel];
        card.previewRequest = nil;
        return;
    }
    if (card.previewRequest != nil) return;
    NSString *revisionIdentifier =
        summary.currentRevision.revisionIdentifier;
    __weak typeof(self) weakSelf = self;
    __block MTThemePreviewRequest *request = nil;
    request = [self.previewRepository loadImagesForThemeSummary:summary
        priority:MTThemePreviewPriorityNormal
        completion:^(__unused NSArray<UIImage *> *images) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        if (card.previewRequest == request) card.previewRequest = nil;
        if (!MTViewControllerCanApplyVisibleProjection(self)) return;
        MTThemeLibraryThemeSummary *current =
            [self summaryForThemeIdentifier:themeIdentifier];
        if (![current.currentRevision.revisionIdentifier
                isEqualToString:revisionIdentifier]) return;
        [self updateThemeCardForIdentifier:themeIdentifier animated:YES];
    }];
    card.previewRequest = request;
    MTThemePreviewRequest *prefetch = self.prefetchRequests[themeIdentifier];
    [self.prefetchRequests removeObjectForKey:themeIdentifier];
    [prefetch cancel];
}

- (void)collectionView:(UICollectionView *)collectionView
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    (void)cell;
    NSString *themeIdentifier = [self themeIdentifierAtIndexPath:indexPath];
    if (MTThemeIdentifiersEqual(themeIdentifier,
                                self.selectedThemeIdentifier)) {
        [self loadPreviewForSelectedThemeIfNeeded];
    } else {
        // UIKit can deliver willDisplay before cellForItemAtIndexPath: starts
        // returning this cell, so use the callback's cell directly.
        [self loadVisiblePreviewForCard:(MTThemeChoiceCard *)cell
                        themeIdentifier:themeIdentifier];
    }
}

- (void)collectionView:(UICollectionView *)collectionView
  didEndDisplayingCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    (void)indexPath;
    MTThemeChoiceCard *card = (MTThemeChoiceCard *)cell;
    [card.previewRequest cancel];
    card.previewRequest = nil;
}

- (void)collectionView:(UICollectionView *)collectionView
    prefetchItemsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    (void)collectionView;
    for (NSIndexPath *indexPath in indexPaths) {
        NSString *themeIdentifier = [self themeIdentifierAtIndexPath:indexPath];
        if (themeIdentifier.length == 0 ||
            MTThemeIdentifiersEqual(themeIdentifier,
                                    self.selectedThemeIdentifier) ||
            self.prefetchRequests[themeIdentifier] != nil) continue;
        MTThemeLibraryThemeSummary *summary =
            [self summaryForThemeIdentifier:themeIdentifier];
        if (summary == nil ||
            [self.previewRepository cachedImagesForThemeSummary:summary] != nil) {
            continue;
        }
        NSString *revisionIdentifier =
            summary.currentRevision.revisionIdentifier;
        __weak typeof(self) weakSelf = self;
        __block MTThemePreviewRequest *request = nil;
        request = [self.previewRepository loadImagesForThemeSummary:summary
            priority:MTThemePreviewPriorityLow
            completion:^(__unused NSArray<UIImage *> *images) {
            typeof(self) self = weakSelf;
            if (self == nil) return;
            if (self.prefetchRequests[themeIdentifier] == request) {
                [self.prefetchRequests removeObjectForKey:themeIdentifier];
            }
            if (!MTViewControllerCanApplyVisibleProjection(self)) return;
            MTThemeLibraryThemeSummary *current =
                [self summaryForThemeIdentifier:themeIdentifier];
            if (![current.currentRevision.revisionIdentifier
                    isEqualToString:revisionIdentifier]) return;
            [self updateThemeCardForIdentifier:themeIdentifier animated:YES];
        }];
        self.prefetchRequests[themeIdentifier] = request;
    }
}

- (void)collectionView:(UICollectionView *)collectionView
    cancelPrefetchingForItemsAtIndexPaths:
        (NSArray<NSIndexPath *> *)indexPaths {
    (void)collectionView;
    for (NSIndexPath *indexPath in indexPaths) {
        NSString *themeIdentifier = [self themeIdentifierAtIndexPath:indexPath];
        if (themeIdentifier.length == 0) continue;
        MTThemePreviewRequest *request =
            self.prefetchRequests[themeIdentifier];
        [self.prefetchRequests removeObjectForKey:themeIdentifier];
        [request cancel];
    }
}

- (void)applySelection:(id)sender {
    (void)sender;
    if (self.themes.count == 0 && self.selectedThemeIdentifier == nil) {
        [self openThemeLibrary:nil];
        return;
    }
    if (self.applying) return;
    NSString *themeIdentifier = [self.selectedThemeIdentifier copy];
    MTThemeLibraryThemeSummary *summary =
        [self summaryForThemeIdentifier:themeIdentifier];
    NSString *themeName = summary == nil
        ? MTLocalized(@"theme.stock.name")
        : summary.currentRevision.manifest.displayName;
    __weak typeof(self) weakSelf = self;
    [self.managerController applySelectionWithCompletion:
        ^(BOOL success, NSError *error) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        if (!success) {
            [self presentApplyError:error];
            return;
        }
        [[[UINotificationFeedbackGenerator alloc] init]
            notificationOccurred:UINotificationFeedbackTypeSuccess];
        MTApplyResultViewController *resultController =
            [[MTApplyResultViewController alloc]
                initWithThemeName:themeName
                  restoredStock:themeIdentifier == nil
               managerController:self.managerController];
        resultController.dismissalHandler =
            [self visibleProjectionDismissalHandler];
        resultController.presentationController.delegate = self;
        [self suspendVisibleProjection];
        [self presentViewController:resultController
                           animated:YES completion:nil];
    }];
}

- (void)presentApplyError:(NSError *)error {
    NSLog(@"MarkTheme Apply failed (%@/%ld): %@", error.domain,
          (long)error.code, error.localizedDescription);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTLocalized(@"apply.error.title")
                         message:MTErrorPresentationMessage(
                             MTLocalized(@"apply.error.detail"), error)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MTLocalized(@"common.ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openSelectedThemeDetail:(id)sender {
    (void)sender;
    NSString *themeIdentifier = [self.selectedThemeIdentifier copy];
    if (themeIdentifier.length == 0 ||
        [self summaryForThemeIdentifier:themeIdentifier] == nil) {
        return;
    }
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    MTThemeDetailViewController *detail = [[MTThemeDetailViewController alloc]
        initWithManagerController:self.managerController
              previewRepository:self.previewRepository
                  themeIdentifier:themeIdentifier];
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closePresentedThemeDetail:)];
    closeItem.accessibilityIdentifier = @"marktheme.theme-detail.close";
    detail.navigationItem.leftBarButtonItem = closeItem;

    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:detail];
    MTConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    if (navigation.sheetPresentationController != nil) {
        navigation.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.largeDetent,
        ];
    }
    navigation.presentationController.delegate = self;
    [self suspendVisibleProjection];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)closePresentedThemeDetail:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES
                             completion:[self visibleProjectionDismissalHandler]];
}

- (void)openThemeLibrary:(id)sender {
    (void)sender;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    __weak typeof(self) weakSelf = self;
    MTThemeLibraryViewController *library =
        [[MTThemeLibraryViewController alloc]
            initWithManagerController:self.managerController
            previewRepository:self.previewRepository
            selectedThemeIdentifier:self.selectedThemeIdentifier
            selectionHandler:^(NSString *themeIdentifier) {
        (void)themeIdentifier;
        weakSelf.scrollToTopAfterNextReload = YES;
    }];
    library.dismissalHandler = [self visibleProjectionDismissalHandler];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:library];
    MTConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    if (navigation.sheetPresentationController != nil) {
        navigation.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.largeDetent,
        ];
    }
    navigation.presentationController.delegate = self;
    [self suspendVisibleProjection];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)openSettings:(id)sender {
    (void)sender;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    MTSettingsViewController *settings = [[MTSettingsViewController alloc]
        initWithManagerController:self.managerController];
    settings.dismissalHandler = [self visibleProjectionDismissalHandler];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:settings];
    MTConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    if (navigation.sheetPresentationController != nil) {
        navigation.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.largeDetent,
        ];
    }
    navigation.presentationController.delegate = self;
    [self suspendVisibleProjection];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentImportForURL:(NSURL *)url {
    MTImportDiagnosticsRecord(@"external-import.present-request", @{
        @"isFileURL" : @(url.isFileURL),
        @"path" : url.path ?: @"",
        @"presentedController" : self.presentedViewController == nil
            ? @"<none>" : NSStringFromClass(self.presentedViewController.class),
    });
    if (!url.isFileURL) return;
    UIViewController *presenter = self;
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
        UINavigationController *navigation =
            [presenter isKindOfClass:UINavigationController.class]
                ? (UINavigationController *)presenter : nil;
        if ([navigation.viewControllers.firstObject
                isKindOfClass:MTImportViewController.class]) {
            return;
        }
    }
    if (self.presentingExternalImport) return;
    self.presentingExternalImport = YES;
    __weak typeof(self) weakSelf = self;
    MTImportViewController *importController = [[MTImportViewController alloc]
        initWithCompletionHandler:^(NSString *themeIdentifier) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        self.scrollToTopAfterNextReload = YES;
        [self.managerController
            reloadSelectingThemeIdentifier:themeIdentifier];
    }];
    importController.dismissalHandler =
        [self visibleProjectionDismissalHandler];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:importController];
    MTConfigureNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.view.accessibilityViewIsModal = YES;
    if (navigation.sheetPresentationController != nil) {
        navigation.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.largeDetent,
        ];
    }
    navigation.presentationController.delegate = self;
    [self suspendVisibleProjection];
    [presenter presentViewController:navigation animated:YES completion:^{
        weakSelf.presentingExternalImport = NO;
        MTImportDiagnosticsRecord(@"external-import.presented", nil);
    }];
    // Acquire the external URL while the open-URL handoff is still active.
    // Waiting for the sheet animation to finish let iOS 18 revoke a provider
    // URL before the asynchronous import worker could start its private copy.
    [importController startImportAtURL:url];
}

- (void)animateEntranceIfNeeded {
    if (self.hasAnimatedEntrance || UIAccessibilityIsReduceMotionEnabled()) {
        self.hasAnimatedEntrance = YES;
        return;
    }
    self.hasAnimatedEntrance = YES;
    NSArray<UIView *> *views = @[
        self.titleLabel,
        self.subtitleLabel,
        self.heroView,
        self.sectionTitleLabel,
        self.themeCollectionView,
    ];
    for (UIView *view in views) {
        view.alpha = 0.0;
        view.transform = CGAffineTransformMakeTranslation(0, 12);
    }
    [views enumerateObjectsUsingBlock:^(UIView *view,
                                        NSUInteger index,
                                        BOOL *stop) {
        (void)stop;
        [UIView animateWithDuration:0.42
                              delay:0.035 * index
             usingSpringWithDamping:0.94
              initialSpringVelocity:0.15
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            view.alpha = 1.0;
            view.transform = CGAffineTransformIdentity;
        }
                         completion:nil];
    }];
}

@end
