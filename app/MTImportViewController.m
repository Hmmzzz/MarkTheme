#import "MTImportViewController.h"

#import <math.h>
#import <sys/stat.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "MTDesignSystem.h"
#import "MTDiagnostic.h"
#import "MTImportDiagnostics.h"
#import "MTImportCoordinator.h"
#import "MTInstalledThemeLocator.h"
#import "MTSafeImageDecoder.h"
#import "MTThemeCapabilityReport.h"
#import "MTThemeImport.h"
#import "MTThemeLibraryStore.h"
#import "MTThemeManifest.h"

NSString *const MTThemeArchiveContentTypeIdentifier =
    @"com.hmmzzz.marktheme.theme-archive";

static NSString *MTImportLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

static UIImage *_Nullable MTImportPreviewImage(
    MTThemeImportPreviewArtifact *_Nullable artifact) {
    MTSafeImageDecodeResult *result = artifact.decodeResult;
    if (result == nil ||
        ![result.pixelFormat
            isEqualToString:MTSafeImagePixelFormatRGBA8PremultipliedLast] ||
        result.thumbnailPixelWidth == 0 || result.thumbnailPixelHeight == 0 ||
        result.thumbnailBytesPerRow < result.thumbnailPixelWidth * 4U ||
        result.thumbnailPixelData.length <
            result.thumbnailBytesPerRow * result.thumbnailPixelHeight) {
        return nil;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)result.thumbnailPixelData);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Big |
        kCGImageAlphaPremultipliedLast;
    CGImageRef image = provider == NULL || colorSpace == NULL ? NULL :
        CGImageCreate(result.thumbnailPixelWidth,
                      result.thumbnailPixelHeight,
                      8, 32, result.thumbnailBytesPerRow,
                      colorSpace, bitmapInfo, provider,
                      NULL, false, kCGRenderingIntentDefault);
    UIImage *preview = image == NULL ? nil : [UIImage imageWithCGImage:image];
    if (image != NULL) CGImageRelease(image);
    if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
    if (provider != NULL) CGDataProviderRelease(provider);
    return preview;
}

static NSString *MTImportPhaseTitle(MTImportWorkflowPhase phase) {
    switch (phase) {
        case MTImportWorkflowPhaseIdle:
            return MTImportLocalized(@"import.hero.idle-title");
        case MTImportWorkflowPhaseAcquiring:
            return MTImportLocalized(@"import.phase.acquiring");
        case MTImportWorkflowPhaseAuditing:
            return MTImportLocalized(@"import.phase.auditing");
        case MTImportWorkflowPhaseParsing:
            return MTImportLocalized(@"import.phase.parsing");
        case MTImportWorkflowPhaseStaging:
            return MTImportLocalized(@"import.phase.staging");
        case MTImportWorkflowPhaseValidating:
            return MTImportLocalized(@"import.phase.validating");
        case MTImportWorkflowPhaseReadyForReview:
            return MTImportLocalized(@"import.phase.ready");
        case MTImportWorkflowPhaseCommitting:
            return MTImportLocalized(@"import.phase.committing");
        case MTImportWorkflowPhaseCompleted:
            return MTImportLocalized(@"import.phase.completed");
        case MTImportWorkflowPhaseCancelling:
            return MTImportLocalized(@"import.phase.cancelling");
        case MTImportWorkflowPhaseCancelled:
            return MTImportLocalized(@"import.phase.cancelled");
        case MTImportWorkflowPhaseFailed:
            return MTImportLocalized(@"import.phase.failed");
    }
    return MTImportLocalized(@"import.phase.failed");
}

static NSString *MTImportPhaseDetail(MTImportWorkflowPhase phase) {
    switch (phase) {
        case MTImportWorkflowPhaseIdle:
            return MTImportLocalized(@"import.hero.idle-detail");
        case MTImportWorkflowPhaseAcquiring:
            return MTImportLocalized(@"import.phase.acquiring-detail");
        case MTImportWorkflowPhaseAuditing:
            return MTImportLocalized(@"import.phase.auditing-detail");
        case MTImportWorkflowPhaseParsing:
            return MTImportLocalized(@"import.phase.parsing-detail");
        case MTImportWorkflowPhaseStaging:
            return MTImportLocalized(@"import.phase.staging-detail");
        case MTImportWorkflowPhaseValidating:
            return MTImportLocalized(@"import.phase.validating-detail");
        case MTImportWorkflowPhaseReadyForReview:
            return MTImportLocalized(@"import.phase.ready-detail");
        case MTImportWorkflowPhaseCommitting:
            return MTImportLocalized(@"import.phase.committing-detail");
        case MTImportWorkflowPhaseCompleted:
            return MTImportLocalized(@"import.phase.completed-detail");
        case MTImportWorkflowPhaseCancelling:
            return MTImportLocalized(@"import.phase.cancelling-detail");
        case MTImportWorkflowPhaseCancelled:
            return MTImportLocalized(@"import.phase.cancelled-detail");
        case MTImportWorkflowPhaseFailed:
            return MTImportLocalized(@"import.phase.failed-detail");
    }
    return MTImportLocalized(@"import.phase.failed-detail");
}

static NSString *MTImportFriendlyError(NSError *_Nullable error) {
    if ([error.domain isEqualToString:MTThemeImportErrorDomain]) {
        switch ((MTThemeImportErrorCode)error.code) {
            case MTThemeImportErrorCancelled:
                return MTImportLocalized(@"import.error.cancelled");
            case MTThemeImportErrorAcquisition:
            case MTThemeImportErrorDirectorySnapshot:
                return MTImportLocalized(@"import.error.access");
            case MTThemeImportErrorArchiveAudit:
                return MTImportLocalized(@"import.error.archive");
            case MTThemeImportErrorMetadata:
            case MTThemeImportErrorImporter:
                return MTImportLocalized(@"import.error.format");
            case MTThemeImportErrorAssetStaging:
                return MTImportLocalized(@"import.error.storage");
            case MTThemeImportErrorImageValidation:
                return MTImportLocalized(@"import.error.image");
            case MTThemeImportErrorCleanup:
                return MTImportLocalized(@"import.error.cleanup");
            case MTThemeImportErrorLibraryCommit:
                return MTImportLocalized(@"import.error.save");
            case MTThemeImportErrorInvalidRequest:
            case MTThemeImportErrorInvalidState:
                break;
        }
    }
    return MTImportLocalized(@"import.error.generic");
}

