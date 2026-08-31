#import "MTThemeDetailViewController.h"

#import "MTBadgeContract.h"
#import "MTDesignSystem.h"
#import "MTApplyResultViewController.h"
#import "MTIconShadowsModule.h"
#import "MTManagerController.h"
#import "MTThemeCapabilityReport.h"
#import "MTThemeComponentCatalog.h"
#import "MTThemeLibraryCatalog.h"
#import "MTThemeManifest.h"
#import "MTThemeMixSelection.h"
#import "MTThemePreviewRepository.h"

static NSString *MTDetailLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static BOOL MTDetailStringsEqual(NSString *_Nullable left,
                                 NSString *_Nullable right) {
    return left == right || [left isEqualToString:right];
}

static BOOL MTDetailObjectsEqual(id _Nullable left, id _Nullable right) {
    return left == right || [left isEqual:right];
}

static NSDictionary<NSString *, NSString *> *MTDetailLibraryRevisionIdentifiers(
    NSArray<MTThemeLibraryThemeSummary *> *themes) {
    NSMutableDictionary<NSString *, NSString *> *result =
        [NSMutableDictionary dictionaryWithCapacity:themes.count];
    for (MTThemeLibraryThemeSummary *theme in themes) {
        if (theme.themeID.length > 0 &&
            theme.currentRevision.revisionIdentifier.length > 0) {
            result[theme.themeID] = theme.currentRevision.revisionIdentifier;
        }
    }
    return [result copy];
}

static NSString *MTDetailVariantGroupTitle(MTThemeVariantGroup *group) {
    if ([group.groupIdentifier isEqualToString:MTBadgesModuleID]) {
        return MTDetailLocalized(@"theme.capability.badges.title");
    }
    if ([group.groupIdentifier isEqualToString:MTIconShadowsModuleID]) {
        return MTDetailLocalized(@"theme.capability.icon-shadows.title");
    }
    return group.groupIdentifier;
}

static NSString *MTDetailVariantGroupSymbol(MTThemeVariantGroup *group) {
    return [group.groupIdentifier isEqualToString:MTBadgesModuleID]
        ? @"app.badge.fill" : @"paintpalette.fill";
}

static NSString *MTDetailMetadata(MTThemeManifest *manifest) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (manifest.author.length > 0) [parts addObject:manifest.author];
    if (manifest.themeVersion.length > 0) {
        [parts addObject:[NSString stringWithFormat:
            MTDetailLocalized(@"theme.meta.version"), manifest.themeVersion]];
    }
    return parts.count > 0
        ? [parts componentsJoinedByString:@" · "]
        : MTDetailLocalized(@"theme.detail.unknown");
}

static NSString *_Nullable MTDetailAppearanceCoverage(
    MTThemeCapabilityItem *item) {
    MTThemeCapabilityAppearanceCoverage coverage = item.appearanceCoverage;
    if (coverage == MTThemeCapabilityAppearanceCoverageNone) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ((coverage & MTThemeCapabilityAppearanceCoverageShared) != 0) {
        [parts addObject:MTDetailLocalized(
            @"theme.capability.appearance.shared")];
    }
    if ((coverage & MTThemeCapabilityAppearanceCoverageLight) != 0) {
        [parts addObject:MTDetailLocalized(
            @"theme.capability.appearance.light")];
    }
    if ((coverage & MTThemeCapabilityAppearanceCoverageDark) != 0) {
        [parts addObject:MTDetailLocalized(
            @"theme.capability.appearance.dark")];
    }
    NSString *joined = [parts componentsJoinedByString:MTDetailLocalized(
        @"theme.capability.appearance.separator")];
    return [NSString stringWithFormat:MTDetailLocalized(
        @"theme.capability.appearance-format"), joined];
}

static NSString *MTDetailFeatureDetail(MTThemeCapabilityItem *item) {
    if (item.availability == MTThemeCapabilityAvailabilityPlanned) {
        return MTDetailLocalized(@"theme.capability.planned-detail");
    }
    if (!item.hasRecognizedContent) {
        return MTDetailLocalized(@"theme.capability.absent-detail");
    }
    NSString *metric = nil;
    switch (item.metricPresentation) {
        case MTThemeCapabilityMetricPresentationIconCount:
            metric = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.capability.icon-count-format"),
                (unsigned long)item.uniqueSubjectCount];
            break;
        case MTThemeCapabilityMetricPresentationComponentProgress:
            metric = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.capability.component-count-format"),
                (unsigned long)item.presentVariants.count,
                (unsigned long)item.expectedComponentCount];
            break;
        case MTThemeCapabilityMetricPresentationStyleCount:
            metric = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.capability.style-count-format"),
                (unsigned long)item.presentVariants.count];
            break;
        case MTThemeCapabilityMetricPresentationSubjectCount:
            metric = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.capability.subject-count-format"),
                (unsigned long)item.uniqueSubjectCount];
            break;
        case MTThemeCapabilityMetricPresentationCalendarLayout:
            metric = MTDetailLocalized(@"theme.capability.calendar-detail");
            break;
        case MTThemeCapabilityMetricPresentationResourceCount:
            metric = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.capability.resource-count-format"),
                (unsigned long)item.resourceCount];
            break;
    }
    NSString *appearance = MTDetailAppearanceCoverage(item);
    return appearance.length == 0 ? (metric ?: @"") :
        [NSString stringWithFormat:MTDetailLocalized(
            @"theme.capability.detail-separator-format"),
            metric ?: @"", appearance];
}

static NSString *MTDetailFeatureStatus(MTThemeCapabilityItem *item) {
    switch (item.availability) {
        case MTThemeCapabilityAvailabilityAbsent:
            return MTDetailLocalized(@"theme.capability.status.absent");
        case MTThemeCapabilityAvailabilityReady:
            return MTDetailLocalized(@"theme.capability.status.ready");
        case MTThemeCapabilityAvailabilityImportedOnly:
            return MTDetailLocalized(@"theme.capability.status.imported-only");
        case MTThemeCapabilityAvailabilityPlanned:
            return MTDetailLocalized(@"theme.capability.status.planned");
    }
    return @"";
}

static UIColor *MTDetailFeatureColor(MTThemeCapabilityItem *item) {
    switch (item.availability) {
        case MTThemeCapabilityAvailabilityReady:
            return MTSuccessColor();
        case MTThemeCapabilityAvailabilityImportedOnly:
            return MTWarningColor();
        case MTThemeCapabilityAvailabilityPlanned:
            return MTAccentColor();
        case MTThemeCapabilityAvailabilityAbsent:
            return UIColor.tertiaryLabelColor;
    }
    return UIColor.tertiaryLabelColor;
}

@interface MTThemeCapabilityCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *symbolBackground;
@property(nonatomic, strong) UIImageView *symbolView;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UISwitch *toggle;
@property(nonatomic, strong) MTPressableButton *sourceButton;
@property(nonatomic, strong) NSLayoutConstraint *nameTrailingToggleConstraint;
@property(nonatomic, strong) NSLayoutConstraint *nameTrailingStatusConstraint;
@property(nonatomic, strong) NSLayoutConstraint *detailBottomConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sourceTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sourceBottomConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sourceHeightConstraint;
@property(nonatomic, copy, nullable) NSString *featureIdentifier;
@property(nonatomic, copy, nullable) void (^toggleHandler)(BOOL enabled);
- (void)configureWithItem:(MTThemeCapabilityItem *)item
                   enabled:(BOOL)enabled
                sourceName:(nullable NSString *)sourceName
                  mixable:(BOOL)mixable
      availableSourceCount:(NSUInteger)availableSourceCount
   selectedSourceAvailable:(BOOL)selectedSourceAvailable
                  editable:(BOOL)editable
                sourceMenu:(nullable UIMenu *)sourceMenu
             toggleHandler:(nullable void (^)(BOOL enabled))toggleHandler;
