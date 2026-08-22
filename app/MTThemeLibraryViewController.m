#import "MTThemeLibraryViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "MTDesignSystem.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTImportDiagnostics.h"
#import "MTImportViewController.h"
#import "MTInstalledThemeLocator.h"
#import "MTManagerController.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeDetailViewController.h"
#import "MTThemeManifest.h"
#import "MTThemePreviewProvider.h"
#import "MTThemePreviewRepository.h"

static NSString *MTLibraryLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static BOOL MTLibraryThemeIDsEqual(NSString *_Nullable left,
                                   NSString *_Nullable right) {
    return left == right || [left isEqualToString:right];
}

// The swipe action rectangle is painted in the canvas color so only this
// circular badge stays visible, matching the delete action in MarkFont.
static UIImage *MTCircularDeleteActionImage(UITraitCollection *traits) {
    CGSize size = CGSizeMake(44, 44);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(__unused UIGraphicsImageRendererContext *context) {
        UIColor *danger =
            [MTDangerColor() resolvedColorWithTraitCollection:traits];
        [danger setFill];
        [[UIBezierPath bezierPathWithOvalInRect:
            CGRectInset((CGRect){ CGPointZero, size }, 2, 2)] fill];

        UIImageSymbolConfiguration *symbolConfiguration =
            [UIImageSymbolConfiguration configurationWithPointSize:18
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *trash = [[UIImage systemImageNamed:@"trash.fill"
                                  withConfiguration:symbolConfiguration]
            imageWithTintColor:UIColor.whiteColor
                 renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGPoint origin = CGPointMake((size.width - trash.size.width) / 2.0,
                                     (size.height - trash.size.height) / 2.0);
        [trash drawAtPoint:origin];
    }];
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    image.accessibilityLabel = MTLibraryLocalized(@"library.delete-action");
    return image;
}

@interface MTThemeLibraryCell : UITableViewCell
@property(nonatomic, copy, nullable) NSString *themeIdentifier;
@property(nonatomic, copy, nullable) NSString *previewRevisionIdentifier;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) MTIconGridView *iconGrid;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIImageView *chevron;
@property(nonatomic, strong, nullable) MTThemePreviewRequest *previewRequest;
- (void)configureWithThemeIdentifier:(nullable NSString *)themeIdentifier
           previewRevisionIdentifier:(nullable NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                          iconImages:(nullable NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                             chosen:(BOOL)chosen;
@end

@implementation MTThemeLibraryCell

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.previewRequest cancel];
    self.previewRequest = nil;
    self.themeIdentifier = nil;
    self.previewRevisionIdentifier = nil;
    self.card.transform = CGAffineTransformIdentity;
    self.card.alpha = 1.0;
    [self.iconGrid setIconImages:@[] animated:NO];
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.isAccessibilityElement = YES;

    _card = MTCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_card];

    _iconGrid = [[MTIconGridView alloc] initWithFrame:CGRectZero];
    _iconGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_iconGrid];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _nameLabel.textColor = UIColor.labelColor;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.72;
    [_card addSubview:_nameLabel];

    _detailLabel = MTLabel(UIFontTextStyleFootnote,
                           UIFontWeightRegular,
                           UIColor.secondaryLabelColor);
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 1;
    [_card addSubview:_detailLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.layer.cornerRadius = 10.0;
    _statusLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _statusLabel.layer.masksToBounds = YES;
    [_card addSubview:_statusLabel];

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
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
        [_card.heightAnchor constraintGreaterThanOrEqualToConstant:104],
        [_iconGrid.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:13],
        [_iconGrid.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconGrid.widthAnchor constraintEqualToConstant:84],
        [_iconGrid.heightAnchor constraintEqualToConstant:84],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconGrid.trailingAnchor constant:14],
        [_nameLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:17],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                               constant:-10],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevron.leadingAnchor
                                                                  constant:-10],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:5],
        [_statusLabel.heightAnchor constraintEqualToConstant:20],
        [_statusLabel.widthAnchor constraintGreaterThanOrEqualToConstant:50],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor
                                                  constant:-11],
        [_chevron.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
        [_chevron.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_chevron.widthAnchor constraintEqualToConstant:11],
        [_chevron.heightAnchor constraintEqualToConstant:17],
    ]];
    return self;
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