static NSString *MTImportDiagnosticText(MTDiagnostic *diagnostic) {
    NSString *key = [@"diagnostic." stringByAppendingString:diagnostic.code];
    NSString *localized = MTImportLocalized(key);
    return [localized isEqualToString:key] ? diagnostic.summary : localized;
}

static NSString *MTImportCapabilityNames(MTThemeCapabilityReport *report) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (MTThemeCapabilityItem *item in report.items) {
        if (!item.hasRecognizedContent) continue;
        [names addObject:MTImportLocalized(item.titleLocalizationKey)];
    }
    return [names componentsJoinedByString:MTImportLocalized(
        @"import.review.capabilities-separator")];
}

static BOOL MTImportPhaseIsBusy(MTImportWorkflowPhase phase) {
    switch (phase) {
        case MTImportWorkflowPhaseAcquiring:
        case MTImportWorkflowPhaseAuditing:
        case MTImportWorkflowPhaseParsing:
        case MTImportWorkflowPhaseStaging:
        case MTImportWorkflowPhaseValidating:
        case MTImportWorkflowPhaseCommitting:
        case MTImportWorkflowPhaseCancelling:
            return YES;
        default:
            return NO;
    }
}

typedef NS_ENUM(NSUInteger, MTImportPrimaryActionPresentation) {
    MTImportPrimaryActionPresentationChoose,
    MTImportPrimaryActionPresentationChooseAnother,
    MTImportPrimaryActionPresentationCancel,
    MTImportPrimaryActionPresentationSave,
    MTImportPrimaryActionPresentationRetrySave,
    MTImportPrimaryActionPresentationDone,
};

static MTImportPrimaryActionPresentation MTImportPrimaryActionForSnapshot(
    MTImportWorkflowSnapshot *snapshot) {
    if (MTImportPhaseIsBusy(snapshot.phase)) {
        return MTImportPrimaryActionPresentationCancel;
    }
    if (snapshot.phase == MTImportWorkflowPhaseReadyForReview) {
        return MTImportPrimaryActionPresentationSave;
    }
    if (snapshot.phase == MTImportWorkflowPhaseFailed &&
        snapshot.canRetryCommit) {
        return MTImportPrimaryActionPresentationRetrySave;
    }
    if (snapshot.phase == MTImportWorkflowPhaseCompleted) {
        return MTImportPrimaryActionPresentationDone;
    }
    return snapshot.phase == MTImportWorkflowPhaseIdle
        ? MTImportPrimaryActionPresentationChoose
        : MTImportPrimaryActionPresentationChooseAnother;
}

static float MTImportStageFraction(MTImportWorkflowSnapshot *snapshot) {
    if (snapshot.totalUnitCount == 0) return 0.0f;
    return MIN(1.0f, (float)snapshot.completedUnitCount /
                         (float)snapshot.totalUnitCount);
}

static float MTImportOverallProgress(MTImportWorkflowSnapshot *snapshot) {
    float fraction = MTImportStageFraction(snapshot);
    switch (snapshot.phase) {
        case MTImportWorkflowPhaseAcquiring:
            return 0.02f + fraction * 0.10f;
        case MTImportWorkflowPhaseAuditing:
            return 0.12f + fraction * 0.08f;
        case MTImportWorkflowPhaseParsing:
            return 0.20f + fraction * 0.10f;
        case MTImportWorkflowPhaseStaging:
            return 0.30f + fraction * 0.40f;
        case MTImportWorkflowPhaseValidating:
            return 0.70f + fraction * 0.22f;
        case MTImportWorkflowPhaseReadyForReview:
            return 0.92f;
        case MTImportWorkflowPhaseCommitting:
            return 0.92f + fraction * 0.08f;
        case MTImportWorkflowPhaseCompleted:
            return 1.0f;
        default:
            return 0.0f;
    }
}

@interface MTImportSkeletonBlockView : UIView
- (instancetype)initWithColor:(UIColor *)color;
- (void)setAnimating:(BOOL)animating;
@end

@implementation MTImportSkeletonBlockView

- (instancetype)initWithColor:(UIColor *)color {
    self = [super initWithFrame:CGRectZero];
    if (self == nil) return nil;
    self.backgroundColor = color;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = NO;
    return self;
}

- (void)setAnimating:(BOOL)animating {
    [self.layer removeAnimationForKey:@"marktheme.skeleton.pulse"];
    self.layer.opacity = 0.72f;
    if (!animating || UIAccessibilityIsReduceMotionEnabled()) return;
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @0.46f;
    pulse.toValue = @0.86f;
    pulse.duration = 0.82;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:pulse forKey:@"marktheme.skeleton.pulse"];
}

@end

@interface MTImportSkeletonGridView : UIView
@property(nonatomic, copy) NSArray<MTImportSkeletonBlockView *> *blocks;
- (void)setAnimating:(BOOL)animating;
@end

@implementation MTImportSkeletonGridView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = NO;
    NSMutableArray *blocks = [NSMutableArray arrayWithCapacity:4];
    for (NSUInteger index = 0; index < 4; index++) {
        MTImportSkeletonBlockView *block = [[MTImportSkeletonBlockView alloc]
            initWithColor:[UIColor.whiteColor colorWithAlphaComponent:0.52]];
        [self addSubview:block];
        [blocks addObject:block];
    }
    _blocks = blocks;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    CGFloat spacing = MAX(6.0, MIN(10.0, side * 0.065));
    CGFloat dimension = floor((side - spacing) / 2.0);
    for (NSUInteger index = 0; index < self.blocks.count; index++) {
        NSUInteger column = index % 2;
        NSUInteger row = index / 2;
        MTImportSkeletonBlockView *block = self.blocks[index];
        block.frame = CGRectMake(column * (dimension + spacing),
                                 row * (dimension + spacing),
                                 dimension, dimension);
        block.layer.cornerRadius = dimension * 0.2253;
    }
}

- (void)setAnimating:(BOOL)animating {
    for (MTImportSkeletonBlockView *block in self.blocks) {
        [block setAnimating:animating];
    }
}

@end

