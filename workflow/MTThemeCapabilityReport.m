#import "MTThemeCapabilityReport.h"

#import "MTBadgesModule.h"
#import "MTCalendarIconsModule.h"
#import "MTClockIconsModule.h"
#import "MTDialerModule.h"
#import "MTFolderIconContract.h"
#import "MTIconMaskContract.h"
#import "MTIconShadowsModule.h"
#import "MTResourceKey.h"
#import "MTStatusBarModule.h"
#import "MTThemeManifest.h"
#import "MTUIResourcesModule.h"

NSString *const MTThemeFeatureAppIcons = @"app-icons";
NSString *const MTThemeFeatureSettingsIcons = @"settings-icons";
NSString *const MTThemeFeatureShareIcons = @"share-icons";
NSString *const MTThemeFeatureFolders = @"folders";
NSString *const MTThemeFeatureDynamicClock = @"dynamic-clock";
NSString *const MTThemeFeatureDynamicCalendar = @"dynamic-calendar";
NSString *const MTThemeFeatureIconMask = @"icon-mask";
NSString *const MTThemeFeatureIconPattern = @"icon-pattern";
NSString *const MTThemeFeatureBadges = @"badges";
NSString *const MTThemeFeatureStatusBar = @"status-bar";
NSString *const MTThemeFeatureIconShadows = @"icon-shadows";
NSString *const MTThemeFeatureDialer = @"dialer";

@interface MTThemeCapabilityItem ()
@property(nonatomic, copy, readwrite) NSString *featureID;
@property(nonatomic, copy, readwrite, nullable) NSString *moduleID;
@property(nonatomic, copy, readwrite) NSString *titleLocalizationKey;
@property(nonatomic, copy, readwrite) NSString *symbolName;
@property(nonatomic, assign, readwrite)
    MTThemeCapabilityMetricPresentation metricPresentation;
@property(nonatomic, assign, readwrite)
    MTThemeCapabilityAvailability availability;
@property(nonatomic, assign, readwrite) NSUInteger resourceCount;
@property(nonatomic, assign, readwrite) NSUInteger uniqueSubjectCount;
@property(nonatomic, assign, readwrite) NSUInteger expectedComponentCount;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *presentVariants;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *presentTraits;
@property(nonatomic, assign, readwrite)
    MTThemeCapabilityAppearanceCoverage appearanceCoverage;
- (instancetype)initWithFeatureID:(NSString *)featureID
                          moduleID:(nullable NSString *)moduleID
              titleLocalizationKey:(NSString *)titleLocalizationKey
                        symbolName:(NSString *)symbolName
                metricPresentation:
                    (MTThemeCapabilityMetricPresentation)metricPresentation
                      availability:
                          (MTThemeCapabilityAvailability)availability
                     resourceCount:(NSUInteger)resourceCount
                uniqueSubjectCount:(NSUInteger)uniqueSubjectCount
            expectedComponentCount:(NSUInteger)expectedComponentCount
                   presentVariants:(NSArray<NSString *> *)presentVariants
                     presentTraits:(NSArray<NSString *> *)presentTraits
                appearanceCoverage:
                    (MTThemeCapabilityAppearanceCoverage)appearanceCoverage;
@end

@implementation MTThemeCapabilityItem

- (instancetype)initWithFeatureID:(NSString *)featureID
                          moduleID:(NSString *)moduleID
              titleLocalizationKey:(NSString *)titleLocalizationKey
                        symbolName:(NSString *)symbolName
                metricPresentation:
                    (MTThemeCapabilityMetricPresentation)metricPresentation
                      availability:
                          (MTThemeCapabilityAvailability)availability
                     resourceCount:(NSUInteger)resourceCount
                uniqueSubjectCount:(NSUInteger)uniqueSubjectCount
            expectedComponentCount:(NSUInteger)expectedComponentCount
                   presentVariants:(NSArray<NSString *> *)presentVariants
                     presentTraits:(NSArray<NSString *> *)presentTraits
                appearanceCoverage:
                    (MTThemeCapabilityAppearanceCoverage)appearanceCoverage {
    self = [super init];
    if (self == nil) return nil;
    _featureID = [featureID copy];
    _moduleID = [moduleID copy];
    _titleLocalizationKey = [titleLocalizationKey copy];
    _symbolName = [symbolName copy];
    _metricPresentation = metricPresentation;
    _availability = availability;
    _resourceCount = resourceCount;
    _uniqueSubjectCount = uniqueSubjectCount;
    _expectedComponentCount = expectedComponentCount;
    _presentVariants = [presentVariants copy];
    _presentTraits = [presentTraits copy];
    _appearanceCoverage = appearanceCoverage;
    return self;
}

