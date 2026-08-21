#import <Foundation/Foundation.h>

@class MTThemeManifest;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeFeatureAppIcons;
FOUNDATION_EXPORT NSString *const MTThemeFeatureSettingsIcons;
FOUNDATION_EXPORT NSString *const MTThemeFeatureShareIcons;
FOUNDATION_EXPORT NSString *const MTThemeFeatureFolders;
FOUNDATION_EXPORT NSString *const MTThemeFeatureDynamicClock;
FOUNDATION_EXPORT NSString *const MTThemeFeatureDynamicCalendar;
FOUNDATION_EXPORT NSString *const MTThemeFeatureIconMask;
FOUNDATION_EXPORT NSString *const MTThemeFeatureIconPattern;
FOUNDATION_EXPORT NSString *const MTThemeFeatureBadges;
FOUNDATION_EXPORT NSString *const MTThemeFeatureStatusBar;
FOUNDATION_EXPORT NSString *const MTThemeFeatureIconShadows;
FOUNDATION_EXPORT NSString *const MTThemeFeatureDialer;

typedef NS_ENUM(NSUInteger, MTThemeCapabilityAvailability) {
    // MarkTheme64e supports this feature, but the current Manifest has no input.
    MTThemeCapabilityAvailabilityAbsent = 0,

    // The current Manifest contains a complete feature that Runtime can use.
    MTThemeCapabilityAvailabilityReady = 1,

    // Import/Library/Compiler data is present, while the product Runtime
    // adapter is not enabled yet.
    MTThemeCapabilityAvailabilityImportedOnly = 2,

    // The feature is part of the public module roadmap but has no importer or
    // Runtime contract in this build, so absence cannot be attributed to the
    // theme itself.
    MTThemeCapabilityAvailabilityPlanned = 3,
};

// Presentation is data-driven so App screens do not need their own list of
// feature IDs. Most future modules can reuse one of these count styles.
typedef NS_ENUM(NSUInteger, MTThemeCapabilityMetricPresentation) {
    MTThemeCapabilityMetricPresentationResourceCount = 0,
    MTThemeCapabilityMetricPresentationIconCount = 1,
    MTThemeCapabilityMetricPresentationComponentProgress = 2,
    MTThemeCapabilityMetricPresentationStyleCount = 3,
    MTThemeCapabilityMetricPresentationSubjectCount = 4,
    MTThemeCapabilityMetricPresentationCalendarLayout = 5,
};

// Orthogonal to style variants. A single style can provide one shared image,
// explicit appearance images, or both (shared remains Runtime fallback).
typedef NS_OPTIONS(NSUInteger, MTThemeCapabilityAppearanceCoverage) {
    MTThemeCapabilityAppearanceCoverageNone = 0,
    MTThemeCapabilityAppearanceCoverageShared = 1 << 0,
    MTThemeCapabilityAppearanceCoverageLight = 1 << 1,
    MTThemeCapabilityAppearanceCoverageDark = 1 << 2,
};

@interface MTThemeCapabilityItem : NSObject

@property(nonatomic, copy, readonly) NSString *featureID;
@property(nonatomic, copy, readonly, nullable) NSString *moduleID;
@property(nonatomic, copy, readonly) NSString *titleLocalizationKey;
@property(nonatomic, copy, readonly) NSString *symbolName;
@property(nonatomic, assign, readonly)
    MTThemeCapabilityMetricPresentation metricPresentation;
@property(nonatomic, assign, readonly)
    MTThemeCapabilityAvailability availability;
@property(nonatomic, assign, readonly) NSUInteger resourceCount;
@property(nonatomic, assign, readonly) NSUInteger uniqueSubjectCount;
@property(nonatomic, assign, readonly) NSUInteger expectedComponentCount;
@property(nonatomic, copy, readonly) NSArray<NSString *> *presentVariants;
@property(nonatomic, copy, readonly) NSArray<NSString *> *presentTraits;
@property(nonatomic, assign, readonly)
    MTThemeCapabilityAppearanceCoverage appearanceCoverage;
// Recognition and Runtime applicability are intentionally separate. A theme
// may contain valid data for a module before its process adapter is enabled.
@property(nonatomic, assign, readonly, getter=hasRecognizedContent)
    BOOL recognizedContent;
@property(nonatomic, assign, readonly, getter=isRuntimeApplicable)
    BOOL runtimeApplicable;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// A deterministic, read-only product projection of one canonical Manifest.
// UI code renders these stable feature IDs and does not reimplement module or
// resource counting rules. New modules extend this report in one place.
@interface MTThemeCapabilityReport : NSObject

@property(nonatomic, copy, readonly) NSArray<MTThemeCapabilityItem *> *items;
@property(nonatomic, assign, readonly) NSUInteger runtimeApplicableFeatureCount;
@property(nonatomic, assign, readonly) NSUInteger recognizedFeatureCount;

+ (instancetype)reportForManifest:(MTThemeManifest *)manifest;
- (nullable MTThemeCapabilityItem *)itemForFeatureID:(NSString *)featureID;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
