#import <Foundation/Foundation.h>

@class MTRuntimeProfile;
@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeAdapterRegistryErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimeAdapterRegistryErrorCode) {
    MTRuntimeAdapterRegistryErrorInvalidProfile = 1,
    MTRuntimeAdapterRegistryErrorUnsupportedAdapter = 2,
    MTRuntimeAdapterRegistryErrorUnsupportedModule = 3,
    MTRuntimeAdapterRegistryErrorInstallRejected = 4,
};

// Resolves built-in adapters and their ModuleRuntime resolver from the exact
// generated profile. Resolution completes before the Hook is scheduled,
// preventing partial activation when either ID is unknown.
FOUNDATION_EXPORT BOOL MTRuntimeInstallConfiguredAdapters(
    MTRuntimeProfile *profile,
    MTRuntimeKernel *kernel,
    NSError **error);

NS_ASSUME_NONNULL_END
