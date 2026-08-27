#import "MTImportContractViewController.h"

#import "MTDesignSystem.h"
#import "MTSafeDirectoryScanner.h"
#import "MTSafeImageDecoder.h"
#import "MTSafeImageInspector.h"
#import "MTSafePropertyListReader.h"
#import "MTThemeLibraryStore.h"
#import "MTVersionContracts.h"

static NSString *MTImportLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

@interface MTImportContractItem : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *symbolName;
@property(nonatomic, strong) UIColor *symbolColor;
+ (instancetype)itemWithTitle:(NSString *)title
                        detail:(NSString *)detail
                        symbol:(NSString *)symbol
                         color:(UIColor *)color;
@end

@implementation MTImportContractItem
+ (instancetype)itemWithTitle:(NSString *)title
                        detail:(NSString *)detail
                        symbol:(NSString *)symbol
                         color:(UIColor *)color {
    MTImportContractItem *item = [[self alloc] init];
    item.title = title;
    item.detail = detail;
    item.symbolName = symbol;
    item.symbolColor = color;
    return item;
}
@end

@interface MTImportContractSection : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray<MTImportContractItem *> *items;
+ (instancetype)sectionWithTitle:(NSString *)title
                            items:(NSArray<MTImportContractItem *> *)items;
@end

@implementation MTImportContractSection
+ (instancetype)sectionWithTitle:(NSString *)title
                            items:(NSArray<MTImportContractItem *> *)items {
    MTImportContractSection *section = [[self alloc] init];
    section.title = title;
    section.items = items;
    return section;
}
@end

@interface MTImportContractViewController ()
@property(nonatomic, copy) NSArray<MTImportContractSection *> *sections;
@property(nonatomic, strong) UIView *summaryHeaderView;
@property(nonatomic, strong) UIView *scopeFooterView;
@property(nonatomic, strong)
    MTTableSupplementaryLayoutCache *headerLayoutCache;
@property(nonatomic, strong)
    MTTableSupplementaryLayoutCache *footerLayoutCache;
@end

@implementation MTImportContractViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self == nil) return nil;
    _headerLayoutCache = [[MTTableSupplementaryLayoutCache alloc] init];
    _footerLayoutCache = [[MTTableSupplementaryLayoutCache alloc] init];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MTImportLocalized(@"import.contract.title");
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
    self.summaryHeaderView = [self makeSummaryHeader];
    self.scopeFooterView = [self makeScopeFooter];
    self.tableView.tableHeaderView = self.summaryHeaderView;
    self.tableView.tableFooterView = self.scopeFooterView;
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[
            UITraitPreferredContentSizeCategory.class,
        ] withHandler:^(__unused id<UITraitEnvironment> environment,
                        __unused UITraitCollection *previous) {
            [weakSelf.headerLayoutCache invalidate];
            [weakSelf.footerLayoutCache invalidate];
            [weakSelf.view setNeedsLayout];
        }];
    }
    [self rebuildSections];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.headerLayoutCache fitHeaderView:self.summaryHeaderView
                              inTableView:self.tableView];
    [self.footerLayoutCache fitFooterView:self.scopeFooterView
                              inTableView:self.tableView];
}

- (UIView *)makeSummaryHeader {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    UIImageView *symbol = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"doc.badge.gearshape"]];
    symbol.translatesAutoresizingMaskIntoConstraints = NO;
    symbol.tintColor = UIColor.systemIndigoColor;
    symbol.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2];
    UILabel *summary = [[UILabel alloc] init];
    summary.translatesAutoresizingMaskIntoConstraints = NO;
    summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    summary.adjustsFontForContentSizeCategory = YES;
    summary.textColor = UIColor.secondaryLabelColor;
    summary.numberOfLines = 0;
    summary.text = MTImportLocalized(@"import.contract.summary");
    [container addSubview:symbol];
    [container addSubview:summary];
    [NSLayoutConstraint activateConstraints:@[
        [symbol.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor],
        [symbol.topAnchor constraintEqualToAnchor:container.topAnchor constant:18],
        [summary.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:12],
        [summary.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor],
        [summary.topAnchor constraintEqualToAnchor:container.topAnchor constant:16],
        [summary.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16],
    ]];
    return container;
}