- (void)configureWithThemeIdentifier:(NSString *)themeIdentifier
           previewRevisionIdentifier:(NSString *)previewRevisionIdentifier
                                name:(NSString *)name
                              detail:(NSString *)detail
                          iconImages:(NSArray<UIImage *> *)iconImages
                             current:(BOOL)current
                             chosen:(BOOL)chosen {
    BOOL previewChanged =
        !MTLibraryThemeIDsEqual(self.themeIdentifier, themeIdentifier) ||
        !MTLibraryThemeIDsEqual(self.previewRevisionIdentifier,
                                previewRevisionIdentifier);
    if (previewChanged) {
        [self.previewRequest cancel];
        self.previewRequest = nil;
    }
    self.themeIdentifier = themeIdentifier;
    self.previewRevisionIdentifier = previewRevisionIdentifier;
    if (iconImages != nil) {
        [self.iconGrid setIconImages:iconImages animated:NO];
    } else if (previewChanged) {
        [self.iconGrid setIconImages:@[] animated:NO];
    }
    self.nameLabel.text = name;
    self.detailLabel.text = detail;
    self.chevron.hidden = themeIdentifier == nil;
    NSString *status = nil;
    if (current) {
        status = MTLibraryLocalized(@"theme.card.current");
    } else if (chosen) {
        status = MTLibraryLocalized(@"library.selected");
    }
    self.statusLabel.hidden = status == nil;
    self.statusLabel.text = status;
    UIColor *statusColor = current ? MTSuccessColor() : MTAccentColor();
    self.statusLabel.textColor = statusColor;
    self.statusLabel.backgroundColor = status == nil
        ? UIColor.clearColor
        : MTTintedBackground(statusColor);
    self.accessibilityLabel = name;
    self.accessibilityValue = status.length > 0
        ? status
        : MTLibraryLocalized(@"library.detail-hint");
    self.accessibilityTraits = UIAccessibilityTraitButton;
}

@end

@interface MTThemeLibraryViewController () <UITableViewDataSource,
                                              UITableViewDelegate,
                                              UITableViewDataSourcePrefetching,
                                              UIDocumentPickerDelegate>
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, strong) MTThemePreviewRepository *previewRepository;
@property(nonatomic, copy, nullable) NSString *selectedThemeIdentifier;
@property(nonatomic, copy, nullable) NSString *activeThemeIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeComponentSelection *> *componentSelections;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *activeComponentSelection;
@property(nonatomic, assign) BOOL runtimeEnabled;
@property(nonatomic, copy) MTThemeLibrarySelectionHandler selectionHandler;
@property(nonatomic, copy) NSArray<MTThemeLibraryThemeSummary *> *themes;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *rowByThemeIdentifier;
@property(nonatomic, assign) BOOL managerProjectionPending;
@property(nonatomic, assign) BOOL visibleProjectionResumePending;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, MTThemePreviewRequest *> *prefetchRequests;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong)
    MTTableSupplementaryLayoutCache *headerLayoutCache;
- (void)scheduleVisiblePreviewResumeAfterCatalogChange;
- (void)presentInstalledThemesForImport;
- (void)presentThemeArchivePicker;
- (void)pushImportControllerStartingURL:(NSURL *)url;
@end

@implementation MTThemeLibraryViewController