@interface MTImportHeroView : MTGradientView
@property(nonatomic, strong) UILabel *badgeLabel;
@property(nonatomic, strong) MTIconGridView *iconGrid;
@property(nonatomic, strong) MTImportSkeletonGridView *skeletonGrid;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) NSLayoutConstraint *titleLeadingConstraint;
@property(nonatomic, assign) BOOL hasConfigured;
@property(nonatomic, assign) BOOL showingPreview;
@property(nonatomic, assign) BOOL hasProgressState;
@property(nonatomic, assign) BOOL progressVisible;
@property(nonatomic, assign) float displayedProgress;
@property(nonatomic, assign) MTImportWorkflowPhase lastPhase;
- (void)updatePresentationWithSnapshot:(MTImportWorkflowSnapshot *)snapshot
                        preparedImport:
                            (nullable MTPreparedThemeImport *)prepared
                              animated:(BOOL)animated;
- (void)updateProgressWithSnapshot:(MTImportWorkflowSnapshot *)snapshot
                          animated:(BOOL)animated;
@end

@implementation MTImportHeroView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.isAccessibilityElement = YES;

    _badgeLabel = MTLabel(UIFontTextStyleCaption1, UIFontWeightSemibold,
                          [UIColor colorWithWhite:0.12 alpha:0.88]);
    _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.54];
    _badgeLabel.layer.cornerRadius = 12.0;
    _badgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
    _badgeLabel.layer.masksToBounds = YES;
    [self addSubview:_badgeLabel];

    _iconGrid = [[MTIconGridView alloc] initWithFrame:CGRectZero];
    _iconGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_iconGrid];

    _skeletonGrid = [[MTImportSkeletonGridView alloc] initWithFrame:CGRectZero];
    _skeletonGrid.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_skeletonGrid];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    _titleLabel.textColor = MTSpecimenInkColor();
    _titleLabel.numberOfLines = 2;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.74;
    [self addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _detailLabel.textColor = MTSpecimenSecondaryInkColor();
    _detailLabel.numberOfLines = 3;
    [self addSubview:_detailLabel];

    _progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.progressTintColor = MTSpecimenInkColor();
    _progressView.trackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.42];
    _progressView.layer.cornerRadius = 2.0;
    _progressView.clipsToBounds = YES;
    _progressView.hidden = YES;
    [self addSubview:_progressView];

    _titleLeadingConstraint =
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:168];
    [NSLayoutConstraint activateConstraints:@[
        [_badgeLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:20],
        [_badgeLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
        [_badgeLabel.heightAnchor constraintEqualToConstant:25],
        [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:88],

        [_iconGrid.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
        [_iconGrid.topAnchor constraintEqualToAnchor:_badgeLabel.bottomAnchor constant:12],
        [_iconGrid.widthAnchor constraintEqualToConstant:132],
        [_iconGrid.heightAnchor constraintEqualToConstant:132],
        [_skeletonGrid.leadingAnchor constraintEqualToAnchor:_iconGrid.leadingAnchor],
        [_skeletonGrid.trailingAnchor constraintEqualToAnchor:_iconGrid.trailingAnchor],
        [_skeletonGrid.topAnchor constraintEqualToAnchor:_iconGrid.topAnchor],
        [_skeletonGrid.bottomAnchor constraintEqualToAnchor:_iconGrid.bottomAnchor],

        _titleLeadingConstraint,
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
        [_titleLabel.topAnchor constraintEqualToAnchor:_badgeLabel.bottomAnchor constant:28],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_detailLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:7],
        [_detailLabel.bottomAnchor constraintLessThanOrEqualToAnchor:
            _progressView.topAnchor constant:-12],

        [_progressView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:22],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-22],
        [_progressView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-20],
    ]];
    return self;
}

- (void)updatePresentationWithSnapshot:(MTImportWorkflowSnapshot *)snapshot
                        preparedImport:(MTPreparedThemeImport *)prepared
                              animated:(BOOL)animated {
    NSString *themeIdentifier = prepared.manifest.themeID;
    NSArray<MTThemeImportPreviewArtifact *> *artifacts =
        prepared.previewArtifacts ?: @[];
    NSMutableArray<UIImage *> *images = [NSMutableArray arrayWithCapacity:4];
    for (MTThemeImportPreviewArtifact *artifact in artifacts) {
        UIImage *image = MTImportPreviewImage(artifact);
        if (image != nil) [images addObject:image];
        if (images.count == 4) break;
    }

    BOOL showsThemePreview = prepared != nil &&
        (snapshot.phase == MTImportWorkflowPhaseReadyForReview ||
         snapshot.phase == MTImportWorkflowPhaseCommitting ||
         snapshot.phase == MTImportWorkflowPhaseCompleted ||
         (snapshot.phase == MTImportWorkflowPhaseFailed && snapshot.canRetryCommit));
    BOOL completed = snapshot.phase == MTImportWorkflowPhaseCompleted;
    BOOL committing = snapshot.phase == MTImportWorkflowPhaseCommitting;
    BOOL failed = snapshot.phase == MTImportWorkflowPhaseFailed;
    BOOL busy = MTImportPhaseIsBusy(snapshot.phase);
    BOOL hasPreview = prepared != nil;
    BOOL previewAvailabilityChanged =
        self.hasConfigured && self.showingPreview != hasPreview;
    NSString *title = showsThemePreview
        ? prepared.manifest.displayName
        : MTImportPhaseTitle(snapshot.phase);
    NSString *detail = showsThemePreview
        ? (prepared.manifest.author.length > 0
            ? prepared.manifest.author
            : MTImportLocalized(@"theme.meta.system-theme"))
        : (failed ? MTImportFriendlyError(snapshot.error)
                  : MTImportPhaseDetail(snapshot.phase));
    void (^updates)(void) = ^{
        self.gradientColors = MTThemeGradientColors(themeIdentifier);
        self.titleLeadingConstraint.constant = 168.0;
        self.badgeLabel.text = completed
            ? MTImportLocalized(@"import.badge.saved")
            : (committing
                ? MTImportLocalized(@"import.badge.saving")
                : (showsThemePreview
                    ? MTImportLocalized(@"import.badge.preview")
                    : (busy ? MTImportLocalized(@"import.badge.checking")
                            : MTImportLocalized(@"import.badge.new-theme"))));
        self.titleLabel.text = title;
        self.detailLabel.text = detail;
        [self.iconGrid setIconImages:images
                           animated:animated && previewAvailabilityChanged];
        self.iconGrid.hidden = !hasPreview;
        self.skeletonGrid.hidden = hasPreview;
        [self.skeletonGrid setAnimating:!hasPreview && busy];
        self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@，%@",
            self.badgeLabel.text, title, detail];
    };
    updates();
    self.hasConfigured = YES;
    self.showingPreview = hasPreview;
}