@end

@implementation MTThemeCapabilityCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = MTCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_card];

    _symbolBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _symbolBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _symbolBackground.layer.cornerRadius = 14.0;
    _symbolBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_symbolBackground];

    _symbolView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _symbolView.translatesAutoresizingMaskIntoConstraints = NO;
    _symbolView.contentMode = UIViewContentModeScaleAspectFit;
    [_symbolBackground addSubview:_symbolView];

    _nameLabel = MTLabel(UIFontTextStyleBody, UIFontWeightSemibold,
                         UIColor.labelColor);
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_nameLabel];

    _detailLabel = MTLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                           UIColor.secondaryLabelColor);
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 2;
    [_card addSubview:_detailLabel];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.layer.cornerRadius = 10.0;
    _statusLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _statusLabel.layer.masksToBounds = YES;
    [_card addSubview:_statusLabel];

    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.onTintColor = MTAccentColor();
    [_toggle addTarget:self action:@selector(toggleValueChanged:)
      forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_toggle];

    _sourceButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    _sourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    _sourceButton.showsMenuAsPrimaryAction = YES;
    _sourceButton.changesSelectionAsPrimaryAction = NO;
    _sourceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _sourceButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_sourceButton setContentCompressionResistancePriority:
        UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [_card addSubview:_sourceButton];

    _nameTrailingToggleConstraint = [_nameLabel.trailingAnchor
        constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-10];
    _nameTrailingStatusConstraint = [_nameLabel.trailingAnchor
        constraintLessThanOrEqualToAnchor:_statusLabel.leadingAnchor constant:-8];
    _detailBottomConstraint = [_detailLabel.bottomAnchor
        constraintEqualToAnchor:_card.bottomAnchor constant:-14];
    _sourceTopConstraint = [_sourceButton.topAnchor
        constraintEqualToAnchor:_detailLabel.bottomAnchor constant:9];
    _sourceBottomConstraint = [_sourceButton.bottomAnchor
        constraintEqualToAnchor:_card.bottomAnchor constant:-14];
    _sourceHeightConstraint = [_sourceButton.heightAnchor
        constraintGreaterThanOrEqualToConstant:32];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                            constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                             constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
        [_symbolBackground.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:14],
        [_symbolBackground.topAnchor constraintEqualToAnchor:_card.topAnchor constant:14],
        [_symbolBackground.widthAnchor constraintEqualToConstant:48],
        [_symbolBackground.heightAnchor constraintEqualToConstant:48],
        [_symbolView.centerXAnchor constraintEqualToAnchor:_symbolBackground.centerXAnchor],
        [_symbolView.centerYAnchor constraintEqualToAnchor:_symbolBackground.centerYAnchor],
        [_symbolView.widthAnchor constraintEqualToConstant:24],
        [_symbolView.heightAnchor constraintEqualToConstant:24],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_symbolBackground.trailingAnchor constant:13],
        [_nameLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:14],
        _nameTrailingStatusConstraint,
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-12],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
        [_statusLabel.heightAnchor constraintEqualToConstant:20],
        [_statusLabel.widthAnchor constraintGreaterThanOrEqualToConstant:54],
        [_toggle.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor
                                                constant:-14],
        [_toggle.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor
                                                     constant:-14],
        [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:4],
        _detailBottomConstraint,
        [_sourceButton.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_sourceButton.trailingAnchor constraintLessThanOrEqualToAnchor:
            _card.trailingAnchor constant:-14],
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.toggleHandler = nil;
    self.sourceButton.menu = nil;
}

- (void)toggleValueChanged:(UISwitch *)toggle {
    if (self.toggleHandler != nil) self.toggleHandler(toggle.isOn);
}

- (void)configureWithItem:(MTThemeCapabilityItem *)item
                   enabled:(BOOL)enabled
                sourceName:(NSString *)sourceName
                  mixable:(BOOL)mixable
      availableSourceCount:(NSUInteger)availableSourceCount
   selectedSourceAvailable:(BOOL)selectedSourceAvailable
                  editable:(BOOL)editable
                sourceMenu:(UIMenu *)sourceMenu
             toggleHandler:(void (^)(BOOL))toggleHandler {
    self.featureIdentifier = item.featureID;
    self.toggleHandler = toggleHandler;
    BOOL hasSources = availableSourceCount > 0;
    BOOL canChooseSource = hasSources &&
        (!selectedSourceAvailable || availableSourceCount > 1);
    UIColor *color = !mixable ? MTDetailFeatureColor(item)
        : (enabled ? MTSuccessColor()
            : (!selectedSourceAvailable && hasSources
                ? MTAccentColor() : UIColor.tertiaryLabelColor));
    self.symbolView.image = [UIImage systemImageNamed:item.symbolName];
    self.symbolView.tintColor = color;
    self.symbolBackground.backgroundColor = MTTintedBackground(color);
    self.nameLabel.text = MTDetailLocalized(item.titleLocalizationKey);
    NSString *metric = MTDetailFeatureDetail(item);
    if ([item.featureID isEqualToString:MTThemeFeatureIconPattern]) {
        metric = [NSString stringWithFormat:
            MTDetailLocalized(@"theme.capability.detail-separator-format"),
            metric ?: @"",
            MTDetailLocalized(@"theme.detail.feature.follows-mask")];
    }
    self.detailLabel.text = metric;
    self.statusLabel.text = [NSString stringWithFormat:@"  %@  ",
        MTDetailFeatureStatus(item)];
    self.statusLabel.textColor = color;
    self.statusLabel.backgroundColor = MTTintedBackground(color);
    self.statusLabel.hidden = mixable;
    self.toggle.hidden = !mixable;
    self.toggle.enabled = mixable && editable && selectedSourceAvailable;
    [self.toggle setOn:enabled animated:NO];
    self.sourceButton.hidden = !mixable;
    self.sourceButton.menu = sourceMenu;
    self.sourceButton.enabled = mixable && editable && canChooseSource;

    self.nameTrailingToggleConstraint.active = mixable;
    self.nameTrailingStatusConstraint.active = !mixable;
    if (mixable) {
        self.detailBottomConstraint.active = NO;
        self.sourceTopConstraint.active = YES;
        self.sourceBottomConstraint.active = YES;
        self.sourceHeightConstraint.active = YES;
    } else {
        self.sourceTopConstraint.active = NO;
        self.sourceBottomConstraint.active = NO;
        self.sourceHeightConstraint.active = NO;
        self.detailBottomConstraint.active = YES;
    }

    NSString *sourceTitle = nil;
    if (!hasSources) {
        sourceTitle = MTDetailLocalized(@"theme.detail.feature.no-source");
    } else if (!selectedSourceAvailable) {
        sourceTitle = MTDetailLocalized(@"theme.detail.feature.choose-source-short");
    } else {
        sourceTitle = [NSString stringWithFormat:
            MTDetailLocalized(@"theme.detail.feature.source-button-format"),
            sourceName ?: @""];
    }
    UIButtonConfiguration *sourceConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    sourceConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    sourceConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(6, 11, 6, 11);
    sourceConfiguration.imagePadding = 6;
    sourceConfiguration.imagePlacement = NSDirectionalRectEdgeLeading;
    sourceConfiguration.image = [UIImage systemImageNamed:
        hasSources ? @"paintpalette.fill" : @"nosign"];
    sourceConfiguration.baseForegroundColor = hasSources
        ? MTAccentColor() : UIColor.secondaryLabelColor;
    sourceConfiguration.baseBackgroundColor = hasSources
        ? MTTintedBackground(MTAccentColor()) : UIColor.tertiarySystemFillColor;
    UIFont *sourceFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];
    sourceConfiguration.attributedTitle = [[NSAttributedString alloc]
        initWithString:sourceTitle ?: @""
        attributes:@{ NSFontAttributeName : sourceFont }];
    self.sourceButton.configuration = sourceConfiguration;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.accessoryType = UITableViewCellAccessoryNone;
    self.contentView.alpha = editable || !mixable ? 1.0 : 0.68;
    self.sourceButton.accessibilityIdentifier = [NSString stringWithFormat:
        @"marktheme.theme-detail.capability.%@.source", item.featureID];
    self.sourceButton.accessibilityLabel = [NSString stringWithFormat:
        MTDetailLocalized(@"theme.detail.feature.source-accessibility-format"),
        self.nameLabel.text ?: @"", sourceTitle ?: @""];
    self.toggle.accessibilityIdentifier = [NSString stringWithFormat:
        @"marktheme.theme-detail.capability.%@.toggle", item.featureID];
    self.toggle.accessibilityLabel = [NSString stringWithFormat:
        MTDetailLocalized(@"theme.detail.feature.toggle-accessibility-format"),
        self.nameLabel.text ?: @""];
    self.toggle.accessibilityHint = selectedSourceAvailable ? nil :
        MTDetailLocalized(@"theme.detail.feature.toggle-source-required-hint");

    if (mixable) {
        self.isAccessibilityElement = NO;
        self.nameLabel.isAccessibilityElement = YES;
        self.nameLabel.accessibilityLabel = self.nameLabel.text;
        self.nameLabel.accessibilityValue = self.detailLabel.text;
        self.accessibilityElements = @[
            self.nameLabel, self.sourceButton, self.toggle,
        ];
    } else {
        self.nameLabel.isAccessibilityElement = NO;
        self.accessibilityElements = nil;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = self.nameLabel.text;
        self.accessibilityValue = [NSString stringWithFormat:@"%@，%@",
            self.statusLabel.text ?: @"", self.detailLabel.text ?: @""];
    }
}