- (instancetype)initWithManagerController:
        (MTManagerController *)managerController
    previewRepository:(MTThemePreviewRepository *)previewRepository
    selectedThemeIdentifier:(NSString *)selectedThemeIdentifier
                                 selectionHandler:(MTThemeLibrarySelectionHandler)selectionHandler {
    NSParameterAssert(managerController != nil);
    NSParameterAssert(previewRepository != nil);
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _managerController = managerController;
        _previewRepository = previewRepository;
        _selectedThemeIdentifier = [selectedThemeIdentifier copy];
        _selectionHandler = [selectionHandler copy];
        _prefetchRequests = [NSMutableDictionary dictionary];
        _headerLayoutCache = [[MTTableSupplementaryLayoutCache alloc] init];
        _visibleProjectionResumePending = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTCanvasColor();
    self.title = MTLibraryLocalized(@"library.title");
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.themes = @[];
    self.rowByThemeIdentifier = @{};

    MTPressableButton *closeButton =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    closeButton.accessibilityLabel = MTLibraryLocalized(@"library.close");
    UIButtonConfiguration *closeConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    closeConfiguration.image = [UIImage systemImageNamed:@"xmark"];
    closeConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    closeConfiguration.baseForegroundColor = MTAccentColor();
    closeConfiguration.baseBackgroundColor = MTAccentColor();
    closeButton.configuration = closeConfiguration;
    [closeButton addTarget:self action:@selector(closeLibrary:)
           forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.widthAnchor constraintEqualToConstant:36],
        [closeButton.heightAnchor constraintEqualToConstant:36],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:closeButton];

    self.tableView = [[UITableView alloc]
        initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = MTCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.prefetchDataSource = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 114.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 24, 0);
    self.tableView.accessibilityIdentifier = @"marktheme64e.library";
    [self.tableView registerClass:MTThemeLibraryCell.class
           forCellReuseIdentifier:@"ThemeLibraryCell"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.tableView.tableHeaderView = [self makeImportHeader];
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[
            UITraitPreferredContentSizeCategory.class,
        ] withHandler:^(__unused id<UITraitEnvironment> environment,
                        __unused UITraitCollection *previous) {
            [weakSelf.headerLayoutCache invalidate];
            if (MTViewControllerCanApplyVisibleProjection(weakSelf)) {
                [weakSelf.view setNeedsLayout];
            }
        }];
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(managerControllerDidChange:)
               name:MTManagerControllerDidChangeNotification
             object:self.managerController];
    [self consumeManagerSnapshot];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraits {
    [super traitCollectionDidChange:previousTraits];
    if (@available(iOS 17.0, *)) return;
    if (previousTraits == nil ||
        ![previousTraits.preferredContentSizeCategory isEqualToString:
            self.traitCollection.preferredContentSizeCategory]) {
        [self.headerLayoutCache invalidate];
        if (MTViewControllerCanApplyVisibleProjection(self)) {
            [self.view setNeedsLayout];
        }
    }
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
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self suspendVisibleProjection];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self resumeVisibleProjectionIfNeeded];
    [self.headerLayoutCache fitHeaderView:self.tableView.tableHeaderView
                              inTableView:self.tableView];
}

