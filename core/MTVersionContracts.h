#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeManifestVersionKey;
FOUNDATION_EXPORT NSString *const MTNormalizedModelVersionKey;
FOUNDATION_EXPORT NSString *const MTCompilerVersionKey;
FOUNDATION_EXPORT NSString *const MTRuntimeSnapshotVersionKey;
FOUNDATION_EXPORT NSString *const MTModuleAPIVersionKey;

FOUNDATION_EXPORT NSUInteger const MTThemeManifestVersion;
FOUNDATION_EXPORT NSUInteger const MTNormalizedModelVersion;
FOUNDATION_EXPORT NSUInteger const MTCompilerVersion;
FOUNDATION_EXPORT NSUInteger const MTRuntimeSnapshotVersion;
FOUNDATION_EXPORT NSUInteger const MTModuleAPIVersion;

FOUNDATION_EXPORT NSString *const MTVersionContractsErrorDomain;

FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *
MTCurrentContractVersions(void);

// Validates all contracts known to this build. Unknown extra keys are retained
// for forward diagnostics but cannot replace a missing required contract.
FOUNDATION_EXPORT BOOL
MTContractVersionsAreSupported(NSDictionary<NSString *, id> *versions,
                               NSError **error);

NS_ASSUME_NONNULL_END