- (void)updateProgressWithSnapshot:(MTImportWorkflowSnapshot *)snapshot
                          animated:(BOOL)animated {
    BOOL busy = MTImportPhaseIsBusy(snapshot.phase);
    BOOL beginsNewImport = snapshot.phase == MTImportWorkflowPhaseAcquiring &&
        self.hasProgressState &&
        (self.lastPhase == MTImportWorkflowPhaseIdle ||
         self.lastPhase == MTImportWorkflowPhaseCancelled ||
         self.lastPhase == MTImportWorkflowPhaseCompleted ||
         self.lastPhase == MTImportWorkflowPhaseFailed);
    if (beginsNewImport) {
        self.displayedProgress = 0.0f;
        [self.progressView setProgress:0.0f animated:NO];
    }
    if (!self.hasProgressState || self.progressVisible != busy) {
        self.progressVisible = busy;
        self.progressView.hidden = !busy;
    }
    float progress = snapshot.phase == MTImportWorkflowPhaseCancelling
        ? self.displayedProgress
        : MTImportOverallProgress(snapshot);
    float nextProgress = MAX(self.displayedProgress, progress);
    if (fabsf(nextProgress - self.displayedProgress) > 0.0001f) {
        self.displayedProgress = nextProgress;
        [self.progressView setProgress:nextProgress animated:animated];
    }
    self.hasProgressState = YES;
    self.lastPhase = snapshot.phase;
}

@end

@interface MTImportMetricsCard : UIView
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, copy) NSArray<UILabel *> *valueLabels;
@property(nonatomic, copy) NSArray<UILabel *> *captionLabels;
@property(nonatomic, copy)
    NSArray<MTImportSkeletonBlockView *> *skeletonBlocks;
@property(nonatomic, assign) BOOL hasConfigured;
@property(nonatomic, assign) BOOL showingValues;
- (void)configureWithPreparedImport:
        (nullable MTPreparedThemeImport *)prepared
                            loading:(BOOL)loading
                           animated:(BOOL)animated;
@end

@implementation MTImportMetricsCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.backgroundColor = MTCardColor();
    self.layer.cornerRadius = 22.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.layer.borderColor = MTHairlineColor().CGColor;

    _titleLabel = MTLabel(UIFontTextStyleSubheadline,
                          UIFontWeightSemibold,
                          UIColor.labelColor);
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.numberOfLines = 1;
    [self addSubview:_titleLabel];

    UIStackView *metrics = [[UIStackView alloc] initWithFrame:CGRectZero];
    metrics.translatesAutoresizingMaskIntoConstraints = NO;
    metrics.axis = UILayoutConstraintAxisHorizontal;
    metrics.alignment = UIStackViewAlignmentFill;
    metrics.distribution = UIStackViewDistributionFillEqually;
    metrics.spacing = 8.0;
    [self addSubview:metrics];

    NSArray<NSString *> *captions = @[
        MTImportLocalized(@"import.review.metric.resources"),
        MTImportLocalized(@"import.review.metric.files"),
        MTImportLocalized(@"import.review.metric.size"),
    ];
    NSMutableArray<UILabel *> *valueLabels = [NSMutableArray arrayWithCapacity:3];
    NSMutableArray<UILabel *> *captionLabels = [NSMutableArray arrayWithCapacity:3];
    NSMutableArray<MTImportSkeletonBlockView *> *skeletons =
        [NSMutableArray arrayWithCapacity:3];
    for (NSString *caption in captions) {
        UIStackView *metric = [[UIStackView alloc] initWithFrame:CGRectZero];
        metric.axis = UILayoutConstraintAxisVertical;
        metric.alignment = UIStackViewAlignmentLeading;
        metric.spacing = 2.0;

        UIView *valueContainer = [[UIView alloc] initWithFrame:CGRectZero];
        valueContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [valueContainer.heightAnchor constraintEqualToConstant:26].active = YES;

        UILabel *valueLabel = MTLabel(UIFontTextStyleTitle3,
                                      UIFontWeightBold,
                                      UIColor.labelColor);
        valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        valueLabel.numberOfLines = 1;
        valueLabel.adjustsFontSizeToFitWidth = YES;
        valueLabel.minimumScaleFactor = 0.72;
        [valueContainer addSubview:valueLabel];

        MTImportSkeletonBlockView *skeleton = [[MTImportSkeletonBlockView alloc]
            initWithColor:UIColor.tertiarySystemFillColor];
        skeleton.translatesAutoresizingMaskIntoConstraints = NO;
        skeleton.layer.cornerRadius = 7.0;
        [valueContainer addSubview:skeleton];

        [NSLayoutConstraint activateConstraints:@[
            [valueLabel.leadingAnchor constraintEqualToAnchor:valueContainer.leadingAnchor],
            [valueLabel.trailingAnchor constraintEqualToAnchor:valueContainer.trailingAnchor],
            [valueLabel.centerYAnchor constraintEqualToAnchor:valueContainer.centerYAnchor],
            [skeleton.leadingAnchor constraintEqualToAnchor:valueContainer.leadingAnchor],
            [skeleton.centerYAnchor constraintEqualToAnchor:valueContainer.centerYAnchor],
            [skeleton.widthAnchor constraintEqualToConstant:54],
            [skeleton.heightAnchor constraintEqualToConstant:18],
        ]];

        UILabel *captionLabel = MTLabel(UIFontTextStyleCaption1,
                                        UIFontWeightRegular,
                                        UIColor.secondaryLabelColor);
        captionLabel.numberOfLines = 1;
        captionLabel.text = caption;
        [metric addArrangedSubview:valueContainer];
        [metric addArrangedSubview:captionLabel];
        [metrics addArrangedSubview:metric];
        [valueLabels addObject:valueLabel];
        [captionLabels addObject:captionLabel];
        [skeletons addObject:skeleton];
    }
    _valueLabels = valueLabels;
    _captionLabels = captionLabels;
    _skeletonBlocks = skeletons;

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
        [metrics.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [metrics.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [metrics.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:14],
        [metrics.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
    ]];
    self.isAccessibilityElement = YES;
    return self;
}