- (UIView *)makeImportHeader {
    UIView *header = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 1)];
    UIView *card = MTCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = MTTintedBackground(MTAccentColor());
    card.layer.borderColor = [MTAccentColor() colorWithAlphaComponent:0.14].CGColor;
    [header addSubview:card];

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"plus"
            withConfiguration:[UIImageSymbolConfiguration
                configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = MTAccentColor();
    [card addSubview:icon];

    UILabel *title = MTLabel(UIFontTextStyleTitle3,
                             UIFontWeightBold, UIColor.labelColor);
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = MTLibraryLocalized(@"library.import-title");
    [card addSubview:title];

    UILabel *detail = MTLabel(UIFontTextStyleFootnote,
                              UIFontWeightRegular,
                              UIColor.secondaryLabelColor);
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.text = MTLibraryLocalized(@"library.import-detail");
    [card addSubview:detail];

    MTPressableButton *button =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityIdentifier = @"marktheme64e.library.import";
    UIButtonConfiguration *configuration =
        [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = MTLibraryLocalized(@"library.import-action");
    configuration.image = [UIImage systemImageNamed:@"doc.badge.plus"];
    configuration.imagePadding = 7;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.baseBackgroundColor = MTAccentColor();
    configuration.baseForegroundColor = UIColor.whiteColor;
    button.configuration = configuration;
    [button addTarget:self action:@selector(importTheme:)
      forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [icon.widthAnchor constraintEqualToConstant:25],
        [icon.heightAnchor constraintEqualToConstant:25],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:11],
        [title.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [detail.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [detail.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:8],
        [button.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [button.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [button.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:12],
        [button.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [button.heightAnchor constraintEqualToConstant:44],
    ]];
    return header;
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
    BOOL selectedThemeChanged = !MTLibraryThemeIDsEqual(
        previousSelectedThemeIdentifier, snapshot.selectedThemeIdentifier);
    BOOL activeThemeChanged = !MTLibraryThemeIDsEqual(
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
    BOOL runtimeEnabledChanged = self.runtimeEnabled != snapshot.runtimeEnabled;
    self.themes = snapshot.themes;
    self.selectedThemeIdentifier = snapshot.selectedThemeIdentifier;
    self.activeThemeIdentifier = snapshot.activeThemeIdentifier;
    self.componentSelections = snapshot.componentSelectionsByThemeIdentifier;
    self.activeComponentSelection = snapshot.activeComponentSelection;
    self.runtimeEnabled = snapshot.runtimeEnabled;
    if (catalogChanged) {
        [self cancelPreviewRequests];
        NSMutableDictionary<NSString *, NSNumber *> *rows =
            [NSMutableDictionary dictionaryWithCapacity:self.themes.count];
        [self.themes enumerateObjectsUsingBlock:
            ^(MTThemeLibraryThemeSummary *summary, NSUInteger index,
              __unused BOOL *stop) {
            rows[summary.themeID] = @(index);
        }];
        self.rowByThemeIdentifier = rows;
        [self.tableView reloadData];
        [self scheduleVisiblePreviewResumeAfterCatalogChange];
        return;
    }
    if (!selectedThemeChanged && !activeThemeChanged &&
        !componentSelectionsChanged && !activeComponentSelectionChanged &&
        !runtimeEnabledChanged) return;
    if (componentSelectionsChanged || activeComponentSelectionChanged ||
        runtimeEnabledChanged) {
        for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
            MTThemeLibraryCell *cell =
                [self.tableView cellForRowAtIndexPath:indexPath];
            if (cell != nil) [self configureCell:cell atIndexPath:indexPath];
        }
        return;
    }
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
        [self updateVisibleThemeIdentifier:
            value == NSNull.null ? nil : value];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 1 : (NSInteger)self.themes.count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return MTLibraryLocalized(@"library.section.built-in");
    return self.themes.count > 0
        ? MTLibraryLocalized(@"library.section.mine") : nil;
}

- (UIView *)tableView:(UITableView *)tableView
 viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title == nil) return nil;
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

- (CGFloat)tableView:(UITableView *)tableView
 heightForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView titleForHeaderInSection:section] == nil
        ? 0.0 : 34.0;
}

- (MTThemeLibraryThemeSummary *)summaryAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 &&
        (NSUInteger)indexPath.row < self.themes.count
        ? self.themes[(NSUInteger)indexPath.row] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MTThemeLibraryCell *cell = [tableView
        dequeueReusableCellWithIdentifier:@"ThemeLibraryCell"
                              forIndexPath:indexPath];
    [self configureCell:cell atIndexPath:indexPath];
    return cell;
}

- (void)configureCell:(MTThemeLibraryCell *)cell
           atIndexPath:(NSIndexPath *)indexPath {
    MTThemeLibraryThemeSummary *summary = [self summaryAtIndexPath:indexPath];
    NSString *identifier = summary.themeID;
    NSString *name = summary == nil
        ? MTLibraryLocalized(@"theme.stock.name")
        : summary.currentRevision.manifest.displayName;
    NSString *detail = summary == nil
        ? MTLibraryLocalized(@"theme.stock.detail")
        : [NSString stringWithFormat:MTLibraryLocalized(@"theme.card.icon-count"),
            (unsigned long)summary.currentRevision.manifest.resources.count];
    [cell configureWithThemeIdentifier:identifier
             previewRevisionIdentifier:
                 summary.currentRevision.revisionIdentifier
                                  name:name
                                detail:detail
                            iconImages:identifier == nil
                                ? MTSystemDefaultPreviewImages()
                                : [self.previewRepository
                                    presentationImagesForThemeSummary:summary]
                               current:identifier == nil
                                   ? !self.managerController.snapshot.runtimeEnabled
                                   : [self.managerController.snapshot
                                       runtimeMatchesCurrentSelectionForThemeIdentifier:
                                           identifier]
                               chosen:MTLibraryThemeIDsEqual(identifier,
                                                             self.selectedThemeIdentifier)];
    cell.accessibilityIdentifier = identifier == nil
        ? @"marktheme64e.library.stock"
        : [@"marktheme64e.library." stringByAppendingString:identifier];
}

