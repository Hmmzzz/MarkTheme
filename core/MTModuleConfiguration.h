#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTModuleConfigurationErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTModuleConfigurationMaximumCount;
FOUNDATION_EXPORT NSUInteger const MTModuleConfigurationMaximumByteCount;

// Returns a deeply immutable, canonical-JSON-safe copy. Configuration keys are
// stable module identifiers and must be declared by the owning manifest or
// generation descriptor.
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
    _Nullable MTNormalizeModuleConfigurations(
        NSDictionary<NSString *, NSDictionary<NSString *, id> *> *configurations,
        NSArray<NSString *> *declaredModuleIDs,
        NSError **error);

NS_ASSUME_NONNULL_END
