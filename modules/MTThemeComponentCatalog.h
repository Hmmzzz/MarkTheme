#import <Foundation/Foundation.h>

@class MTThemeManifest;
@class MTThemeResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeComponentCatalogErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTThemeComponentSelectionSchemaVersion;

// One physical SnowBoard component whose non-variant resources may be enabled
// or disabled together. The primary component is always required.
@interface MTThemeComponentDescriptor : NSObject

@property(nonatomic, copy, readonly) NSString *componentIdentifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSArray<NSString *> *moduleIDs;
@property(nonatomic, assign, readonly) NSUInteger resourceCount;
@property(nonatomic, assign, readonly, getter=isRequired) BOOL required;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// One authored style on a semantic variant axis. Appearance remains a
// separate resource trait and is never inferred from this display name.
@interface MTThemeVariantOption : NSObject

@property(nonatomic, copy, readonly) NSString *variantIdentifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *componentIdentifier;
@property(nonatomic, assign, readonly) NSUInteger resourceCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeVariantGroup : NSObject

// The group identifier is the owning module identifier.
@property(nonatomic, copy, readonly) NSString *groupIdentifier;
@property(nonatomic, copy, readonly) NSArray<MTThemeVariantOption *> *options;
@property(nonatomic, copy, readonly) NSString *defaultVariantIdentifier;

- (nullable MTThemeVariantOption *)optionWithIdentifier:
    (NSString *)variantIdentifier;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@class MTThemeComponentSelection;

// Deterministic projection of one immutable Manifest. It does not mutate the
// Library and can be rebuilt cheaply from catalog metadata.
@interface MTThemeComponentCatalog : NSObject

@property(nonatomic, copy, readonly) NSString *themeIdentifier;
@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, copy, readonly)
    NSArray<MTThemeComponentDescriptor *> *components;
@property(nonatomic, copy, readonly)
    NSArray<MTThemeVariantGroup *> *variantGroups;
@property(nonatomic, strong, readonly)
    MTThemeComponentSelection *defaultSelection;

+ (nullable instancetype)catalogForManifest:(MTThemeManifest *)manifest
                                       error:(NSError **)error;
- (nullable MTThemeComponentDescriptor *)componentWithIdentifier:
    (NSString *)componentIdentifier;
- (nullable MTThemeVariantGroup *)variantGroupWithIdentifier:
    (NSString *)groupIdentifier;
- (nullable MTThemeVariantGroup *)variantGroupForModuleIdentifier:
    (NSString *)moduleIdentifier;
- (nullable NSString *)componentIdentifierForResource:
    (MTThemeResource *)resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Immutable value state owned by Manager. It is compiled into the Generation
// but never read by injected Runtime code.
@interface MTThemeComponentSelection : NSObject

@property(nonatomic, copy, readonly) NSString *manifestDigest;
@property(nonatomic, copy, readonly) NSArray<NSString *> *enabledComponentIDs;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSString *> *selectedVariantsByGroup;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, id> *canonicalDictionary;

+ (nullable instancetype)selectionForCatalog:
    (MTThemeComponentCatalog *)catalog
                         canonicalDictionary:
                             (NSDictionary<NSString *, id> *)dictionary
                                       error:(NSError **)error;

// Preserves any still-valid user choices and fills missing/invalid fields from
// the current deterministic defaults. Intended only for preference loading.
+ (instancetype)selectionByNormalizingDictionary:
    (nullable NSDictionary<NSString *, id> *)dictionary
                                     catalog:
                                         (MTThemeComponentCatalog *)catalog;

- (BOOL)isComponentEnabled:(NSString *)componentIdentifier;
- (nullable NSString *)selectedVariantForGroup:
    (NSString *)groupIdentifier;
- (nullable instancetype)selectionBySettingComponentIdentifier:
    (NSString *)componentIdentifier
                                                    enabled:(BOOL)enabled
                                                    catalog:
                                                        (MTThemeComponentCatalog *)catalog
                                                      error:(NSError **)error;
- (nullable instancetype)selectionBySelectingVariantIdentifier:
    (NSString *)variantIdentifier
                                               forGroupIdentifier:
                                                   (NSString *)groupIdentifier
                                                            catalog:
                                                                (MTThemeComponentCatalog *)catalog
                                                              error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