- (NSIndexPath *)indexPathForThemeIdentifier:(NSString *)themeIdentifier {
    if (themeIdentifier == nil) {
        return [NSIndexPath indexPathForRow:0 inSection:0];
    }
    NSNumber *row = self.rowByThemeIdentifier[themeIdentifier];
    return row == nil ? nil
        : [NSIndexPath indexPathForRow:row.integerValue inSection:1];
}

- (void)updateVisibleThemeIdentifier:(NSString *)themeIdentifier {
    NSIndexPath *indexPath =
        [self indexPathForThemeIdentifier:themeIdentifier];
    if (indexPath == nil) return;
    MTThemeLibraryCell *cell =
        [self.tableView cellForRowAtIndexPath:indexPath];
    if (cell != nil) [self configureCell:cell atIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView
   willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    [self startPreviewRequestForCell:(MTThemeLibraryCell *)cell
                         atIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView
 didEndDisplayingCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    MTThemeLibraryCell *themeCell = (MTThemeLibraryCell *)cell;
    [themeCell.previewRequest cancel];
    themeCell.previewRequest = nil;
}

- (void)startPreviewRequestsForVisibleRows {
    for (NSIndexPath *indexPath in self.tableView.indexPathsForVisibleRows) {
        MTThemeLibraryCell *cell =
            [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell != nil) {
            [self configureCell:cell atIndexPath:indexPath];
            [self startPreviewRequestForCell:cell atIndexPath:indexPath];
        }
    }
}

- (void)startPreviewRequestForCell:(MTThemeLibraryCell *)cell
                       atIndexPath:(NSIndexPath *)indexPath {
    MTThemeLibraryThemeSummary *summary = [self summaryAtIndexPath:indexPath];
    NSString *themeIdentifier = summary.themeID;
    if (summary == nil) {
        [cell.previewRequest cancel];
        cell.previewRequest = nil;
        return;
    }
    if ([self.previewRepository cachedImagesForThemeSummary:summary] != nil) {
        [cell.previewRequest cancel];
        cell.previewRequest = nil;
        [self cancelPrefetchRequestForThemeIdentifier:themeIdentifier];
        return;
    }
    if (cell.previewRequest != nil) {
        [self cancelPrefetchRequestForThemeIdentifier:themeIdentifier];
        return;
    }
    NSString *revisionIdentifier = summary.currentRevision.revisionIdentifier;
    __weak typeof(self) weakSelf = self;
    __block MTThemePreviewRequest *request = nil;
    request = [self.previewRepository loadImagesForThemeSummary:summary
        priority:MTThemePreviewPriorityNormal
        completion:^(__unused NSArray<UIImage *> *images) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        NSIndexPath *indexPath =
            [self indexPathForThemeIdentifier:themeIdentifier];
        MTThemeLibraryCell *cell = indexPath == nil ? nil
            : [self.tableView cellForRowAtIndexPath:indexPath];
        if (cell.previewRequest == request) cell.previewRequest = nil;
        if (!MTViewControllerCanApplyVisibleProjection(self)) return;
        MTThemeLibraryThemeSummary *current =
            [self.managerController.snapshot
                themeWithIdentifier:themeIdentifier];
        if (![current.currentRevision.revisionIdentifier
                isEqualToString:revisionIdentifier]) return;
        [self updateVisibleThemeIdentifier:themeIdentifier];
    }];
    cell.previewRequest = request;
    [self cancelPrefetchRequestForThemeIdentifier:themeIdentifier];
}

- (void)tableView:(UITableView *)tableView
    prefetchRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths {
    for (NSIndexPath *indexPath in indexPaths) {
        MTThemeLibraryThemeSummary *summary = [self summaryAtIndexPath:indexPath];
        NSString *themeIdentifier = summary.themeID;
        if (summary == nil || self.prefetchRequests[themeIdentifier] != nil ||
            [tableView cellForRowAtIndexPath:indexPath] != nil ||
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
                [self.managerController.snapshot
                    themeWithIdentifier:themeIdentifier];
            if (![current.currentRevision.revisionIdentifier
                    isEqualToString:revisionIdentifier]) return;
            [self updateVisibleThemeIdentifier:themeIdentifier];
        }];
        self.prefetchRequests[themeIdentifier] = request;
    }
}