- (UIView *)makeScopeFooter {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.text = MTImportLocalized(@"import.contract.footer");
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor
                                            constant:12],
        [label.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor
                                             constant:-12],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:16],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-24],
    ]];
    return container;
}

- (void)rebuildSections {
    MTImportLimits *limits = MTImportLimits.defaultLimits;
    MTSafePropertyListLimits *propertyListLimits =
        MTSafePropertyListLimits.defaultLimits;
    MTSafeImageLimits *imageLimits = MTSafeImageLimits.defaultLimits;
    MTSafeImageDecodeLimits *decodeLimits =
        MTSafeImageDecodeLimits.defaultLimits;
    NSString *files = [NSNumberFormatter localizedStringFromNumber:
        @(limits.maximumRegularFiles) numberStyle:NSNumberFormatterDecimalStyle];
    NSString *entries = [NSNumberFormatter localizedStringFromNumber:
        @(limits.maximumArchiveEntries) numberStyle:NSNumberFormatterDecimalStyle];
    NSString *source = [NSByteCountFormatter
        stringFromByteCount:(long long)limits.maximumSourceBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *expanded = [NSByteCountFormatter
        stringFromByteCount:(long long)limits.maximumExpandedBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *single = [NSByteCountFormatter
        stringFromByteCount:(long long)limits.maximumSingleFileBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *ratio = [NSString stringWithFormat:
        MTImportLocalized(@"import.limit.ratio.format"),
        (unsigned long long)limits.maximumArchiveExpansionRatio];
    NSString *propertyListBytes = [NSByteCountFormatter
        stringFromByteCount:(long long)propertyListLimits.maximumInputBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *propertyListDetail = [NSString stringWithFormat:
        MTImportLocalized(@"import.plist.detail.format"), propertyListBytes,
        (unsigned long)propertyListLimits.maximumDepth,
        (unsigned long)propertyListLimits.maximumNodes,
        (unsigned long)propertyListLimits.maximumCollectionEntries];
    NSString *imageEncoded = [NSByteCountFormatter
        stringFromByteCount:(long long)imageLimits.maximumEncodedBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *imageDecoded = [NSByteCountFormatter
        stringFromByteCount:(long long)imageLimits.maximumDecodedBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *imagePixels = [NSNumberFormatter localizedStringFromNumber:
        @(imageLimits.maximumPixelCount)
        numberStyle:NSNumberFormatterDecimalStyle];
    NSString *imageAncillary = [NSByteCountFormatter
        stringFromByteCount:(long long)imageLimits.maximumAncillaryBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *decodePixels = [NSNumberFormatter localizedStringFromNumber:
        @(decodeLimits.maximumFullResolutionPixelCount)
        numberStyle:NSNumberFormatterDecimalStyle];
    NSString *decodeBytes = [NSByteCountFormatter
        stringFromByteCount:
            (long long)decodeLimits.maximumFullResolutionDecodedBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *thumbnailBytes = [NSByteCountFormatter
        stringFromByteCount:(long long)decodeLimits.maximumThumbnailBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *decodeDetail = [NSString stringWithFormat:
        MTImportLocalized(@"import.decode.detail.format"),
        (unsigned int)decodeLimits.maximumFullResolutionDimensionPixels,
        decodePixels, decodeBytes,
        (unsigned int)decodeLimits.maximumThumbnailDimensionPixels,
        thumbnailBytes];
    MTThemeLibraryConfiguration *libraryConfiguration =
        MTThemeLibraryConfiguration.defaultConfiguration;
    NSString *libraryReserve = [NSByteCountFormatter
        stringFromByteCount:
            (long long)libraryConfiguration.minimumFreeSpaceReserveBytes
                 countStyle:NSByteCountFormatterCountStyleBinary];
    NSString *libraryDetail = [NSString stringWithFormat:
        MTImportLocalized(@"import.library.detail.format"), libraryReserve];
    UIColor *ready = UIColor.systemGreenColor;
    UIColor *unavailable = UIColor.tertiaryLabelColor;
    self.sections = @[
        [MTImportContractSection sectionWithTitle:
            MTImportLocalized(@"import.section.ready") items:@[
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.canonical.title")
                detail:[NSString stringWithFormat:
                    MTImportLocalized(@"import.canonical.detail.format"),
                    (unsigned long)MTThemeManifestVersion]
                symbol:@"checkmark.shield.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.iconbundles.title")
                detail:MTImportLocalized(@"import.iconbundles.detail")
                symbol:@"checkmark.shield.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.session.title")
                detail:MTImportLocalized(@"import.session.detail")
                symbol:@"lock.doc.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.archive.title")
                detail:MTImportLocalized(@"import.archive.detail")
                symbol:@"checkmark.shield.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.audited.title")
                detail:MTImportLocalized(@"import.audited.detail")
                symbol:@"doc.text.magnifyingglass" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.staging.title")
                detail:MTImportLocalized(@"import.staging.detail")
                symbol:@"shippingbox.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.plist.title")
                detail:propertyListDetail
                symbol:@"list.bullet.rectangle.portrait.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.image.title")
                detail:MTImportLocalized(@"import.image.detail")
                symbol:@"photo.fill.on.rectangle.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.decode.title")
                detail:decodeDetail
                symbol:@"checkmark.shield.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.library.title")
                detail:libraryDetail
                symbol:@"checkmark.shield.fill" color:ready],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.workflow.title")
                detail:MTImportLocalized(@"import.workflow.detail")
                symbol:@"person.crop.circle.badge.checkmark" color:ready],
        ]],
        [MTImportContractSection sectionWithTitle:
            MTImportLocalized(@"import.section.limits") items:@[
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.source") detail:source
                symbol:@"archivebox" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.entries") detail:entries
                symbol:@"list.number" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.files") detail:files
                symbol:@"doc.on.doc" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.total") detail:expanded
                symbol:@"externaldrive" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.single") detail:single
                symbol:@"doc" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.ratio") detail:ratio
                symbol:@"arrow.up.left.and.arrow.down.right"
                color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.path")
                detail:[NSString stringWithFormat:
                    MTImportLocalized(@"import.limit.path.format"),
                    (unsigned long)limits.maximumPathDepth,
                    (unsigned long)limits.maximumPathUTF8Bytes]
                symbol:@"point.bottomleft.forward.to.point.topright.scurvepath"
                color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.image.bytes")
                detail:[NSString stringWithFormat:
                    MTImportLocalized(@"import.limit.image.bytes.format"),
                    imageEncoded, imageDecoded]
                symbol:@"memorychip" color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.image.structure")
                detail:[NSString stringWithFormat:
                    MTImportLocalized(@"import.limit.image.structure.format"),
                    (unsigned int)imageLimits.maximumDimensionPixels,
                    imagePixels, (unsigned long)imageLimits.maximumChunkCount,
                    imageAncillary]
                symbol:@"photo.on.rectangle.angled"
                color:UIColor.systemIndigoColor],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.limit.decode")
                detail:decodeDetail
                symbol:@"memorychip.fill"
                color:UIColor.systemIndigoColor],
        ]],
        [MTImportContractSection sectionWithTitle:
            MTImportLocalized(@"import.section.unavailable") items:@[
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.directory.title")
                detail:MTImportLocalized(@"import.directory.detail")
                symbol:@"folder.badge.minus" color:unavailable],
            [MTImportContractItem itemWithTitle:
                MTImportLocalized(@"import.runtime.title")
                detail:MTImportLocalized(@"import.runtime.detail")
                symbol:@"minus.circle" color:unavailable],
        ]],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return self.sections[(NSUInteger)section].items.count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return self.sections[(NSUInteger)section].title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"ImportContractCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }
    MTImportContractItem *item = self.sections[(NSUInteger)indexPath.section]
        .items[(NSUInteger)indexPath.row];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.detail;
    cell.imageView.image = [UIImage systemImageNamed:item.symbolName];
    cell.imageView.tintColor = item.symbolColor;
    cell.accessibilityLabel = item.title;
    cell.accessibilityValue = item.detail;
    return cell;
}

@end