- (void)configureWithPreparedImport:(MTPreparedThemeImport *)prepared
                            loading:(BOOL)loading
                           animated:(BOOL)animated {
    NSArray<NSString *> *values = nil;
    if (prepared != nil) {
        NSString *size = [NSByteCountFormatter
            stringFromByteCount:(long long)prepared.assetByteCount
                      countStyle:NSByteCountFormatterCountStyleFile];
        values = @[
            [NSString stringWithFormat:@"%lu",
                (unsigned long)prepared.manifest.resources.count],
            [NSString stringWithFormat:@"%lu",
                (unsigned long)prepared.uniqueAssetCount],
            size,
        ];
    }
    BOOL hasValues = values != nil;
    BOOL availabilityChanged =
        self.hasConfigured && self.showingValues != hasValues;
    void (^updates)(void) = ^{
        self.titleLabel.text = prepared == nil && loading
            ? MTImportLocalized(@"import.review.loading-title")
            : MTImportLocalized(@"import.review.contents-title");
        for (NSUInteger index = 0; index < self.valueLabels.count; index++) {
            UILabel *valueLabel = self.valueLabels[index];
            MTImportSkeletonBlockView *skeleton = self.skeletonBlocks[index];
            valueLabel.text = values == nil ? nil : values[index];
            valueLabel.hidden = !hasValues;
            skeleton.hidden = hasValues;
            [skeleton setAnimating:!hasValues && loading];
        }
        if (values == nil) {
            self.accessibilityLabel = self.titleLabel.text;
        } else {
            self.accessibilityLabel = [NSString stringWithFormat:
                @"%@，%@ %@，%@ %@，%@ %@",
                self.titleLabel.text,
                values[0], self.captionLabels[0].text,
                values[1], self.captionLabels[1].text,
                values[2], self.captionLabels[2].text];
        }
    };
    if (animated && availabilityChanged &&
        !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:self
                          duration:0.18
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:updates
                        completion:nil];
    } else {
        updates();
    }
    self.hasConfigured = YES;
    self.showingValues = hasValues;
}

@end

@interface MTImportViewController () <UIDocumentPickerDelegate,
                                       UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy, nullable) MTThemeImportCompletionHandler completionHandler;
@property(nonatomic, strong) MTImportCoordinator *coordinator;
@property(nonatomic, strong) MTImportWorkflowSnapshot *snapshot;
@property(nonatomic, strong, nullable) MTPreparedThemeImport *reviewedImport;
@property(nonatomic, strong, nullable)
    MTThemeCapabilityReport *capabilityReport;
@property(nonatomic, assign) BOOL pendingSourcePicker;
@property(nonatomic, assign) BOOL deliveredCompletion;

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIView *contentView;
@property(nonatomic, strong) MTImportHeroView *heroView;
@property(nonatomic, strong) UIStackView *summaryStack;
@property(nonatomic, strong) MTImportMetricsCard *metricsCard;
@property(nonatomic, strong) MTFloatingActionDockView *actionDock;
@property(nonatomic, strong) MTPressableButton *primaryButton;
- (void)presentThemeSourcePicker;
- (void)presentInstalledThemesFromLocator;
@end

@implementation MTImportViewController

- (instancetype)init {
    return [self initWithCompletionHandler:nil];
}

- (instancetype)initWithCompletionHandler:
        (MTThemeImportCompletionHandler)completionHandler {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) _completionHandler = [completionHandler copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTCanvasColor();
    self.title = MTImportLocalized(@"import.title");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;

    MTPressableButton *closeButton =
        [MTPressableButton buttonWithType:UIButtonTypeSystem];
    closeButton.accessibilityLabel = MTImportLocalized(@"common.close");
    UIButtonConfiguration *closeConfiguration =
        [UIButtonConfiguration tintedButtonConfiguration];
    closeConfiguration.image = [UIImage systemImageNamed:@"xmark"];
    closeConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    closeConfiguration.baseForegroundColor = MTAccentColor();
    closeConfiguration.baseBackgroundColor = MTAccentColor();
    closeButton.configuration = closeConfiguration;
    [closeButton addTarget:self action:@selector(close:) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.widthAnchor constraintEqualToConstant:36],
        [closeButton.heightAnchor constraintEqualToConstant:36],
    ]];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:closeButton];
    if (self.navigationController.viewControllers.firstObject != self) {
        self.navigationItem.rightBarButtonItem = nil;
    }

    [self buildInterface];
    MTThemeImportPipeline *pipeline = [[MTThemeImportPipeline alloc] init];
    self.coordinator = [[MTImportCoordinator alloc] initWithPipeline:pipeline];
    __weak typeof(self) weakSelf = self;
    self.coordinator.stateDidChangeHandler = ^(MTImportWorkflowSnapshot *snapshot) {
        [weakSelf consumeSnapshot:snapshot animated:YES];
    };
    [self consumeSnapshot:self.coordinator.snapshot animated:NO];
}

- (void)dealloc {
    self.coordinator.stateDidChangeHandler = nil;
    [self.coordinator cancel];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.pendingSourcePicker) return;
    self.pendingSourcePicker = NO;
    [self presentInstalledThemeChoiceOrSourcePicker];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.view bringSubviewToFront:self.actionDock];
}