- (void)tableView:(UITableView *)tableView
    cancelPrefetchingForRowsAtIndexPaths:
        (NSArray<NSIndexPath *> *)indexPaths {
    (void)tableView;
    for (NSIndexPath *indexPath in indexPaths) {
        NSString *themeIdentifier =
            [self summaryAtIndexPath:indexPath].themeID;
        [self cancelPrefetchRequestForThemeIdentifier:themeIdentifier];
    }
}

- (void)cancelPrefetchRequestForThemeIdentifier:
        (NSString *)themeIdentifier {
    if (themeIdentifier.length == 0) return;
    MTThemePreviewRequest *request = self.prefetchRequests[themeIdentifier];
    [self.prefetchRequests removeObjectForKey:themeIdentifier];
    [request cancel];
}

- (void)cancelPreviewRequests {
    for (MTThemeLibraryCell *cell in self.tableView.visibleCells) {
        [cell.previewRequest cancel];
        cell.previewRequest = nil;
    }
    for (MTThemePreviewRequest *request in self.prefetchRequests.allValues) {
        [request cancel];
    }
    [self.prefetchRequests removeAllObjects];
}

- (void)suspendVisibleProjection {
    self.visibleProjectionResumePending = YES;
    [self cancelPreviewRequests];
}

- (void)scheduleVisiblePreviewResumeAfterCatalogChange {
    self.visibleProjectionResumePending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil ||
            !MTViewControllerCanApplyVisibleProjection(self)) return;
        [self.tableView layoutIfNeeded];
        self.visibleProjectionResumePending = NO;
        [self startPreviewRequestsForVisibleRows];
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
    if (resumesPreviewRequests) [self startPreviewRequestsForVisibleRows];
}

- (void)tableView:(UITableView *)tableView
   didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    MTThemeLibraryThemeSummary *summary = [self summaryAtIndexPath:indexPath];
    NSString *identifier = summary.themeID;
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
    if (summary == nil) {
        [self.managerController selectThemeIdentifier:identifier];
        self.selectionHandler(identifier);
        [self dismissViewControllerAnimated:YES completion:^{
            [self finishDismissal];
        }];
        return;
    }
    [self pushThemeDetailForSummary:summary];
}

