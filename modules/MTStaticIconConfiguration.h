#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSUInteger const
    MTStaticIconMaximumFuzzyBundleIdentifierCount;
FOUNDATION_EXPORT NSUInteger const MTStaticIconMaximumBundleAliasCount;

// Source-family variants preserve SnowBoard/IconBundles filename precedence
// through the immutable Generation boundary. "primary" remains supported for
// already-imported libraries and older published Generations.
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantPrimary;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantLarge;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantDeviceScale;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantScaleDevice;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantScale;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantDevice;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantPlain;
FOUNDATION_EXPORT NSString *const MTStaticIconSourceVariantBundleIcon;

FOUNDATION_EXPORT NSArray<NSString *> *MTStaticIconSourceVariants(void);
FOUNDATION_EXPORT BOOL MTStaticIconSourceVariantIsSupported(
    NSString *variant);

FOUNDATION_EXPORT BOOL MTStaticIconBundleIdentifierIsValid(
    NSString *_Nullable bundleIdentifier);

// Typed configuration shared by import, compiler and Runtime. Fuzzy matching
// is opt-in per themed identifier and is attempted only after an exact miss.
@interface MTStaticIconConfiguration : NSObject

@property(nonatomic, copy, readonly)
    NSArray<NSString *> *fuzzyBundleIdentifiers;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSString *> *bundleAliases;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, id> *canonicalDictionary;

+ (nullable instancetype)configurationWithFuzzyBundleIdentifiers:
    (NSArray<NSString *> *)fuzzyBundleIdentifiers
                                            bundleAliases:
    (NSDictionary<NSString *, NSString *> *)bundleAliases;

- (nullable instancetype)initWithDictionary:
    (NSDictionary<NSString *, id> *)dictionary
                                      error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

// Returns a configured themed subject for an alternate/resigned identifier.
// Exact index lookup remains the caller's first operation.
- (nullable NSString *)themedBundleIdentifierForRequestedIdentifier:
    (NSString *)requestedIdentifier;

// Returns every configured fallback in deterministic lookup order: an
// explicit alias first, followed by case-insensitive equality and then
// longest dot-boundary fuzzy matches. Callers may continue after a configured
// subject is absent from a particular Generation.
- (NSArray<NSString *> *)
    themedBundleIdentifierCandidatesForRequestedIdentifier:
        (NSString *)requestedIdentifier;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