- (BOOL)hasRecognizedContent {
    return self.availability == MTThemeCapabilityAvailabilityReady ||
        self.availability == MTThemeCapabilityAvailabilityImportedOnly;
}

- (BOOL)isRuntimeApplicable {
    return self.availability == MTThemeCapabilityAvailabilityReady;
}

@end

@interface MTThemeCapabilityAccumulator : NSObject
@property(nonatomic, assign) NSUInteger resourceCount;
@property(nonatomic, strong) NSMutableSet<NSString *> *subjects;
@property(nonatomic, strong) NSMutableSet<NSString *> *variants;
@property(nonatomic, strong) NSMutableSet<NSString *> *traits;
@end

@implementation MTThemeCapabilityAccumulator
- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _subjects = [NSMutableSet set];
    _variants = [NSMutableSet set];
    _traits = [NSMutableSet set];
    return self;
}
@end

@interface MTThemeCapabilityReport ()
@property(nonatomic, copy, readwrite) NSArray<MTThemeCapabilityItem *> *items;
@property(nonatomic, assign, readwrite)
    NSUInteger runtimeApplicableFeatureCount;
@property(nonatomic, assign, readwrite) NSUInteger recognizedFeatureCount;
- (instancetype)initWithItems:(NSArray<MTThemeCapabilityItem *> *)items;
@end

static MTThemeCapabilityAccumulator *MTThemeCapabilityAccumulate(
    MTThemeManifest *manifest,
    NSString *moduleID,
    NSString *_Nullable surface,
    NSString *_Nullable variant) {
    MTThemeCapabilityAccumulator *result =
        [[MTThemeCapabilityAccumulator alloc] init];
    for (MTThemeResource *resource in manifest.resources) {
        MTResourceKey *key = resource.resourceKey;
        if (![key.moduleID isEqualToString:moduleID] ||
            (surface != nil && ![key.surface isEqualToString:surface]) ||
            (variant != nil && ![key.variant isEqualToString:variant])) {
            continue;
        }
        result.resourceCount += 1;
        [result.subjects addObject:key.subject];
        [result.variants addObject:key.variant];
        [result.traits addObject:key.trait];
    }
    return result;
}

static MTThemeCapabilityItem *MTThemeCapabilityItemFromAccumulator(
    NSString *featureID,
    NSString *moduleID,
    NSString *titleLocalizationKey,
    NSString *symbolName,
    MTThemeCapabilityMetricPresentation metricPresentation,
    MTThemeCapabilityAccumulator *accumulator,
    BOOL declared,
    MTThemeCapabilityAvailability presentAvailability,
    NSUInteger expectedComponentCount,
    BOOL appearanceAware) {
    BOOL present = declared || accumulator.resourceCount > 0;
    MTThemeCapabilityAppearanceCoverage appearanceCoverage =
        MTThemeCapabilityAppearanceCoverageNone;
    if (appearanceAware) {
        for (NSString *trait in accumulator.traits) {
            if ([trait isEqualToString:MTBadgeAppearanceLight] ||
                [trait hasSuffix:@"-light"]) {
                appearanceCoverage |=
                    MTThemeCapabilityAppearanceCoverageLight;
            } else if ([trait isEqualToString:MTBadgeAppearanceDark] ||
                       [trait hasSuffix:@"-dark"]) {
                appearanceCoverage |=
                    MTThemeCapabilityAppearanceCoverageDark;
            } else {
                appearanceCoverage |=
                    MTThemeCapabilityAppearanceCoverageShared;
            }
        }
    }
    return [[MTThemeCapabilityItem alloc]
        initWithFeatureID:featureID
        moduleID:moduleID
        titleLocalizationKey:titleLocalizationKey
        symbolName:symbolName
        metricPresentation:metricPresentation
        availability:present
            ? presentAvailability : MTThemeCapabilityAvailabilityAbsent
        resourceCount:accumulator.resourceCount
        uniqueSubjectCount:accumulator.subjects.count
        expectedComponentCount:expectedComponentCount
        presentVariants:[[accumulator.variants allObjects]
            sortedArrayUsingSelector:@selector(compare:)]
        presentTraits:[[accumulator.traits allObjects]
            sortedArrayUsingSelector:@selector(compare:)]
        appearanceCoverage:appearanceCoverage];
}