@end

@interface MTThemeConfigurationCell : UITableViewCell
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *iconBackground;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UIImageView *chevronView;
@property(nonatomic, strong) UISwitch *toggle;
@property(nonatomic, copy, nullable) NSString *componentIdentifier;
@property(nonatomic, copy, nullable) void (^toggleHandler)(BOOL enabled);
- (void)configureComponent:(MTThemeComponentDescriptor *)component
                   enabled:(BOOL)enabled
                  editable:(BOOL)editable
             toggleHandler:(void (^)(BOOL enabled))toggleHandler;
- (void)configureVariantGroup:(MTThemeVariantGroup *)group
                       option:(MTThemeVariantOption *)option
                     editable:(BOOL)editable;
@end

@implementation MTThemeConfigurationCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self == nil) return nil;
    self.backgroundColor = UIColor.clearColor;

    _card = MTCardView();
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 18.0;
    [self.contentView addSubview:_card];

    _iconBackground = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBackground.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBackground.layer.cornerRadius = 13.0;
    _iconBackground.layer.cornerCurve = kCACornerCurveContinuous;
    [_card addSubview:_iconBackground];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconBackground addSubview:_iconView];

    _titleLabel = MTLabel(UIFontTextStyleBody, UIFontWeightSemibold,
                          UIColor.labelColor);
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    [_card addSubview:_titleLabel];

    _detailLabel = MTLabel(UIFontTextStyleFootnote, UIFontWeightRegular,
                           UIColor.secondaryLabelColor);
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.numberOfLines = 1;
    [_card addSubview:_detailLabel];

    _valueLabel = MTLabel(UIFontTextStyleSubheadline, UIFontWeightSemibold,
                          MTAccentColor());
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.82;
    [_card addSubview:_valueLabel];

    _chevronView = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    _chevronView.tintColor = UIColor.tertiaryLabelColor;
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [_card addSubview:_chevronView];

    _toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.onTintColor = MTAccentColor();
    [_toggle addTarget:self action:@selector(toggleValueChanged:)
      forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_toggle];

    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                            constant:20],
        [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                             constant:-20],
        [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                         constant:4],
        [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                            constant:-4],
        [_iconBackground.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor
                                                      constant:14],
        [_iconBackground.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_iconBackground.widthAnchor constraintEqualToConstant:40],
        [_iconBackground.heightAnchor constraintEqualToConstant:40],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:19],
        [_iconView.heightAnchor constraintEqualToConstant:19],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor
                                                  constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:13],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:
            _card.trailingAnchor constant:-90],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:
            _card.trailingAnchor constant:-90],
        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                               constant:3],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor
                                                  constant:-13],
        [_chevronView.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor
                                                    constant:-15],
        [_chevronView.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:8],
        [_chevronView.heightAnchor constraintEqualToConstant:14],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:_chevronView.leadingAnchor
                                                   constant:-8],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
        [_valueLabel.widthAnchor constraintLessThanOrEqualToConstant:104],
        [_toggle.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor
                                                constant:-14],
        [_toggle.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
    ]];
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.componentIdentifier = nil;
    self.toggleHandler = nil;
}

- (void)toggleValueChanged:(UISwitch *)sender {
    if (self.toggleHandler != nil) self.toggleHandler(sender.isOn);
}

- (void)configureComponent:(MTThemeComponentDescriptor *)component
                   enabled:(BOOL)enabled
                  editable:(BOOL)editable
             toggleHandler:(void (^)(BOOL enabled))toggleHandler {
    self.componentIdentifier = component.componentIdentifier;
    self.toggleHandler = toggleHandler;
    self.titleLabel.text = component.displayName;
    self.detailLabel.text = [NSString stringWithFormat:
        MTDetailLocalized(@"theme.detail.configuration.resource-count"),
        (unsigned long)component.resourceCount];
    self.iconView.image = [UIImage systemImageNamed:@"square.stack.3d.up.fill"];
    self.iconView.tintColor = MTAccentColor();
    self.iconBackground.backgroundColor = MTTintedBackground(MTAccentColor());
    self.valueLabel.hidden = YES;
    self.chevronView.hidden = YES;
    self.toggle.hidden = NO;
    self.toggle.enabled = editable;
    [self.toggle setOn:enabled animated:NO];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.contentView.alpha = editable ? 1.0 : 0.62;
    self.isAccessibilityElement = NO;
    self.accessibilityLabel = component.displayName;
    self.accessibilityValue = enabled
        ? MTDetailLocalized(@"theme.detail.configuration.enabled")
        : MTDetailLocalized(@"theme.detail.configuration.disabled");
}