// Only imported themes can be deleted; the built-in row in section 0 is the
// system appearance and owns no Library storage.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    MTThemeLibraryThemeSummary *summary = [self summaryAtIndexPath:indexPath];
    if (summary == nil) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:nil
                          handler:^(__unused UIContextualAction *action,
                                    __unused UIView *source,
                                    void (^completion)(BOOL)) {
        [weakSelf confirmDeleteThemeSummary:summary completion:completion];
    }];
    deleteAction.backgroundColor =
        [MTCanvasColor() resolvedColorWithTraitCollection:tableView.traitCollection];
    deleteAction.image = MTCircularDeleteActionImage(tableView.traitCollection);
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[ deleteAction ]];
    // Deletion is irreversible, so require the explicit tap rather than
    // letting a long swipe delete a theme outright.
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (void)confirmDeleteThemeSummary:(MTThemeLibraryThemeSummary *)summary
                        completion:(void (^)(BOOL))completion {
    NSString *identifier = summary.themeID;
    NSString *name = summary.currentRevision.manifest.displayName;
    // Removing the theme that Runtime is currently serving would leave the
    // desktop pointing at storage that no longer exists.
    if ([self.managerController.snapshot
            runtimeMatchesCurrentSelectionForThemeIdentifier:identifier]) {
        UIAlertController *inUse = [UIAlertController
            alertControllerWithTitle:
                MTLibraryLocalized(@"library.delete-in-use-title")
                             message:
                MTLibraryLocalized(@"library.delete-in-use-message")
                      preferredStyle:UIAlertControllerStyleAlert];
        [inUse addAction:[UIAlertAction
            actionWithTitle:MTLibraryLocalized(@"library.delete-in-use-dismiss")
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            completion(NO);
        }]];
        [self presentViewController:inUse animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:
            MTLibraryLocalized(@"library.delete-title.format"), name]
                         message:MTLibraryLocalized(@"library.delete-message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"library.delete-cancel")
                  style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *action) {
        completion(NO);
    }]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"library.delete-confirm")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
        typeof(self) self = weakSelf;
        if (self == nil) {
            completion(NO);
            return;
        }
        [self cancelPrefetchRequestForThemeIdentifier:identifier];
        if ([self.selectedThemeIdentifier isEqualToString:identifier]) {
            self.selectedThemeIdentifier = nil;
        }
        [self.managerController removeThemeIdentifier:identifier
                                           completion:^(BOOL success,
                                                        NSError *error) {
            typeof(self) self = weakSelf;
            if (success) {
                [[[UINotificationFeedbackGenerator alloc] init]
                    notificationOccurred:UINotificationFeedbackTypeSuccess];
            } else if (self != nil) {
                [self presentDeletionError:error];
            }
            completion(success);
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentDeletionError:(NSError *)error {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTLibraryLocalized(@"library.delete-action")
                         message:error.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"library.delete-in-use-dismiss")
                  style:UIAlertActionStyleDefault
                handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushThemeDetailForSummary:(MTThemeLibraryThemeSummary *)summary {
    MTThemeDetailViewController *detail = [[MTThemeDetailViewController alloc]
        initWithManagerController:self.managerController
              previewRepository:self.previewRepository
                  themeIdentifier:summary.themeID];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)importTheme:(id)sender {
    UIView *sourceView = [sender isKindOfClass:UIView.class]
        ? (UIView *)sender : self.view;
    MTImportDiagnosticsRecord(@"breadcrumb.library.import-button.tap", @{
        @"senderClass" : NSStringFromClass([sender class]) ?: @"",
        @"viewInWindow" : @(self.view.window != nil),
        @"presentedController" : self.presentedViewController == nil
            ? @"<none>" : NSStringFromClass(self.presentedViewController.class),
    });
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:MTLibraryLocalized(@"import.source.title")
                         message:MTLibraryLocalized(@"import.source.detail")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"import.source.installed-action")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        MTImportDiagnosticsRecord(@"breadcrumb.library.source.installed.tap", nil);
        [weakSelf presentInstalledThemesForImport];
    }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"import.source.zip-action")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        MTImportDiagnosticsRecord(@"breadcrumb.library.source.archive.tap", nil);
        [weakSelf presentThemeArchivePicker];
    }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"import.source.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    MTImportDiagnosticsRecord(@"breadcrumb.library.source-sheet.present-request", @{
        @"actionCount" : @(sheet.actions.count),
    });
    [self presentViewController:sheet animated:YES completion:^{
        MTImportDiagnosticsRecord(@"breadcrumb.library.source-sheet.presented", nil);
    }];
}