@implementation MTThemeCapabilityReport

+ (instancetype)reportForManifest:(MTThemeManifest *)manifest {
    NSParameterAssert(manifest != nil);
    NSSet<NSString *> *declared = [NSSet setWithArray:manifest.capabilities];

    MTThemeCapabilityAccumulator *appIcons =
        MTThemeCapabilityAccumulate(manifest, @"icons.static", nil, nil);
    MTThemeCapabilityAccumulator *settings =
        MTThemeCapabilityAccumulate(manifest, MTUIResourcesModuleID,
                                    @"preferences.icon", nil);
    MTThemeCapabilityAccumulator *share =
        MTThemeCapabilityAccumulate(manifest, MTUIResourcesModuleID,
                                    @"share.activity", nil);
    MTThemeCapabilityAccumulator *folders =
        MTThemeCapabilityAccumulate(manifest, MTFolderIconsModuleID, nil, nil);
    MTThemeCapabilityAccumulator *clock =
        MTThemeCapabilityAccumulate(manifest, MTClockIconsModuleID, nil, nil);
    MTThemeCapabilityAccumulator *mask =
        MTThemeCapabilityAccumulate(manifest, MTIconMaskModuleID,
                                    MTIconMaskSurface,
                                    MTIconMaskVariantMask);
    MTThemeCapabilityAccumulator *pattern =
        MTThemeCapabilityAccumulate(manifest, MTIconMaskModuleID,
                                    MTIconMaskSurface,
                                    MTIconMaskVariantPattern);
    BOOL maskDeclared =
        [declared containsObject:MTIconMaskModuleID] &&
        manifest.moduleConfigurations[MTIconMaskModuleID] != nil;
    if (maskDeclared && mask.resourceCount == 0) {
        [mask.subjects addObject:MTIconMaskGlobalSubject];
        [mask.variants addObject:MTIconMaskVariantSystem];
        [mask.traits addObject:@"any"];
    }
    MTThemeCapabilityAccumulator *badges =
        MTThemeCapabilityAccumulate(manifest, MTBadgesModuleID, nil, nil);
    MTThemeCapabilityAccumulator *statusBar =
        MTThemeCapabilityAccumulate(manifest, MTStatusBarModuleID, nil, nil);
    MTThemeCapabilityAccumulator *iconShadows =
        MTThemeCapabilityAccumulate(manifest, MTIconShadowsModuleID, nil, nil);
    MTThemeCapabilityAccumulator *dialer =
        MTThemeCapabilityAccumulate(manifest, MTDialerModuleID, nil, nil);

    BOOL calendarDeclared =
        [declared containsObject:MTCalendarIconsModuleID] &&
        manifest.moduleConfigurations[MTCalendarIconsModuleID] != nil;
    MTThemeCapabilityItem *calendar = [[MTThemeCapabilityItem alloc]
        initWithFeatureID:MTThemeFeatureDynamicCalendar
        moduleID:MTCalendarIconsModuleID
        titleLocalizationKey:@"theme.capability.dynamic-calendar.title"
        symbolName:@"calendar"
        metricPresentation:MTThemeCapabilityMetricPresentationCalendarLayout
        availability:calendarDeclared
            ? MTThemeCapabilityAvailabilityReady
            : MTThemeCapabilityAvailabilityAbsent
        resourceCount:calendarDeclared ? 1 : 0
        uniqueSubjectCount:calendarDeclared ? 1 : 0
        expectedComponentCount:1
        presentVariants:calendarDeclared ? @[@"day-date-layout"] : @[]
        presentTraits:calendarDeclared ? @[@"any"] : @[]
        appearanceCoverage:MTThemeCapabilityAppearanceCoverageNone];

    NSArray<MTThemeCapabilityItem *> *items = @[
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureAppIcons, @"icons.static",
            @"theme.capability.app-icons.title", @"square.grid.2x2.fill",
            MTThemeCapabilityMetricPresentationIconCount, appIcons,
            [declared containsObject:@"icons.static"],
            MTThemeCapabilityAvailabilityReady, 0, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureSettingsIcons, MTUIResourcesModuleID,
            @"theme.capability.settings-icons.title", @"gearshape.2.fill",
            MTThemeCapabilityMetricPresentationIconCount, settings,
            settings.resourceCount > 0,
            MTThemeCapabilityAvailabilityReady, 0, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureShareIcons, MTUIResourcesModuleID,
            @"theme.capability.share-icons.title", @"square.and.arrow.up.fill",
            MTThemeCapabilityMetricPresentationIconCount, share,
            share.resourceCount > 0,
            MTThemeCapabilityAvailabilityReady, 0, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureFolders, MTFolderIconsModuleID,
            @"theme.capability.folders.title", @"folder.fill",
            MTThemeCapabilityMetricPresentationComponentProgress, folders,
            [declared containsObject:MTFolderIconsModuleID],
            MTThemeCapabilityAvailabilityReady,
            MTFolderIconResourceVariants().count, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureDynamicClock, MTClockIconsModuleID,
            @"theme.capability.dynamic-clock.title", @"clock.fill",
            MTThemeCapabilityMetricPresentationComponentProgress, clock,
            [declared containsObject:MTClockIconsModuleID],
            MTThemeCapabilityAvailabilityReady,
            MTClockIconResourceVariants().count, NO),
        calendar,
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureIconMask, MTIconMaskModuleID,
            @"theme.capability.icon-mask.title", @"square.dashed.inset.filled",
            MTThemeCapabilityMetricPresentationComponentProgress, mask,
            maskDeclared, MTThemeCapabilityAvailabilityReady, 1,
            NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureIconPattern, MTIconMaskModuleID,
            @"theme.capability.icon-pattern.title", @"circle.grid.cross.fill",
            MTThemeCapabilityMetricPresentationComponentProgress, pattern,
            pattern.resourceCount > 0,
            MTThemeCapabilityAvailabilityImportedOnly, 1, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureBadges, MTBadgesModuleID,
            @"theme.capability.badges.title", @"app.badge.fill",
            MTThemeCapabilityMetricPresentationStyleCount, badges,
            [declared containsObject:MTBadgesModuleID],
            MTThemeCapabilityAvailabilityReady, 0, YES),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureStatusBar, MTStatusBarModuleID,
            @"theme.capability.status-bar.title", @"wifi",
            MTThemeCapabilityMetricPresentationSubjectCount, statusBar,
            [declared containsObject:MTStatusBarModuleID],
            MTThemeCapabilityAvailabilityReady, 0, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureIconShadows, MTIconShadowsModuleID,
            @"theme.capability.icon-shadows.title", @"square.stack.3d.up.fill",
            MTThemeCapabilityMetricPresentationStyleCount, iconShadows,
            [declared containsObject:MTIconShadowsModuleID],
            MTThemeCapabilityAvailabilityReady, 0, NO),
        MTThemeCapabilityItemFromAccumulator(
            MTThemeFeatureDialer, MTDialerModuleID,
            @"theme.capability.dialer.title", @"phone.fill",
            MTThemeCapabilityMetricPresentationSubjectCount, dialer,
            [declared containsObject:MTDialerModuleID],
            MTThemeCapabilityAvailabilityReady, 0, NO),
    ];
    return [[self alloc] initWithItems:items];
}

- (instancetype)initWithItems:(NSArray<MTThemeCapabilityItem *> *)items {
    self = [super init];
    if (self == nil) return nil;
    _items = [items copy];
    for (MTThemeCapabilityItem *item in items) {
        if (item.hasRecognizedContent) _recognizedFeatureCount += 1;
        if (item.isRuntimeApplicable) _runtimeApplicableFeatureCount += 1;
    }
    return self;
}

- (MTThemeCapabilityItem *)itemForFeatureID:(NSString *)featureID {
    for (MTThemeCapabilityItem *item in self.items) {
        if ([item.featureID isEqualToString:featureID]) return item;
    }
    return nil;
}

@end