- (void)configureVariantGroup:(MTThemeVariantGroup *)group
                       option:(MTThemeVariantOption *)option
                     editable:(BOOL)editable {
    self.componentIdentifier = nil;
    self.toggleHandler = nil;
    self.titleLabel.text = MTDetailVariantGroupTitle(group);
    self.detailLabel.text = [NSString stringWithFormat:
        MTDetailLocalized(@"theme.detail.configuration.style-resource-count"),
        (unsigned long)option.resourceCount];
    self.valueLabel.text = option.displayName;
    self.iconView.image = [UIImage systemImageNamed:
        MTDetailVariantGroupSymbol(group)];
    self.iconView.tintColor = MTAccentColor();
    self.iconBackground.backgroundColor = MTTintedBackground(MTAccentColor());
    self.valueLabel.hidden = NO;
    self.chevronView.hidden = NO;
    self.toggle.hidden = YES;
    self.selectionStyle = editable
        ? UITableViewCellSelectionStyleDefault
        : UITableViewCellSelectionStyleNone;
    self.contentView.alpha = editable ? 1.0 : 0.62;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = self.titleLabel.text;
    self.accessibilityValue = option.displayName;
}

@end

@interface MTThemeDetailViewController ()
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, strong) MTThemePreviewRepository *previewRepository;
@property(nonatomic, copy) NSString *themeIdentifier;
@property(nonatomic, strong, nullable) MTThemeCapabilityReport *capabilityReport;
@property(nonatomic, strong, nullable) MTThemeComponentCatalog *componentCatalog;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *componentSelection;
@property(nonatomic, strong, nullable) MTThemeMixSelection *mixSelection;
@property(nonatomic, copy)
    NSArray<MTThemeComponentDescriptor *> *selectableComponents;
@property(nonatomic, copy)
    NSArray<MTThemeVariantGroup *> *selectableVariantGroups;
@property(nonatomic, copy)
    NSArray<MTThemeCapabilityItem *> *displayedCapabilityItems;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSArray<MTThemeLibraryThemeSummary *> *> *
        featureSourcesByIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeCapabilityReport *> *
        capabilityReportsByThemeIdentifier;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSSet<NSString *> *> *
        availableFeaturesByThemeIdentifier;
@property(nonatomic, copy, nullable) NSString *projectedRevisionIdentifier;
@property(nonatomic, copy, nullable) NSString *projectedActiveThemeIdentifier;
@property(nonatomic, copy, nullable) NSString *projectedActiveRevisionIdentifier;
@property(nonatomic, copy, nullable) NSString *projectedActiveGenerationIdentifier;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *projectedComponentSelection;
@property(nonatomic, strong, nullable)
    MTThemeComponentSelection *projectedActiveComponentSelection;
@property(nonatomic, strong, nullable)
    MTThemeMixSelection *projectedMixSelection;
@property(nonatomic, copy)
    NSDictionary<NSString *, NSString *> *projectedLibraryRevisionIdentifiers;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTThemeComponentSelection *> *
        projectedLibraryComponentSelections;
@property(nonatomic, assign) BOOL projectedMutating;
@property(nonatomic, assign) BOOL projectedRuntimeControlAvailable;
@property(nonatomic, strong, nullable) MTThemePreviewRequest *previewRequest;

@property(nonatomic, strong) UIView *themeHeader;
@property(nonatomic, strong) MTGradientView *heroCard;
@property(nonatomic, strong) MTIconGridView *iconGrid;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *metadataLabel;
@property(nonatomic, strong) UILabel *summaryLabel;
@property(nonatomic, strong) UILabel *runtimeBadge;
@property(nonatomic, strong) MTFloatingActionDockView *actionDock;
@property(nonatomic, strong) MTPressableButton *applyButton;
@property(nonatomic, strong)
    MTTableSupplementaryLayoutCache *headerLayoutCache;
@end

@implementation MTThemeDetailViewController

- (instancetype)initWithManagerController:
        (MTManagerController *)managerController
    previewRepository:(MTThemePreviewRepository *)previewRepository
    themeIdentifier:(NSString *)themeIdentifier {
    NSParameterAssert(managerController != nil);
    NSParameterAssert(previewRepository != nil);
    NSParameterAssert(themeIdentifier.length > 0);
    self = [super initWithStyle:UITableViewStylePlain];
    if (self == nil) return nil;
    _managerController = managerController;
    _previewRepository = previewRepository;
    _themeIdentifier = [themeIdentifier copy];
    _displayedCapabilityItems = @[];
    _featureSourcesByIdentifier = @{};
    _capabilityReportsByThemeIdentifier = @{};
    _availableFeaturesByThemeIdentifier = @{};
    _selectableComponents = @[];
    _selectableVariantGroups = @[];
    _projectedLibraryRevisionIdentifiers = @{};
    _projectedLibraryComponentSelections = @{};
    _headerLayoutCache = [[MTTableSupplementaryLayoutCache alloc] init];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MTDetailLocalized(@"theme.detail.title");
    self.navigationItem.largeTitleDisplayMode =
        UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = MTCanvasColor();
    self.tableView.backgroundColor = MTCanvasColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78.0;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 20, 0);
    self.tableView.accessibilityIdentifier = @"marktheme.theme-detail";
    [self.tableView registerClass:MTThemeCapabilityCell.class
           forCellReuseIdentifier:@"ThemeCapabilityCell"];
    [self.tableView registerClass:MTThemeConfigurationCell.class
           forCellReuseIdentifier:@"ThemeConfigurationCell"];
    [self buildThemeHeader];
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[
            UITraitPreferredContentSizeCategory.class,
        ] withHandler:^(__unused id<UITraitEnvironment> environment,
                        __unused UITraitCollection *previous) {
            [weakSelf.headerLayoutCache invalidate];
            [weakSelf.view setNeedsLayout];
        }];
    }
    [self installFloatingApplyDock];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(managerControllerDidChange:)
               name:MTManagerControllerDidChangeNotification
             object:self.managerController];
    [self updateThemeProjection];
    [self loadPreview];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.previewRequest cancel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.actionDock];
    [self.headerLayoutCache fitHeaderView:self.themeHeader
                              inTableView:self.tableView];
}

