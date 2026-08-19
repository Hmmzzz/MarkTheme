#import <Foundation/Foundation.h>

@class MTRuntimeProfile;
@class MTRuntimeKernel;
@class MTRuntimeSnapshot;

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

// Called only after the Kernel has accepted a new canonical snapshot. Ready
// generations are prewarmed in bounded batches before their exact icon pairs
// are purged; disabled snapshots purge directly back to stock.
FOUNDATION_EXPORT void MTRuntimeRefreshConfiguredAdapters(
    MTRuntimeProfile *profile,
    MTRuntimeKernel *kernel,
    MTRuntimeSnapshot *snapshot);

NS_ASSUME_NONNULL_END