- (void)buildInterface {
    self.scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentView = [[UIView alloc] initWithFrame:CGRectZero];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentView];

    self.heroView = [[MTImportHeroView alloc] initWithFrame:CGRectZero];
    self.heroView.translatesAutoresizingMaskIntoConstraints = NO;
    self.heroView.layer.cornerRadius = 24.0;
    [self.contentView addSubview:self.heroView];

    self.summaryStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.summaryStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryStack.axis = UILayoutConstraintAxisVertical;
    self.summaryStack.spacing = 12.0;
    [self.contentView addSubview:self.summaryStack];

    self.metricsCard = [[MTImportMetricsCard alloc] initWithFrame:CGRectZero];
    self.metricsCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.summaryStack addArrangedSubview:self.metricsCard];

    self.actionDock = [[MTFloatingActionDockView alloc] initWithFrame:CGRectZero];
    self.actionDock.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionDock.accessibilityIdentifier = @"marktheme.import.action-dock";
    [self.view addSubview:self.actionDock];

    self.primaryButton = [MTPressableButton buttonWithType:UIButtonTypeSystem];
    self.primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.primaryButton.accessibilityIdentifier = @"marktheme.import.primary";
    [self.primaryButton addTarget:self action:@selector(performPrimaryAction:)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.actionDock addSubview:self.primaryButton];

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

        [self.heroView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:20],
        [self.heroView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                     constant:-20],
        [self.heroView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                constant:16],
        [self.heroView.heightAnchor
            constraintGreaterThanOrEqualToConstant:222],

        [self.summaryStack.leadingAnchor constraintEqualToAnchor:self.heroView.leadingAnchor],
        [self.summaryStack.trailingAnchor constraintEqualToAnchor:self.heroView.trailingAnchor],
        [self.summaryStack.topAnchor constraintEqualToAnchor:self.heroView.bottomAnchor
                                                    constant:16],
        [self.summaryStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                       constant:-104],

        [self.actionDock.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.actionDock.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.actionDock.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.primaryButton.leadingAnchor constraintEqualToAnchor:self.actionDock.leadingAnchor
                                                         constant:20],
        [self.primaryButton.trailingAnchor constraintEqualToAnchor:self.actionDock.trailingAnchor
                                                          constant:-20],
        [self.primaryButton.topAnchor constraintEqualToAnchor:self.actionDock.topAnchor
                                                     constant:14],
        [self.primaryButton.heightAnchor constraintEqualToConstant:54],
        [self.primaryButton.bottomAnchor constraintEqualToAnchor:
            self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];
}

