#import "MTApplyResultViewController.h"

#import <math.h>

#import "MTDesignSystem.h"
#import "MTManagerController.h"

static NSString *MTApplyResultLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

@interface MTApplyResultViewController ()
@property(nonatomic, copy) NSString *themeName;
@property(nonatomic, assign) BOOL restoredStock;
@property(nonatomic, assign) BOOL reloadRequired;
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, strong) UIScrollView *contentScrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) MTFloatingActionDockView *actionDock;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UILabel *statusTitle;
@property(nonatomic, strong) UILabel *statusDetail;
@property(nonatomic, strong) MTPressableButton *primaryButton;
@property(nonatomic, strong) MTPressableButton *secondaryButton;
@property(nonatomic, assign) BOOL requestingReload;
@property(nonatomic, assign) CGFloat preferredSheetHeight;
@property(nonatomic, assign) CGFloat measuredSheetWidth;
@property(nonatomic, assign) CGFloat measuredDockHeight;
@property(nonatomic, assign) CGFloat appliedDockInset;
@property(nonatomic, assign) BOOL sheetMeasurementInvalidated;
@end

@implementation MTApplyResultViewController

- (instancetype)initWithThemeName:(NSString *)themeName
                    restoredStock:(BOOL)restoredStock
                   reloadRequired:(BOOL)reloadRequired
                 managerController:(MTManagerController *)managerController {
    NSParameterAssert(themeName.length > 0);
    NSParameterAssert(managerController != nil);
    self = [super initWithNibName:nil bundle:nil];
    if (self == nil) return nil;
    _themeName = [themeName copy];
    _restoredStock = restoredStock;
    _reloadRequired = reloadRequired;
    _managerController = managerController;
    _sheetMeasurementInvalidated = YES;
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTCanvasColor();
    self.view.accessibilityViewIsModal = YES;

    self.contentScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.contentScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentScrollView.alwaysBounceVertical = NO;
    self.contentScrollView.showsVerticalScrollIndicator = NO;
    self.contentScrollView.accessibilityIdentifier =
        @"marktheme64e.apply-result.content";
    [self.view addSubview:self.contentScrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentScrollView addSubview:self.contentView];

    UIView *iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    iconBackground.backgroundColor = MTTintedBackground(MTSuccessColor());
    iconBackground.layer.cornerRadius = 28.0;
    iconBackground.layer.cornerCurve = kCACornerCurveContinuous;

    UIImageView *resultIcon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark"
            withConfiguration:[UIImageSymbolConfiguration
                configurationWithPointSize:23
                                      weight:UIImageSymbolWeightSemibold]]];
    resultIcon.translatesAutoresizingMaskIntoConstraints = NO;
    resultIcon.tintColor = MTSuccessColor();
    [iconBackground addSubview:resultIcon];

    UILabel *eyebrow = MTLabel(UIFontTextStyleSubheadline,
                               UIFontWeightSemibold, MTSuccessColor());
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = self.restoredStock
        ? MTApplyResultLocalized(@"apply.result.stock-eyebrow")
        : MTApplyResultLocalized(@"apply.result.theme-eyebrow");

    UILabel *title = MTLabel(UIFontTextStyleTitle1, UIFontWeightBold,
                             UIColor.labelColor);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.themeName;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.76;

    UIStackView *titleStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[ eyebrow, title ]];
    titleStack.translatesAutoresizingMaskIntoConstraints = NO;
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.alignment = UIStackViewAlignmentFill;
    titleStack.spacing = 0.0;

    UIStackView *header = [[UIStackView alloc]
        initWithArrangedSubviews:@[ iconBackground, titleStack ]];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 16.0;
    [self.contentView addSubview:header];

    UIView *statusRow = [[UIView alloc] initWithFrame:CGRectZero];
    statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:statusRow];

    self.statusIcon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon.tintColor = MTAccentColor();
    self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    [statusRow addSubview:self.statusIcon];

    self.statusTitle = MTLabel(UIFontTextStyleSubheadline,
                               UIFontWeightSemibold, UIColor.labelColor);
    self.statusTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusTitle.text =
        MTApplyResultLocalized(@"apply.result.respring-title");

    self.statusDetail = MTLabel(UIFontTextStyleFootnote,
                                UIFontWeightRegular,
                                UIColor.secondaryLabelColor);
    self.statusDetail.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDetail.text = MTApplyResultLocalized(self.reloadRequired
        ? @"apply.result.respring-required-detail"
        : @"apply.result.respring-ready-detail");

    UIStackView *statusText = [[UIStackView alloc]
        initWithArrangedSubviews:@[ self.statusTitle, self.statusDetail ]];
    statusText.translatesAutoresizingMaskIntoConstraints = NO;
    statusText.axis = UILayoutConstraintAxisVertical;
    statusText.alignment = UIStackViewAlignmentFill;
    statusText.spacing = 3.0;
    [statusRow addSubview:statusText];

    self.actionDock = [[MTFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionDock.accessibilityIdentifier =
        @"marktheme64e.apply-result.action-dock";
    [self.view addSubview:self.actionDock];

    self.primaryButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    self.primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.primaryButton.accessibilityIdentifier =
        @"marktheme64e.apply-result.reload";
    [self.primaryButton addTarget:self
                           action:@selector(performPrimaryAction:)
                 forControlEvents:UIControlEventTouchUpInside];
    [self configurePrimaryButtonReloading:NO retry:NO];
    [self.actionDock addSubview:self.primaryButton];

    self.secondaryButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    self.secondaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *secondaryConfiguration =
        [UIButtonConfiguration plainButtonConfiguration];
    secondaryConfiguration.title =
        MTApplyResultLocalized(@"apply.result.later-action");
    secondaryConfiguration.baseForegroundColor = UIColor.secondaryLabelColor;
    self.secondaryButton.configuration = secondaryConfiguration;
    self.secondaryButton.accessibilityIdentifier =
        @"marktheme64e.apply-result.later";
    [self.secondaryButton addTarget:self action:@selector(close:)
                   forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.secondaryButton];

    UILayoutGuide *contentGuide = self.contentScrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = self.contentScrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.contentScrollView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentScrollView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentScrollView.topAnchor
            constraintEqualToAnchor:self.view.topAnchor],
        [self.contentScrollView.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentView.leadingAnchor
            constraintEqualToAnchor:contentGuide.leadingAnchor],
        [self.contentView.trailingAnchor
            constraintEqualToAnchor:contentGuide.trailingAnchor],
        [self.contentView.topAnchor
            constraintEqualToAnchor:contentGuide.topAnchor],
        [self.contentView.bottomAnchor
            constraintEqualToAnchor:contentGuide.bottomAnchor],
        [self.contentView.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor],

        [header.topAnchor
            constraintEqualToAnchor:self.contentView.topAnchor constant:22],
        [header.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],
        [header.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-24],
        [iconBackground.widthAnchor constraintEqualToConstant:56],
        [iconBackground.heightAnchor constraintEqualToConstant:56],
        [resultIcon.centerXAnchor
            constraintEqualToAnchor:iconBackground.centerXAnchor],
        [resultIcon.centerYAnchor
            constraintEqualToAnchor:iconBackground.centerYAnchor],

        [statusRow.topAnchor
            constraintEqualToAnchor:header.bottomAnchor constant:16],
        [statusRow.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],
        [statusRow.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-24],
        [statusRow.heightAnchor constraintGreaterThanOrEqualToConstant:72],
        [statusRow.bottomAnchor
            constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        [self.statusIcon.leadingAnchor
            constraintEqualToAnchor:statusRow.leadingAnchor],
        [self.statusIcon.centerYAnchor
            constraintEqualToAnchor:statusRow.centerYAnchor],
        [self.statusIcon.widthAnchor constraintEqualToConstant:19],
        [self.statusIcon.heightAnchor constraintEqualToConstant:19],
        [statusText.leadingAnchor
            constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:12],
        [statusText.trailingAnchor
            constraintEqualToAnchor:statusRow.trailingAnchor],
        [statusText.topAnchor
            constraintGreaterThanOrEqualToAnchor:statusRow.topAnchor constant:7],
        [statusText.bottomAnchor
            constraintLessThanOrEqualToAnchor:statusRow.bottomAnchor constant:-7],
        [statusText.centerYAnchor constraintEqualToAnchor:statusRow.centerYAnchor],

        [self.actionDock.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [self.actionDock.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [self.actionDock.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
        [self.primaryButton.leadingAnchor
            constraintEqualToAnchor:self.actionDock.leadingAnchor constant:20],
        [self.primaryButton.trailingAnchor
            constraintEqualToAnchor:self.actionDock.trailingAnchor constant:-20],
        [self.primaryButton.topAnchor
            constraintEqualToAnchor:self.actionDock.topAnchor constant:14],
        [self.primaryButton.heightAnchor constraintEqualToConstant:54],
        [self.secondaryButton.leadingAnchor
            constraintEqualToAnchor:self.actionDock.leadingAnchor constant:20],
        [self.secondaryButton.trailingAnchor
            constraintEqualToAnchor:self.actionDock.trailingAnchor constant:-20],
        [self.secondaryButton.topAnchor
            constraintEqualToAnchor:self.primaryButton.bottomAnchor constant:5],
        [self.secondaryButton.heightAnchor constraintEqualToConstant:38],
        [self.secondaryButton.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                              constant:-6],
    ]];

    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[
            UITraitPreferredContentSizeCategory.class,
        ] withHandler:^(__unused id<UITraitEnvironment> environment,
                        __unused UITraitCollection *previous) {
            [weakSelf invalidateSheetMeasurement];
        }];
    }
    [self configureSheet];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraits {
    [super traitCollectionDidChange:previousTraits];
    if (@available(iOS 17.0, *)) return;
    if (previousTraits == nil ||
        ![previousTraits.preferredContentSizeCategory isEqualToString:
            self.traitCollection.preferredContentSizeCategory]) {
        [self invalidateSheetMeasurement];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.actionDock];

    CGFloat dockHeight = CGRectGetHeight(self.actionDock.bounds);
    if (fabs(dockHeight - self.appliedDockInset) > 0.5) {
        UIEdgeInsets contentInset = self.contentScrollView.contentInset;
        contentInset.bottom = dockHeight;
        self.contentScrollView.contentInset = contentInset;
        UIEdgeInsets indicatorInsets =
            self.contentScrollView.verticalScrollIndicatorInsets;
        indicatorInsets.bottom = dockHeight;
        self.contentScrollView.verticalScrollIndicatorInsets = indicatorInsets;
        self.appliedDockInset = dockHeight;
    }

    CGFloat width = CGRectGetWidth(self.contentScrollView.bounds);
    if (width <= 0.0 || dockHeight <= 0.0) return;
    BOOL geometryChanged =
        fabs(width - self.measuredSheetWidth) > 0.5 ||
        fabs(dockHeight - self.measuredDockHeight) > 0.5;
    if (!self.sheetMeasurementInvalidated && !geometryChanged) return;
    CGSize contentSize = [self.contentView
        systemLayoutSizeFittingSize:
            CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
              verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat measuredHeight = ceil(contentSize.height + dockHeight);
    if (measuredHeight <= 0.0) return;
    BOOL heightChanged =
        fabs(measuredHeight - self.preferredSheetHeight) > 0.5;
    self.measuredSheetWidth = width;
    self.measuredDockHeight = dockHeight;
    self.sheetMeasurementInvalidated = NO;
    self.preferredSheetHeight = measuredHeight;
    self.preferredContentSize = CGSizeMake(width, measuredHeight);
    if (heightChanged) [self.sheetPresentationController invalidateDetents];
}

- (void)invalidateSheetMeasurement {
    self.sheetMeasurementInvalidated = YES;
    [self.view setNeedsLayout];
}

- (void)configureSheet {
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (sheet == nil) return;
    __weak typeof(self) weakSelf = self;
    UISheetPresentationControllerDetent *detent =
        [UISheetPresentationControllerDetent
            customDetentWithIdentifier:@"marktheme64e.apply-result"
            resolver:^CGFloat(
                id<UISheetPresentationControllerDetentResolutionContext>
                    context) {
                CGFloat contentHeight = weakSelf.preferredSheetHeight;
                if (contentHeight <= 0.0) contentHeight = 325.0;
                return MIN(contentHeight, context.maximumDetentValue);
            }];
    sheet.detents = @[ detent ];
    sheet.prefersGrabberVisible = YES;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
    sheet.preferredCornerRadius = 30.0;
}

- (void)configurePrimaryButtonReloading:(BOOL)reloading retry:(BOOL)retry {
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.baseBackgroundColor = MTPrimaryActionColor();
    configuration.baseForegroundColor = MTPrimaryActionForegroundColor();
    configuration.showsActivityIndicator = reloading;
    configuration.imagePadding = 8.0;
    if (reloading) {
        configuration.title =
            MTApplyResultLocalized(@"apply.result.reloading-action");
    } else {
        configuration.title = MTApplyResultLocalized(retry
            ? @"common.try-again" : @"apply.result.respring-action");
        configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    }
    self.primaryButton.configuration = configuration;
    self.primaryButton.enabled = !reloading;
}

- (void)performPrimaryAction:(id)sender {
    (void)sender;
    if (self.requestingReload) return;
    self.requestingReload = YES;
    self.modalInPresentation = YES;
    self.secondaryButton.enabled = NO;
    [self configurePrimaryButtonReloading:YES retry:NO];
    self.statusIcon.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    self.statusIcon.tintColor = MTAccentColor();
    self.statusTitle.text =
        MTApplyResultLocalized(@"apply.result.reloading-title");
    self.statusDetail.text =
        MTApplyResultLocalized(@"apply.result.reloading-detail");
    [self invalidateSheetMeasurement];

    __weak typeof(self) weakSelf = self;
    [self.managerController reloadDesktopWithCompletion:
        ^(BOOL success, NSError *error) {
        typeof(self) self = weakSelf;
        if (self == nil || success) return;
        self.requestingReload = NO;
        self.modalInPresentation = NO;
        self.secondaryButton.enabled = YES;
        [self configurePrimaryButtonReloading:NO retry:YES];
        self.statusIcon.image =
            [UIImage systemImageNamed:@"exclamationmark.circle.fill"];
        self.statusIcon.tintColor = MTDangerColor();
        self.statusTitle.text =
            MTApplyResultLocalized(@"apply.result.reload-failed-title");
        self.statusDetail.text = error.localizedDescription.length > 0
            ? error.localizedDescription
            : MTApplyResultLocalized(@"apply.result.reload-failed-detail");
        [self invalidateSheetMeasurement];
        [[[UINotificationFeedbackGenerator alloc] init]
            notificationOccurred:UINotificationFeedbackTypeError];
        NSLog(@"MarkTheme64e desktop reload failed (%@/%ld): %@",
              error.domain, (long)error.code, error.localizedDescription);
    }];
}

- (void)close:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:^{
        dispatch_block_t handler = self.dismissalHandler;
        self.dismissalHandler = nil;
        if (handler != nil) handler();
    }];
}

@end
