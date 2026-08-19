#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTPackageScheme) {
    MTPackageSchemeHost = 0,
    MTPackageSchemeRootless = 1,
    MTPackageSchemeRootHide = 2,
};

FOUNDATION_EXPORT NSString *const MTRuntimeStoreLogicalPath;
FOUNDATION_EXPORT NSString *const MTGenerationStoreLogicalPath;
FOUNDATION_EXPORT NSString *const MTRuntimeStateLogicalPath;
FOUNDATION_EXPORT NSString *const MTGenerationInboxLogicalPath;
FOUNDATION_EXPORT NSString *const MTRuntimeHelperLogicalPath;
FOUNDATION_EXPORT NSString *const MTDiagnosticsLogicalPath;
FOUNDATION_EXPORT NSString *const MTDesktopReloadExecutableLogicalPath;
FOUNDATION_EXPORT NSString *const MTBootstrapPathsErrorDomain;

FOUNDATION_EXPORT NSString *MTPackageSchemeName(MTPackageScheme scheme);
FOUNDATION_EXPORT NSURL * _Nullable MTDefaultRuntimeStoreURL(NSError **error);
FOUNDATION_EXPORT NSURL * _Nullable MTDefaultGenerationInboxURL(NSError **error);
FOUNDATION_EXPORT NSURL * _Nullable MTDefaultRuntimeHelperURL(NSError **error);

@interface MTBootstrapPathResolver : NSObject

@property(nonatomic, assign, readonly) MTPackageScheme scheme;

+ (instancetype)currentResolver;

// Test-only semantic resolver. `physicalPrefix` is synthetic and never read
// from the host environment or persisted as a production jbroot.
+ (instancetype)resolverForTestingScheme:(MTPackageScheme)scheme
                           physicalPrefix:(NSString *)physicalPrefix;

- (nullable NSString *)resolvedPathForLogicalPath:(NSString *)logicalPath
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