- (void)buildThemeHeader {
    self.themeHeader = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), 1)];
    self.heroCard = [[MTGradientView alloc] initWithFrame:CGRectZero];
    self.heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroCard.layer.cornerRadius = 24.0;
    self.heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.heroCard.layer.masksToBounds = YES;
    [self.themeHeader addSubview:self.heroCard];

    self.iconGrid = [[MTIconGridView alloc] initWithFrame:CGRectZero];
    self.iconGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [self.heroCard addSubview:self.iconGrid];

    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    self.nameLabel.textColor = UIColor.labelColor;
    self.nameLabel.numberOfLines = 2;
    [self.heroCard addSubview:self.nameLabel];

    self.metadataLabel = MTLabel(UIFontTextStyleSubheadline,
                                 UIFontWeightMedium,
                                 UIColor.secondaryLabelColor);
    self.metadataLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.metadataLabel.numberOfLines = 2;
    [self.heroCard addSubview:self.metadataLabel];

    self.summaryLabel = MTLabel(UIFontTextStyleFootnote,
                                UIFontWeightRegular,
                                UIColor.secondaryLabelColor);
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.numberOfLines = 2;
    [self.heroCard addSubview:self.summaryLabel];

    self.runtimeBadge = [[UILabel alloc] initWithFrame:CGRectZero];
    self.runtimeBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.runtimeBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.runtimeBadge.textAlignment = NSTextAlignmentCenter;
    self.runtimeBadge.layer.cornerRadius = 11.0;
    self.runtimeBadge.layer.cornerCurve = kCACornerCurveContinuous;
    self.runtimeBadge.layer.masksToBounds = YES;
    [self.heroCard addSubview:self.runtimeBadge];

    [NSLayoutConstraint activateConstraints:@[
        [self.heroCard.leadingAnchor constraintEqualToAnchor:self.themeHeader.leadingAnchor constant:20],
        [self.heroCard.trailingAnchor constraintEqualToAnchor:self.themeHeader.trailingAnchor constant:-20],
        [self.heroCard.topAnchor constraintEqualToAnchor:self.themeHeader.topAnchor constant:8],
        [self.heroCard.bottomAnchor constraintEqualToAnchor:self.themeHeader.bottomAnchor constant:-12],
        [self.iconGrid.leadingAnchor constraintEqualToAnchor:self.heroCard.leadingAnchor constant:20],
        [self.iconGrid.topAnchor constraintEqualToAnchor:self.heroCard.topAnchor constant:20],
        [self.iconGrid.widthAnchor constraintEqualToConstant:96],
        [self.iconGrid.heightAnchor constraintEqualToConstant:96],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconGrid.trailingAnchor constant:16],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.heroCard.trailingAnchor constant:-20],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.heroCard.topAnchor constant:20],
        [self.metadataLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.metadataLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
        [self.metadataLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:6],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:self.metadataLabel.bottomAnchor constant:8],
        [self.runtimeBadge.leadingAnchor constraintEqualToAnchor:self.heroCard.leadingAnchor constant:20],
        [self.runtimeBadge.topAnchor constraintGreaterThanOrEqualToAnchor:self.iconGrid.bottomAnchor constant:12],
        [self.runtimeBadge.topAnchor constraintGreaterThanOrEqualToAnchor:self.summaryLabel.bottomAnchor constant:10],
        [self.runtimeBadge.heightAnchor constraintEqualToConstant:22],
        [self.runtimeBadge.widthAnchor constraintGreaterThanOrEqualToConstant:90],
        [self.runtimeBadge.bottomAnchor constraintEqualToAnchor:self.heroCard.bottomAnchor
                                                        constant:-16],
    ]];
    self.tableView.tableHeaderView = self.themeHeader;
}

