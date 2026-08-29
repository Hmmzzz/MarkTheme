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

typedef void (^MTRuntimeAdapterRefreshCompletion)(BOOL verified);

// Called only after the Kernel has accepted a new canonical snapshot. The
// IconServices service barrier has already completed; this phase reloads
// independent categories and asks each live ordinary-app consumer to run its
// sealed native invalidation path. No display-layer application-icon pixels
// are produced here.
FOUNDATION_EXPORT void MTRuntimeRefreshConfiguredAdapters(
    MTRuntimeProfile *profile,
    MTRuntimeKernel *kernel,
    MTRuntimeSnapshot *snapshot,
    MTRuntimeAdapterRefreshCompletion _Nullable completion);

NS_ASSUME_NONNULL_END
