#import <Foundation/Foundation.h>

@class MTThemeComponentSelection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeMixSelectionErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTThemeMixSelectionSchemaVersion;
FOUNDATION_EXPORT NSUInteger const MTThemeAppIconFallbackMaximumCount;

// Immutable Manager/Compiler contract for one cross-theme configuration. The
// selected theme remains the base. Individual product features may either use
// that base, name another current Library theme, or be disabled so Runtime
// falls back to the native system appearance for that feature.
//
// Revision and component-selection identities are embedded for every referenced
// theme. This makes an applied Generation comparable without asking injected
// Runtime code to understand Library or preference state.
@interface MTThemeMixSelection : NSObject

@property(nonatomic, copy, readonly) NSString *baseThemeIdentifier;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSString *> *sourceThemeIdentifiersByFeature;
// Additional App-icon sources after the feature's primary source. The order is
// significant and contains at most MTThemeAppIconFallbackMaximumCount themes.
// Compiler composition claims a Bundle ID from the first source that provides
// it, so lower-priority themes can only fill uncovered icons.
@property(nonatomic, copy, readonly)
    NSArray<NSString *> *appIconFallbackThemeIdentifiers;
@property(nonatomic, copy, readonly)
    NSArray<NSString *> *appIconThemeIdentifiersInPriorityOrder;
@property(nonatomic, copy, readonly) NSArray<NSString *> *disabledFeatureIdentifiers;
@property(nonatomic, copy, readonly) NSArray<NSString *> *referencedThemeIdentifiers;
// Base plus source themes of enabled features. Disabled features retain their
// last source preference but do not make that source active Runtime content.
@property(nonatomic, copy, readonly) NSArray<NSString *> *effectiveThemeIdentifiers;
// Runtime identity excludes remembered sources for disabled features. This
// keeps an inactive source revision or component change from making an
// otherwise identical Generation appear stale.
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, id> *effectiveCanonicalDictionary;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSString *> *revisionIdentifiersByThemeIdentifier;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        componentSelectionDictionariesByThemeIdentifier;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *canonicalDictionary;

+ (nullable instancetype)selectionWithBaseThemeIdentifier:
    (NSString *)baseThemeIdentifier
    sourceThemeIdentifiersByFeature:
        (NSDictionary<NSString *, NSString *> *)sourceThemeIdentifiersByFeature
    disabledFeatureIdentifiers:(NSArray<NSString *> *)disabledFeatureIdentifiers
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSString *> *)revisionIdentifiersByThemeIdentifier
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    error:(NSError **)error;

// Extended constructor used when App icons have ordered secondary/tertiary
// sources. The legacy constructor above remains source-compatible and creates
// an empty fallback list.
+ (nullable instancetype)selectionWithBaseThemeIdentifier:
    (NSString *)baseThemeIdentifier
    sourceThemeIdentifiersByFeature:
        (NSDictionary<NSString *, NSString *> *)sourceThemeIdentifiersByFeature
    appIconFallbackThemeIdentifiers:
        (NSArray<NSString *> *)appIconFallbackThemeIdentifiers
    disabledFeatureIdentifiers:(NSArray<NSString *> *)disabledFeatureIdentifiers
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSString *> *)revisionIdentifiersByThemeIdentifier
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    error:(NSError **)error;

+ (nullable instancetype)selectionWithCanonicalDictionary:
    (NSDictionary<NSString *, id> *)canonicalDictionary
                                                  error:(NSError **)error;

- (BOOL)isFeatureEnabled:(NSString *)featureIdentifier;
- (NSString *)sourceThemeIdentifierForFeatureIdentifier:
    (NSString *)featureIdentifier;
- (BOOL)isRuntimeEquivalentToSelection:
    (nullable MTThemeMixSelection *)selection;

- (nullable instancetype)selectionBySettingFeatureIdentifier:
    (NSString *)featureIdentifier
                                                       enabled:(BOOL)enabled
                                                         error:(NSError **)error;

// The full current Library identity maps are supplied because choosing a new
// source can introduce a theme that was not referenced by the old value.
- (nullable instancetype)selectionBySettingSourceThemeIdentifier:
    (NSString *)sourceThemeIdentifier
                                             forFeatureIdentifier:
                                                 (NSString *)featureIdentifier
                             revisionIdentifiersByThemeIdentifier:
                                 (NSDictionary<NSString *, NSString *> *)
                                     revisionIdentifiersByThemeIdentifier
                           componentSelectionsByThemeIdentifier:
                               (NSDictionary<NSString *, MTThemeComponentSelection *> *)
                                   componentSelectionsByThemeIdentifier
                                                           error:(NSError **)error;

// index is zero-based within the fallback list (0 = second icon theme,
// 1 = third). Supplying nil removes that slot and compacts later priorities.
// A non-nil theme may replace an existing slot or append at the current count.
- (nullable instancetype)selectionBySettingAppIconFallbackThemeIdentifier:
    (nullable NSString *)themeIdentifier
                                                               atIndex:
                                                                   (NSUInteger)index
                                    revisionIdentifiersByThemeIdentifier:
                                        (NSDictionary<NSString *, NSString *> *)
                                            revisionIdentifiersByThemeIdentifier
                                  componentSelectionsByThemeIdentifier:
                                      (NSDictionary<NSString *, MTThemeComponentSelection *> *)
                                          componentSelectionsByThemeIdentifier
                                                                  error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