- (void)presentInstalledThemesForImport {
    MTInstalledThemeLocator *locator = [[MTInstalledThemeLocator alloc] init];
    MTImportDiagnosticsRecord(@"installed.scan.begin", @{
        @"searchRoots" : locator.searchRootPaths,
    });
    NSArray<MTInstalledTheme *> *installed =
        [locator locateInstalledThemes];
    MTImportDiagnosticsRecord(@"installed.scan.end", @{
        @"count" : @(installed.count),
        @"names" : [installed valueForKey:@"displayName"] ?: @[],
    });
    if (installed.count == 0) {
        NSString *paths = [locator.searchRootPaths
            componentsJoinedByString:@"\n"];
        NSString *format = MTLibraryLocalized(
            @"import.source.installed-empty-detail");
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:MTLibraryLocalized(
                                         @"import.source.installed-empty-title")
                             message:[NSString stringWithFormat:format, paths]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
            actionWithTitle:MTLibraryLocalized(@"common.ok")
                      style:UIAlertActionStyleDefault
                    handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:MTLibraryLocalized(
                                     @"import.source.installed-title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (installed.count > 1) {
        [sheet addAction:[UIAlertAction
            actionWithTitle:MTLibraryLocalized(@"import.source.installed-all")
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            [weakSelf importAllInstalledThemes:installed];
        }]];
    }
    for (MTInstalledTheme *theme in installed) {
        [sheet addAction:[UIAlertAction
            actionWithTitle:theme.displayName
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            [weakSelf pushImportControllerStartingURL:theme.directoryURL];
        }]];
    }
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTLibraryLocalized(@"import.source.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentThemeArchivePicker {
    UTType *themeArchive =
        [UTType typeWithIdentifier:MTThemeArchiveContentTypeIdentifier];
    NSArray<UTType *> *contentTypes = themeArchive == nil
        ? @[ UTTypeZIP ]
        : @[ UTTypeZIP, themeArchive ];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:contentTypes asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    NSMutableArray<NSString *> *typeIdentifiers = [NSMutableArray array];
    for (UTType *type in contentTypes) {
        if (type.identifier.length > 0) [typeIdentifiers addObject:type.identifier];
    }
    MTImportDiagnosticsRecord(@"archive-picker.present-request", @{
        @"contentTypes" : typeIdentifiers,
        @"customTypeFound" : @(themeArchive != nil),
        @"customTypeDeclared" : @(themeArchive.isDeclared),
        @"asCopy" : @NO,
        @"viewInWindow" : @(self.view.window != nil),
        @"presentedController" : self.presentedViewController == nil
            ? @"<none>" : NSStringFromClass(self.presentedViewController.class),
    });
    [self suspendVisibleProjection];
    [self presentViewController:picker animated:YES completion:^{
        MTImportDiagnosticsRecord(@"archive-picker.presented", nil);
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    MTImportDiagnosticsRecord(@"archive-picker.did-pick", @{
        @"urlCount" : @(urls.count),
        @"isFileURL" : @(url.isFileURL),
        @"lastPathComponent" : url.lastPathComponent ?: @"",
        @"pathExtension" : url.pathExtension ?: @"",
        @"path" : url.path ?: @"",
    });
    if (urls.count != 1 || !url.isFileURL) return;
    [self pushImportControllerStartingURL:url];
}

- (void)importAllInstalledThemes:(NSArray<MTInstalledTheme *> *)themes {
    NSString *tempDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSURL *tempURL = [NSURL fileURLWithPath:tempDir];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:tempURL
        withIntermediateDirectories:YES attributes:nil error:nil];
    for (MTInstalledTheme *theme in themes) {
        NSString *name = theme.directoryURL.lastPathComponent;
        NSURL *dest = [tempURL URLByAppendingPathComponent:name];
        // If names collide, append UUID to keep them unique
        if ([fm fileExistsAtPath:dest.path]) {
            NSString *newName = [NSString stringWithFormat:@"%@-%@",
                theme.displayName, [NSUUID UUID].UUIDString];
            dest = [tempURL URLByAppendingPathComponent:newName];
        }
        [fm copyItemAtURL:theme.directoryURL toURL:dest error:nil];
    }
    [self pushImportControllerStartingURL:tempURL];
}

- (void)documentPickerWasCancelled:
        (UIDocumentPickerViewController *)controller {
    (void)controller;
    MTImportDiagnosticsRecord(@"archive-picker.cancelled", nil);
}

- (void)pushImportControllerStartingURL:(NSURL *)url {
    MTImportDiagnosticsRecord(@"import-navigation.begin", @{
        @"lastPathComponent" : url.lastPathComponent ?: @"",
        @"pathExtension" : url.pathExtension ?: @"",
        @"path" : url.path ?: @"",
    });
    __weak typeof(self) weakSelf = self;
    MTImportViewController *importController = [[MTImportViewController alloc]
        initWithCompletionHandler:^(NSString *themeIdentifier) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        self.selectedThemeIdentifier = themeIdentifier;
        [self.managerController
            reloadSelectingThemeIdentifier:themeIdentifier];
    }];
    [self.navigationController pushViewController:importController animated:YES];
    [importController startImportAtURL:url];
}

- (void)closeLibrary:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:^{
        [self finishDismissal];
    }];
}

- (void)finishDismissal {
    dispatch_block_t handler = self.dismissalHandler;
    self.dismissalHandler = nil;
    if (handler != nil) handler();
}

@end