- (void)installFloatingApplyDock {
    self.actionDock = [[MTFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.actionDock];

    self.applyButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    self.applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.applyButton.accessibilityIdentifier = @"marktheme.theme-detail.apply";
    [self.applyButton addTarget:self action:@selector(applyTheme:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.applyButton];

    UIEdgeInsets contentInset = self.tableView.contentInset;
    contentInset.bottom = MAX(contentInset.bottom, 92.0);
    self.tableView.contentInset = contentInset;
    UIEdgeInsets indicatorInsets = self.tableView.verticalScrollIndicatorInsets;
    indicatorInsets.bottom = MAX(indicatorInsets.bottom, 92.0);
    self.tableView.verticalScrollIndicatorInsets = indicatorInsets;

    [NSLayoutConstraint activateConstraints:@[
        [self.actionDock.leadingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.leadingAnchor],
        [self.actionDock.trailingAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor],
        [self.actionDock.bottomAnchor
            constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor],
        [self.applyButton.leadingAnchor
            constraintEqualToAnchor:self.actionDock.leadingAnchor constant:20],
        [self.applyButton.trailingAnchor
            constraintEqualToAnchor:self.actionDock.trailingAnchor constant:-20],
        [self.applyButton.topAnchor
            constraintEqualToAnchor:self.actionDock.topAnchor constant:14],
        [self.applyButton.heightAnchor constraintEqualToConstant:54],
        [self.applyButton.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                             constant:-12],
    ]];
}

- (MTThemeLibraryThemeSummary *)themeSummary {
    return [self.managerController.snapshot
        themeWithIdentifier:self.themeIdentifier];
}

- (void)updateThemeProjection {
    MTThemeLibraryThemeSummary *theme = self.themeSummary;
    NSString *revisionIdentifier = theme.currentRevision.revisionIdentifier;
    BOOL revisionChanged = !MTDetailStringsEqual(
        self.projectedRevisionIdentifier, revisionIdentifier);
    MTThemeManifest *manifest = theme.currentRevision.manifest;
    MTManagerSnapshot *snapshot = self.managerController.snapshot;
    NSDictionary<NSString *, NSString *> *libraryRevisionIdentifiers =
        MTDetailLibraryRevisionIdentifiers(snapshot.themes);
    NSDictionary<NSString *, MTThemeComponentSelection *> *librarySelections =
        snapshot.componentSelectionsByThemeIdentifier;
    BOOL libraryFeatureInputsChanged =
        ![self.projectedLibraryRevisionIdentifiers
            isEqualToDictionary:libraryRevisionIdentifiers] ||
        ![self.projectedLibraryComponentSelections
            isEqualToDictionary:librarySelections];
    if (libraryFeatureInputsChanged) {
        // Manager builds these immutable indexes while loading Library data on
        // its worker queue. Runtime-only notifications reuse them, and a
        // component edit replaces only the changed theme's availability set.
        self.capabilityReportsByThemeIdentifier =
            snapshot.capabilityReportsByThemeIdentifier;
        self.availableFeaturesByThemeIdentifier =
            snapshot.availableFeatureIdentifiersByThemeIdentifier;
    }
    if (revisionChanged) {
        self.capabilityReport =
            self.capabilityReportsByThemeIdentifier[self.themeIdentifier];
        self.componentCatalog = manifest == nil ? nil
            : [MTThemeComponentCatalog catalogForManifest:manifest error:NULL];
        NSMutableArray<MTThemeComponentDescriptor *> *components =
            [NSMutableArray array];
        for (MTThemeComponentDescriptor *component in
                self.componentCatalog.components) {
            if (!component.isRequired) [components addObject:component];
        }
        self.selectableComponents = components;
        NSMutableArray<MTThemeVariantGroup *> *variantGroups =
            [NSMutableArray array];
        for (MTThemeVariantGroup *group in
                self.componentCatalog.variantGroups) {
            if (group.options.count > 1) [variantGroups addObject:group];
        }
        self.selectableVariantGroups = variantGroups;
        self.nameLabel.text = manifest.displayName ?:
            MTDetailLocalized(@"theme.detail.title");
        self.metadataLabel.text = manifest == nil
            ? MTDetailLocalized(@"home.loading-library")
            : MTDetailMetadata(manifest);
        MTThemeCapabilityItem *appIcons =
            [self.capabilityReport itemForFeatureID:MTThemeFeatureAppIcons];
        self.summaryLabel.text = [NSString stringWithFormat:
            MTDetailLocalized(@"theme.detail.summary-format"),
            (unsigned long)appIcons.uniqueSubjectCount,
            (unsigned long)self.capabilityReport.recognizedFeatureCount];
        self.heroCard.gradientColors =
            MTThemeGradientColors(self.themeIdentifier);
        [self.headerLayoutCache invalidate];
        [self.view setNeedsLayout];
    }
    self.componentSelection = [snapshot
        componentSelectionForThemeIdentifier:self.themeIdentifier] ?:
        self.componentCatalog.defaultSelection;
    MTThemeMixSelection *nextMixSelection = [snapshot
        mixSelectionForThemeIdentifier:self.themeIdentifier];
    BOOL mixSelectionChanged = !MTDetailObjectsEqual(
        self.mixSelection, nextMixSelection);
    self.mixSelection = nextMixSelection;

    if (libraryFeatureInputsChanged) {
        NSMutableDictionary<NSString *,
            NSArray<MTThemeLibraryThemeSummary *> *> *featureSources =
                [NSMutableDictionary dictionary];
        for (MTThemeCapabilityItem *baseItem in self.capabilityReport.items) {
            NSMutableArray<MTThemeLibraryThemeSummary *> *sources =
                [NSMutableArray array];
            for (MTThemeLibraryThemeSummary *candidateTheme in snapshot.themes) {
                if ([self.availableFeaturesByThemeIdentifier[
                        candidateTheme.themeID]
                        containsObject:baseItem.featureID]) {
                    [sources addObject:candidateTheme];
                }
            }
            [sources sortUsingComparator:^NSComparisonResult(
                MTThemeLibraryThemeSummary *left,
                MTThemeLibraryThemeSummary *right) {
                BOOL leftBase = [left.themeID
                    isEqualToString:self.themeIdentifier];
                BOOL rightBase = [right.themeID
                    isEqualToString:self.themeIdentifier];
                if (leftBase != rightBase) {
                    return leftBase ? NSOrderedAscending : NSOrderedDescending;
                }
                NSString *leftName = left.currentRevision.manifest.displayName ?:
                    left.themeID;
                NSString *rightName = right.currentRevision.manifest.displayName ?:
                    right.themeID;
                NSComparisonResult result = [leftName
                    localizedStandardCompare:rightName];
                return result != NSOrderedSame ? result :
                    [left.themeID compare:right.themeID
                                   options:NSLiteralSearch];
            }];
            featureSources[baseItem.featureID] = [sources copy];
        }
        self.featureSourcesByIdentifier = [featureSources copy];
    }
    if (libraryFeatureInputsChanged || mixSelectionChanged) {
        NSMutableArray<MTThemeCapabilityItem *> *displayedItems =
            [NSMutableArray array];
        for (MTThemeCapabilityItem *baseItem in self.capabilityReport.items) {
            NSArray<MTThemeLibraryThemeSummary *> *sources =
                self.featureSourcesByIdentifier[baseItem.featureID] ?: @[];
            NSString *selectedSourceIdentifier = [self.mixSelection
                sourceThemeIdentifierForFeatureIdentifier:baseItem.featureID] ?:
                self.themeIdentifier;
            MTThemeCapabilityItem *selectedItem =
                [self.capabilityReportsByThemeIdentifier[
                    selectedSourceIdentifier]
                    itemForFeatureID:baseItem.featureID];
            MTThemeCapabilityItem *presentationItem =
                selectedItem.hasRecognizedContent ? selectedItem : baseItem;
            if (!presentationItem.hasRecognizedContent && sources.count > 0) {
                presentationItem = [self.capabilityReportsByThemeIdentifier[
                    sources.firstObject.themeID]
                    itemForFeatureID:baseItem.featureID];
            }
            // Product capability rows are stable. Missing artwork changes only
            // the row state; it never removes a feature from the mix workspace.
            [displayedItems addObject:presentationItem ?: baseItem];
        }
        self.displayedCapabilityItems = [displayedItems copy];
    }

    BOOL sameTheme = MTDetailStringsEqual(snapshot.activeThemeIdentifier,
                                          self.themeIdentifier);
    BOOL sameRevision = sameTheme && MTDetailStringsEqual(
        snapshot.activeRevisionIdentifier,
        theme.currentRevision.revisionIdentifier);
    BOOL exactActive = [snapshot
        runtimeMatchesCurrentSelectionForThemeIdentifier:self.themeIdentifier];
    NSString *badge = exactActive
        ? MTDetailLocalized(@"theme.detail.badge.runtime-active")
        : (sameRevision
            ? MTDetailLocalized(
                @"theme.detail.badge.configuration-changed")
            : (sameTheme
            ? MTDetailLocalized(@"theme.detail.badge.runtime-old")
            : MTDetailLocalized(@"theme.detail.badge.library-only")));
    UIColor *badgeColor = exactActive ? MTSuccessColor()
        : (sameTheme ? MTWarningColor() : MTAccentColor());
    self.runtimeBadge.text = [NSString stringWithFormat:@"  %@  ", badge];
    self.runtimeBadge.textColor = badgeColor;
    self.runtimeBadge.backgroundColor = MTTintedBackground(badgeColor);

    UIButtonConfiguration *apply =
        [UIButtonConfiguration filledButtonConfiguration];
    apply.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    apply.imagePadding = 8;
    if (snapshot.isMutating || snapshot.isRuntimeRefreshing) {
        apply.title = MTDetailLocalized(@"apply.preparing");
        apply.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
        apply.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        apply.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (!snapshot.runtimeControlAvailable) {
        apply.title = MTDetailLocalized(@"theme.detail.device-only");
        apply.image = [UIImage systemImageNamed:@"iphone.slash"];
        apply.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        apply.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else if (exactActive) {
        apply.title = MTDetailLocalized(@"theme.detail.in-use");
        apply.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        apply.baseBackgroundColor = UIColor.tertiarySystemFillColor;
        apply.baseForegroundColor = UIColor.secondaryLabelColor;
        self.applyButton.enabled = NO;
    } else {
        apply.title = MTDetailLocalized(sameRevision
            ? @"theme.detail.apply-changes"
            : @"theme.detail.apply-current");
        apply.image = [UIImage systemImageNamed:@"paintbrush.fill"];
        apply.baseBackgroundColor = MTPrimaryActionColor();
        apply.baseForegroundColor = MTPrimaryActionForegroundColor();
        self.applyButton.enabled = theme != nil;
    }
    self.applyButton.configuration = apply;
    self.projectedRevisionIdentifier = revisionIdentifier;
    self.projectedActiveThemeIdentifier = snapshot.activeThemeIdentifier;
    self.projectedActiveRevisionIdentifier = snapshot.activeRevisionIdentifier;
    self.projectedActiveGenerationIdentifier =
        snapshot.activeGenerationIdentifier;
    self.projectedComponentSelection = self.componentSelection;
    self.projectedActiveComponentSelection =
        snapshot.activeComponentSelection;
    self.projectedMixSelection = self.mixSelection;
    self.projectedLibraryRevisionIdentifiers = libraryRevisionIdentifiers;
    self.projectedLibraryComponentSelections = librarySelections;
    self.projectedMutating =
        snapshot.isMutating || snapshot.isRuntimeRefreshing;
    self.projectedRuntimeControlAvailable = snapshot.runtimeControlAvailable;
}

- (void)loadPreview {
    [self.previewRequest cancel];
    self.previewRequest = nil;
    MTThemeLibraryThemeSummary *summary = self.themeSummary;
    if (summary == nil) return;
    NSArray<UIImage *> *cached =
        [self.previewRepository presentationImagesForThemeSummary:summary];
    if (cached != nil) {
        [self.iconGrid setIconImages:cached animated:NO];
        return;
    }
    NSString *revisionIdentifier = summary.currentRevision.revisionIdentifier;
    __weak typeof(self) weakSelf = self;
    __block MTThemePreviewRequest *request = nil;
    request = [self.previewRepository loadImagesForThemeSummary:summary
        priority:MTThemePreviewPriorityHigh
        completion:^(NSArray<UIImage *> *images) {
        typeof(self) self = weakSelf;
        if (self == nil) return;
        if (self.previewRequest == request) self.previewRequest = nil;
        if (![self.themeSummary.currentRevision.revisionIdentifier
                isEqualToString:revisionIdentifier]) return;
        NSArray<UIImage *> *presentation = [self.previewRepository
            presentationImagesForThemeSummary:self.themeSummary];
        [self.iconGrid setIconImages:presentation ?: images animated:YES];
    }];
    self.previewRequest = request;
}

- (void)managerControllerDidChange:(NSNotification *)notification {
    (void)notification;
    MTManagerSnapshot *snapshot = self.managerController.snapshot;
    NSString *revisionIdentifier =
        self.themeSummary.currentRevision.revisionIdentifier;
    BOOL revisionChanged = !MTDetailStringsEqual(
        self.projectedRevisionIdentifier, revisionIdentifier);
    BOOL runtimeSelectionChanged =
        !MTDetailStringsEqual(self.projectedActiveThemeIdentifier,
                              snapshot.activeThemeIdentifier) ||
        !MTDetailStringsEqual(self.projectedActiveRevisionIdentifier,
                              snapshot.activeRevisionIdentifier) ||
        !MTDetailStringsEqual(self.projectedActiveGenerationIdentifier,
                              snapshot.activeGenerationIdentifier) ||
        !MTDetailObjectsEqual(self.projectedActiveComponentSelection,
                              snapshot.activeComponentSelection);
    MTThemeComponentSelection *nextSelection = [snapshot
        componentSelectionForThemeIdentifier:self.themeIdentifier];
    BOOL componentSelectionChanged = !MTDetailObjectsEqual(
        self.projectedComponentSelection, nextSelection);
    MTThemeMixSelection *nextMixSelection = [snapshot
        mixSelectionForThemeIdentifier:self.themeIdentifier];
    BOOL mixSelectionChanged = !MTDetailObjectsEqual(
        self.projectedMixSelection, nextMixSelection);
    BOOL librarySourcesChanged = ![self.projectedLibraryRevisionIdentifiers
        isEqualToDictionary:
            MTDetailLibraryRevisionIdentifiers(snapshot.themes)];
    BOOL libraryComponentSelectionsChanged =
        ![self.projectedLibraryComponentSelections isEqualToDictionary:
            snapshot.componentSelectionsByThemeIdentifier];
    BOOL operationChanged = self.projectedMutating !=
        (snapshot.isMutating || snapshot.isRuntimeRefreshing);
    BOOL runtimeAvailabilityChanged =
        self.projectedRuntimeControlAvailable !=
            snapshot.runtimeControlAvailable;
    BOOL projectionChanged = revisionChanged ||
        runtimeSelectionChanged || componentSelectionChanged ||
        mixSelectionChanged || librarySourcesChanged ||
        libraryComponentSelectionsChanged || operationChanged ||
        runtimeAvailabilityChanged;
    if (!projectionChanged) return;
    [self updateThemeProjection];
    if (revisionChanged) {
        [self.tableView reloadData];
        [self loadPreview];
    } else if (librarySourcesChanged) {
        [self.tableView reloadData];
    } else {
        NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
        if (self.configurationSectionIndex >= 0 &&
            (componentSelectionChanged || operationChanged)) {
            [sections addIndex:(NSUInteger)self.configurationSectionIndex];
        }
        if (mixSelectionChanged || libraryComponentSelectionsChanged ||
            operationChanged) {
            [sections addIndex:(NSUInteger)self.contentsSectionIndex];
        }
        if (sections.count > 0) {
            [self.tableView reloadSections:sections
                          withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

- (BOOL)showsConfigurationSection {
    return self.selectableComponents.count > 0 ||
        self.selectableVariantGroups.count > 0;
}

- (NSInteger)configurationSectionIndex {
    return self.showsConfigurationSection ? 0 : -1;
}

- (NSInteger)contentsSectionIndex {
    return self.showsConfigurationSection ? 1 : 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1 + (self.showsConfigurationSection ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView
  numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == self.configurationSectionIndex) {
        return (NSInteger)(self.selectableComponents.count +
            self.selectableVariantGroups.count);
    }
    if (section == self.contentsSectionIndex) {
        return (NSInteger)self.displayedCapabilityItems.count;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == self.configurationSectionIndex) {
        return MTDetailLocalized(@"theme.detail.section.configuration");
    }
    return MTDetailLocalized(@"theme.detail.section.contents");
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == self.configurationSectionIndex) {
        MTThemeConfigurationCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"ThemeConfigurationCell"
                                  forIndexPath:indexPath];
        BOOL editable = self.managerController.snapshot.operation ==
            MTManagerOperationIdle &&
            !self.managerController.snapshot.isLibraryRefreshing &&
            !self.managerController.snapshot.isRuntimeRefreshing;
        NSUInteger row = (NSUInteger)indexPath.row;
        if (row < self.selectableComponents.count) {
            MTThemeComponentDescriptor *component =
                self.selectableComponents[row];
            BOOL enabled = [self.componentSelection
                isComponentEnabled:component.componentIdentifier];
            __weak typeof(self) weakSelf = self;
            [cell configureComponent:component enabled:enabled
                editable:editable toggleHandler:^(BOOL nextEnabled) {
                [weakSelf.managerController
                    setComponentIdentifier:component.componentIdentifier
                    enabled:nextEnabled
                    forThemeIdentifier:weakSelf.themeIdentifier
                    completion:^(BOOL success, NSError *error) {
                    if (!success) {
                        [weakSelf presentOperationError:error];
                        NSInteger section = weakSelf.configurationSectionIndex;
                        if (section >= 0) {
                            [weakSelf.tableView reloadSections:
                                [NSIndexSet indexSetWithIndex:(NSUInteger)section]
                                withRowAnimation:UITableViewRowAnimationNone];
                        }
                    } else {
                        [[[UISelectionFeedbackGenerator alloc] init]
                            selectionChanged];
                    }
                }];
            }];
            cell.accessibilityIdentifier = [
                @"marktheme.theme-detail.component."
                stringByAppendingString:component.componentIdentifier];
        } else {
            MTThemeVariantGroup *group = self.selectableVariantGroups[
                row - self.selectableComponents.count];
            NSString *variantIdentifier = [self.componentSelection
                selectedVariantForGroup:group.groupIdentifier] ?:
                group.defaultVariantIdentifier;
            MTThemeVariantOption *option = [group
                optionWithIdentifier:variantIdentifier] ?: group.options.firstObject;
            [cell configureVariantGroup:group option:option editable:editable];
            cell.accessibilityIdentifier = [
                @"marktheme.theme-detail.variant."
                stringByAppendingString:group.groupIdentifier];
        }
        return cell;
    }

    if (indexPath.section == self.contentsSectionIndex) {
        MTThemeCapabilityCell *cell = [tableView
            dequeueReusableCellWithIdentifier:@"ThemeCapabilityCell"
                                  forIndexPath:indexPath];
        MTThemeCapabilityItem *item =
            self.displayedCapabilityItems[(NSUInteger)indexPath.row];
        NSArray<MTThemeLibraryThemeSummary *> *sources =
            self.featureSourcesByIdentifier[item.featureID] ?: @[];
        BOOL mixable = self.mixSelection != nil &&
            MTThemeFeatureSupportsMixing(item.featureID);
        NSString *sourceIdentifier = [self.mixSelection
            sourceThemeIdentifierForFeatureIdentifier:item.featureID] ?:
            self.themeIdentifier;
        MTThemeLibraryThemeSummary *selectedSourceTheme = nil;
        for (MTThemeLibraryThemeSummary *source in sources) {
            if ([source.themeID isEqualToString:sourceIdentifier]) {
                selectedSourceTheme = source;
                break;
            }
        }
        BOOL selectedSourceAvailable = selectedSourceTheme != nil;
        BOOL desiredEnabled = mixable &&
            [self.mixSelection isFeatureEnabled:item.featureID];
        BOOL enabled = mixable
            ? (desiredEnabled && selectedSourceAvailable)
            : item.isRuntimeApplicable;
        NSString *sourceName = selectedSourceTheme.currentRevision.manifest
            .displayName ?: selectedSourceTheme.themeID;
        if (selectedSourceAvailable &&
            [selectedSourceTheme.themeID isEqualToString:self.themeIdentifier]) {
            sourceName = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.detail.feature.base-source-format"),
                sourceName ?: self.themeIdentifier];
        }
        BOOL editable = self.managerController.snapshot.operation ==
            MTManagerOperationIdle &&
            !self.managerController.snapshot.isLibraryRefreshing &&
            !self.managerController.snapshot.isRuntimeRefreshing;
        UIMenu *sourceMenu = mixable ? [self
            sourceMenuForItem:item
            sources:sources
            selectedSourceIdentifier:sourceIdentifier] : nil;
        __weak typeof(self) weakSelf = self;
        [cell configureWithItem:item
            enabled:enabled
            sourceName:sourceName
            mixable:mixable
            availableSourceCount:sources.count
            selectedSourceAvailable:selectedSourceAvailable
            editable:editable
            sourceMenu:sourceMenu
            toggleHandler:^(BOOL nextEnabled) {
            [weakSelf.managerController
                setFeatureIdentifier:item.featureID
                enabled:nextEnabled
                forBaseThemeIdentifier:weakSelf.themeIdentifier
                completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [weakSelf presentOperationError:error];
                    [weakSelf.tableView reloadSections:[NSIndexSet
                        indexSetWithIndex:
                            (NSUInteger)weakSelf.contentsSectionIndex]
                        withRowAnimation:UITableViewRowAnimationNone];
                } else {
                    [[[UISelectionFeedbackGenerator alloc] init]
                        selectionChanged];
                }
            }];
        }];
        cell.accessibilityIdentifier = [@"marktheme.theme-detail.capability."
            stringByAppendingString:item.featureID];
        return cell;
    }

    return [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == self.configurationSectionIndex) {
        NSUInteger row = (NSUInteger)indexPath.row;
        if (row < self.selectableComponents.count ||
            self.managerController.snapshot.operation != MTManagerOperationIdle) {
            return;
        }
        NSUInteger groupIndex = row - self.selectableComponents.count;
        if (groupIndex < self.selectableVariantGroups.count) {
            [self presentVariantPickerForGroup:
                self.selectableVariantGroups[groupIndex]
                sourceView:[tableView cellForRowAtIndexPath:indexPath]];
        }
        return;
    }
    return;
}

- (UIMenu *)sourceMenuForItem:(MTThemeCapabilityItem *)item
                       sources:
                           (NSArray<MTThemeLibraryThemeSummary *> *)sources
      selectedSourceIdentifier:(NSString *)selectedSourceIdentifier {
    if (sources.count == 0) return nil;
    NSMutableArray<UIMenuElement *> *actions =
        [NSMutableArray arrayWithCapacity:sources.count];
    __weak typeof(self) weakSelf = self;
    for (MTThemeLibraryThemeSummary *source in sources) {
        NSString *name = source.currentRevision.manifest.displayName ?:
            source.themeID;
        BOOL baseSource = [source.themeID
            isEqualToString:self.themeIdentifier];
        if (baseSource) {
            name = [NSString stringWithFormat:
                MTDetailLocalized(@"theme.detail.feature.base-source-format"),
                name];
        }
        UIAction *action = [UIAction
            actionWithTitle:name
            image:[UIImage systemImageNamed:
                baseSource ? @"house.fill" : @"paintpalette.fill"]
            identifier:nil
            handler:^(__unused UIAction *selectedAction) {
            [weakSelf.managerController
                setSourceThemeIdentifier:source.themeID
                forFeatureIdentifier:item.featureID
                baseThemeIdentifier:weakSelf.themeIdentifier
                completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [weakSelf presentOperationError:error];
                } else {
                    [[[UISelectionFeedbackGenerator alloc] init]
                        selectionChanged];
                }
            }];
        }];
        action.state = [source.themeID
            isEqualToString:selectedSourceIdentifier]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@""
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:actions];
}

- (void)presentVariantPickerForGroup:(MTThemeVariantGroup *)group
                          sourceView:(UIView *)sourceView {
    NSString *selected = [self.componentSelection
        selectedVariantForGroup:group.groupIdentifier];
    UIAlertController *picker = [UIAlertController
        alertControllerWithTitle:MTDetailVariantGroupTitle(group)
        message:MTDetailLocalized(@"theme.detail.configuration.choose-style")
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (MTThemeVariantOption *option in group.options) {
        BOOL isSelected = [option.variantIdentifier isEqualToString:selected];
        NSString *title = isSelected
            ? [NSString stringWithFormat:@"✓ %@", option.displayName]
            : option.displayName;
        [picker addAction:[UIAlertAction
            actionWithTitle:title
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
            [weakSelf.managerController
                selectVariantIdentifier:option.variantIdentifier
                forGroupIdentifier:group.groupIdentifier
                themeIdentifier:weakSelf.themeIdentifier
                completion:^(BOOL success, NSError *error) {
                if (!success) {
                    [weakSelf presentOperationError:error];
                } else {
                    [[[UISelectionFeedbackGenerator alloc] init]
                        selectionChanged];
                }
            }];
        }]];
    }
    [picker addAction:[UIAlertAction
        actionWithTitle:MTDetailLocalized(@"common.cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = sourceView ?: self.view;
    picker.popoverPresentationController.sourceRect = sourceView == nil
        ? self.view.bounds : sourceView.bounds;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)applyTheme:(id)sender {
    (void)sender;
    [self.managerController selectThemeIdentifier:self.themeIdentifier];
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
                initWithThemeName:self.nameLabel.text
                  restoredStock:NO
               managerController:self.managerController];
        [self presentViewController:resultController
                           animated:YES completion:nil];
    }];
}

- (void)presentApplyError:(NSError *)error {
    NSLog(@"MarkTheme theme Apply failed (%@/%ld): %@", error.domain,
          (long)error.code, error.localizedDescription);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTDetailLocalized(@"apply.error.title")
        message:MTErrorPresentationMessage(
            MTDetailLocalized(@"apply.error.detail"), error)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTDetailLocalized(@"common.ok")
                  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentOperationError:(NSError *)error {
    NSLog(@"MarkTheme theme management failed (%@/%ld): %@", error.domain,
          (long)error.code, error.localizedDescription);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTDetailLocalized(@"theme.detail.operation-error")
        message:MTDetailLocalized(@"theme.detail.operation-error-detail")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTDetailLocalized(@"common.ok")
                  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