- (void)consumeSnapshot:(MTImportWorkflowSnapshot *)snapshot
                animated:(BOOL)animated {
    if (snapshot == self.snapshot) return;
    MTImportWorkflowSnapshot *previousSnapshot = self.snapshot;
    MTPreparedThemeImport *previousDisplayImport =
        previousSnapshot.preparedImport ?: self.reviewedImport;
    if (snapshot.preparedImport != nil) {
        self.reviewedImport = snapshot.preparedImport;
    } else if (snapshot.phase == MTImportWorkflowPhaseIdle ||
               snapshot.phase == MTImportWorkflowPhaseCancelled ||
               (snapshot.phase == MTImportWorkflowPhaseFailed &&
                !snapshot.canRetryCommit)) {
        self.reviewedImport = nil;
    }
    self.snapshot = snapshot;
    // Commit snapshots intentionally carry only workflow progress. Keep the
    // reviewed payload visible so Ready -> Saving -> Saved is one continuous
    // screen instead of briefly falling back to the empty skeleton state.
    MTPreparedThemeImport *displayImport =
        snapshot.preparedImport ?: self.reviewedImport;
    if (previousDisplayImport != displayImport) {
        self.capabilityReport = displayImport == nil ? nil :
            [MTThemeCapabilityReport reportForManifest:displayImport.manifest];
    }
    BOOL firstPresentation = previousSnapshot == nil;
    BOOL phaseChanged = firstPresentation ||
        previousSnapshot.phase != snapshot.phase;
    BOOL preparedImportChanged = previousDisplayImport != displayImport;
    BOOL errorChanged = previousSnapshot.error != snapshot.error;
    BOOL heroPresentationChanged = firstPresentation || phaseChanged ||
        preparedImportChanged ||
        (snapshot.phase == MTImportWorkflowPhaseFailed && errorChanged);
    BOOL previousShowsLoadingSummary = previousDisplayImport == nil &&
        previousSnapshot != nil && MTImportPhaseIsBusy(previousSnapshot.phase);
    BOOL showsLoadingSummary = displayImport == nil &&
        MTImportPhaseIsBusy(snapshot.phase);
    BOOL previousShowsFailureSummary = previousDisplayImport != nil &&
        previousSnapshot.phase == MTImportWorkflowPhaseFailed;
    BOOL showsFailureSummary = displayImport != nil &&
        snapshot.phase == MTImportWorkflowPhaseFailed;
    BOOL summaryChanged = firstPresentation || preparedImportChanged ||
        previousShowsLoadingSummary != showsLoadingSummary ||
        previousShowsFailureSummary != showsFailureSummary ||
        (showsFailureSummary && errorChanged);
    BOOL primaryActionChanged = firstPresentation ||
        MTImportPrimaryActionForSnapshot(previousSnapshot) !=
            MTImportPrimaryActionForSnapshot(snapshot) ||
        previousSnapshot.canCancel != snapshot.canCancel;
    if (snapshot.phase == MTImportWorkflowPhaseCompleted &&
        !self.deliveredCompletion && snapshot.libraryRevision != nil) {
        self.deliveredCompletion = YES;
        self.completionHandler(snapshot.libraryRevision.manifest.themeID);
        [[[UINotificationFeedbackGenerator alloc] init]
            notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    if (heroPresentationChanged) {
        [self.heroView updatePresentationWithSnapshot:snapshot
                                       preparedImport:displayImport
                                             animated:animated];
    }
    [self.heroView updateProgressWithSnapshot:snapshot animated:animated];
    if (summaryChanged) [self rebuildSummaryAnimated:animated];
    if (primaryActionChanged) [self updatePrimaryButton];
}

- (UIView *)infoCardWithSymbol:(NSString *)symbol
                         title:(NSString *)title
                        detail:(NSString *)detail
                         color:(UIColor *)color {
    UIView *card = MTCardView();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = color;
    [card addSubview:icon];
    UILabel *titleLabel = MTLabel(UIFontTextStyleSubheadline,
                                  UIFontWeightSemibold,
                                  UIColor.labelColor);
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    [card addSubview:titleLabel];
    UILabel *detailLabel = MTLabel(UIFontTextStyleFootnote,
                                   UIFontWeightRegular,
                                   UIColor.secondaryLabelColor);
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = detail;
    detailLabel.numberOfLines = 0;
    [card addSubview:detailLabel];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [icon.widthAnchor constraintEqualToConstant:23],
        [icon.heightAnchor constraintEqualToConstant:23],
        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:13],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [detailLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

- (void)rebuildSummaryAnimated:(BOOL)animated {
    for (UIView *view in self.summaryStack.arrangedSubviews.copy) {
        if (view == self.metricsCard) continue;
        [self.summaryStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    MTImportWorkflowSnapshot *snapshot = self.snapshot;
    MTPreparedThemeImport *prepared =
        snapshot.preparedImport ?: self.reviewedImport;
    [self.metricsCard configureWithPreparedImport:prepared
                                           loading:MTImportPhaseIsBusy(snapshot.phase)
                                          animated:animated];
    if (prepared != nil) {
        MTThemeCapabilityReport *report = self.capabilityReport;
        if (report.recognizedFeatureCount > 0) {
            NSString *title = [NSString stringWithFormat:
                MTImportLocalized(@"import.review.capabilities-title-format"),
                (unsigned long)report.recognizedFeatureCount];
            NSString *detail = [NSString stringWithFormat:
                MTImportLocalized(@"import.review.capabilities-detail-format"),
                (unsigned long)report.runtimeApplicableFeatureCount,
                MTImportCapabilityNames(report)];
            [self.summaryStack addArrangedSubview:[self
                infoCardWithSymbol:@"square.grid.2x2.fill"
                             title:title
                            detail:detail
                             color:MTAccentColor()]];
        }
        NSUInteger skipped = prepared.ignoredFileCount + prepared.rejectedFileCount;
        if (skipped > 0 || prepared.diagnostics.count > 0) {
            NSString *diagnostic = skipped > 0
                ? MTImportLocalized(@"import.review.skipped-detail")
                : MTImportDiagnosticText(prepared.diagnostics.firstObject);
            NSString *title = skipped > 0
                ? [NSString stringWithFormat:
                    MTImportLocalized(@"import.review.skipped-format"),
                    (unsigned long)skipped]
                : MTImportLocalized(@"import.review.notice-title");
            [self.summaryStack addArrangedSubview:[self
                infoCardWithSymbol:@"info.circle.fill"
                             title:title
                            detail:diagnostic
                             color:MTWarningColor()]];
        }
        if (snapshot.phase == MTImportWorkflowPhaseFailed) {
            [self.summaryStack addArrangedSubview:[self
                infoCardWithSymbol:@"exclamationmark.triangle.fill"
                             title:MTImportLocalized(@"import.review.save-failed")
                            detail:MTImportFriendlyError(snapshot.error)
                             color:MTWarningColor()]];
        }
        return;
    }
}

- (void)updatePrimaryButton {
    MTImportWorkflowSnapshot *snapshot = self.snapshot;
    UIButtonConfiguration *configuration = nil;
    if (MTImportPhaseIsBusy(snapshot.phase)) {
        configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.title = MTImportLocalized(@"import.action.cancel");
        configuration.image = [UIImage systemImageNamed:@"xmark"];
        configuration.baseForegroundColor = MTDangerColor();
        configuration.baseBackgroundColor = MTDangerColor();
        self.primaryButton.enabled = snapshot.canCancel;
        self.primaryButton.accessibilityIdentifier = @"marktheme.import.cancel";
    } else {
        configuration = [UIButtonConfiguration filledButtonConfiguration];
        configuration.baseBackgroundColor = MTPrimaryActionColor();
        configuration.baseForegroundColor = MTPrimaryActionForegroundColor();
        self.primaryButton.enabled = YES;
        if (snapshot.phase == MTImportWorkflowPhaseReadyForReview) {
            configuration.title = MTImportLocalized(@"import.action.save");
            configuration.image = [UIImage systemImageNamed:@"arrow.down.doc.fill"];
            self.primaryButton.accessibilityIdentifier = @"marktheme.import.confirm";
        } else if (snapshot.phase == MTImportWorkflowPhaseFailed &&
                   snapshot.canRetryCommit) {
            configuration.title = MTImportLocalized(@"import.action.retry-save");
            configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            self.primaryButton.accessibilityIdentifier = @"marktheme.import.retry-commit";
        } else if (snapshot.phase == MTImportWorkflowPhaseCompleted) {
            configuration.title = MTImportLocalized(@"common.done");
            configuration.image = [UIImage systemImageNamed:@"checkmark"];
            self.primaryButton.accessibilityIdentifier = @"marktheme.import.done";
        } else {
            configuration.title = snapshot.phase == MTImportWorkflowPhaseIdle
                ? MTImportLocalized(@"import.action.choose")
                : MTImportLocalized(@"import.action.choose-another");
            configuration.image = [UIImage systemImageNamed:@"plus"];
            self.primaryButton.accessibilityIdentifier = @"marktheme.import.choose-source";
        }
    }
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.imagePadding = 8;
    self.primaryButton.configuration = configuration;
}

- (void)performPrimaryAction:(id)sender {
    (void)sender;
    MTImportWorkflowSnapshot *snapshot = self.snapshot;
    if (MTImportPhaseIsBusy(snapshot.phase)) {
        [self.coordinator cancel];
        return;
    }
    if (snapshot.phase == MTImportWorkflowPhaseReadyForReview ||
        (snapshot.phase == MTImportWorkflowPhaseFailed && snapshot.canRetryCommit)) {
        NSError *error = nil;
        if (![self.coordinator confirmPreparedImport:&error]) {
            [self presentError:error];
        }
        return;
    }
    if (snapshot.phase == MTImportWorkflowPhaseCompleted) {
        [self close:nil];
        return;
    }
    [self beginChoosingThemeSource];
}

- (void)beginChoosingThemeSource {
    [self loadViewIfNeeded];
    MTImportWorkflowPhase phase = self.snapshot.phase;
    if (phase == MTImportWorkflowPhaseCancelled ||
        phase == MTImportWorkflowPhaseCompleted ||
        phase == MTImportWorkflowPhaseFailed) {
        NSError *error = nil;
        if (![self.coordinator reset:&error]) {
            [self presentError:error];
            return;
        }
    }
    if (self.view.window == nil) {
        self.pendingSourcePicker = YES;
        return;
    }
    [self presentInstalledThemeChoiceOrSourcePicker];
}

// Directory import is deliberately exposed only through the installed-theme
// locator. iOS Files cannot reliably select directories on the supported
// devices, so every entry point offers exactly two testable sources: scan the
// installed theme roots, or choose an archive.
- (void)presentInstalledThemeChoiceOrSourcePicker {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:MTImportLocalized(@"import.source.title")
                         message:MTImportLocalized(@"import.source.detail")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTImportLocalized(@"import.source.installed-action")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        [self presentInstalledThemesFromLocator];
    }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTImportLocalized(@"import.source.zip-action")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        [self presentThemeSourcePicker];
    }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTImportLocalized(@"import.source.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    sheet.popoverPresentationController.sourceView = self.primaryButton;
    sheet.popoverPresentationController.sourceRect =
        self.primaryButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentInstalledThemesFromLocator {
    MTInstalledThemeLocator *locator = [[MTInstalledThemeLocator alloc] init];
    NSArray<MTInstalledTheme *> *installed =
        [locator locateInstalledThemes];
    if (installed.count > 0) {
        [self presentInstalledThemeList:installed];
        return;
    }
    NSString *paths = [locator.searchRootPaths
        componentsJoinedByString:@"\n"];
    NSString *format = MTImportLocalized(
        @"import.source.installed-empty-detail");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTImportLocalized(
                                     @"import.source.installed-empty-title")
                         message:[NSString stringWithFormat:format, paths]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTImportLocalized(@"common.ok")
                  style:UIAlertActionStyleDefault
                handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentInstalledThemeList:(NSArray<MTInstalledTheme *> *)installed {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:MTImportLocalized(
                                     @"import.source.installed-title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (MTInstalledTheme *theme in installed) {
        [sheet addAction:[UIAlertAction
            actionWithTitle:theme.displayName
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            [self startImportAtURL:theme.directoryURL directory:YES];
        }]];
    }
    [sheet addAction:[UIAlertAction
        actionWithTitle:MTImportLocalized(@"import.source.cancel")
                  style:UIAlertActionStyleCancel
                handler:nil]];
    sheet.popoverPresentationController.sourceView = self.primaryButton;
    sheet.popoverPresentationController.sourceRect =
        self.primaryButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentThemeSourcePicker {
    // ZIP uses the exact system type so Files can enable it consistently on
    // iOS 18. The App-declared type covers the remaining archive extensions.
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
    MTImportDiagnosticsRecord(@"import-page.archive-picker.present-request", @{
        @"customTypeFound" : @(themeArchive != nil),
        @"customTypeDeclared" : @(themeArchive.isDeclared),
        @"asCopy" : @NO,
        @"presentedController" : self.presentedViewController == nil
            ? @"<none>" : NSStringFromClass(self.presentedViewController.class),
    });
    [self presentViewController:picker animated:YES completion:^{
        MTImportDiagnosticsRecord(@"import-page.archive-picker.presented", nil);
    }];
}

// Whether a picked or shared URL names a directory. The URL is only readable
// inside a security scope, and on a jailbreak where the App's sandbox
// exception is not honoured the probe fails outright; treating that failure as
// a fatal error refused the import before it started. A failed probe means
// "unknown", and an archive is the safe assumption -- the format is settled by
// content sniffing further in.
static BOOL MTImportURLIsDirectory(NSURL *url) {
    if (!url.isFileURL) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSNumber *directoryValue = nil;
    BOOL resolved = [url getResourceValue:&directoryValue
                                   forKey:NSURLIsDirectoryKey
                                    error:NULL];
    if (!resolved) {
        struct stat status = {0};
        if (stat(url.path.fileSystemRepresentation, &status) == 0) {
            directoryValue = @(S_ISDIR(status.st_mode));
        }
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    return directoryValue.boolValue;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    MTImportDiagnosticsRecord(@"import-page.archive-picker.did-pick", @{
        @"urlCount" : @(urls.count),
        @"path" : url.path ?: @"",
        @"isFileURL" : @(url.isFileURL),
    });
    if (urls.count != 1 || !url.isFileURL) {
        [self presentError:nil];
        return;
    }
    [self startImportAtURL:url directory:MTImportURLIsDirectory(url)];
}

- (void)startImportAtURL:(NSURL *)url {
    [self loadViewIfNeeded];
    BOOL directory = MTImportURLIsDirectory(url);
    MTImportDiagnosticsRecord(@"import-page.start-url", @{
        @"path" : url.path ?: @"",
        @"lastPathComponent" : url.lastPathComponent ?: @"",
        @"detectedDirectory" : @(directory),
    });
    [self startImportAtURL:url directory:directory];
}

- (void)startImportAtURL:(NSURL *)url directory:(BOOL)directory {
    if (!url.isFileURL) {
        [self presentError:nil];
        return;
    }
    MTImportWorkflowPhase phase = self.snapshot.phase;
    if (phase == MTImportWorkflowPhaseCancelled ||
        phase == MTImportWorkflowPhaseCompleted ||
        phase == MTImportWorkflowPhaseFailed) {
        NSError *resetError = nil;
        if (![self.coordinator reset:&resetError]) {
            [self presentError:resetError];
            return;
        }
    }
    NSString *sourceName = url.lastPathComponent;
    NSSet<NSString *> *archiveExtensions = [NSSet setWithArray:@[
        @"zip", @"deb", @"tar", @"tgz", @"gz", @"txz", @"xz",
        @"tzst", @"zst", @"zstd", @"tbz", @"tbz2", @"bz2",
    ]];
    while (!directory && [archiveExtensions containsObject:
            sourceName.pathExtension.lowercaseString]) {
        sourceName = sourceName.stringByDeletingPathExtension;
    }
    if (sourceName.length == 0) {
        sourceName = MTImportLocalized(@"import.source.unnamed");
    }
    NSError *error = nil;
    BOOL started = directory
        ? [self.coordinator startDirectoryImportAtURL:url
                                          sourceName:sourceName
                                               error:&error]
        : [self.coordinator startArchiveImportAtURL:url
                                         sourceName:sourceName
                                              error:&error];
    if (!started) [self presentError:error];
}

- (void)documentPickerWasCancelled:
        (UIDocumentPickerViewController *)controller {
    (void)controller;
    MTImportDiagnosticsRecord(@"import-page.archive-picker.cancelled", nil);
}

- (void)presentError:(NSError *)error {
    if (error != nil) {
        NSLog(@"MarkTheme Import failed (%@/%ld): %@; underlying=%@",
              error.domain, (long)error.code, error.localizedDescription,
              error.userInfo[NSUnderlyingErrorKey]);
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:MTImportLocalized(@"import.error.title")
                         message:MTImportFriendlyError(error)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:MTImportLocalized(@"common.ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)close:(id)sender {
    (void)sender;
    if (self.snapshot.canCancel) [self.coordinator cancel];
    if (self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        dispatch_block_t handler = self.dismissalHandler;
        self.dismissalHandler = nil;
        if (handler != nil) handler();
    }];
}

@end
