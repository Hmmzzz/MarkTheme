#import <Foundation/Foundation.h>

#import <os/log.h>

#import "MTIconServiceGenerationAdapter.h"
#import "MTIconServiceImageResolver.h"
#import "MTIconServiceProvenCanary.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTIconServiceStoreInvalidator.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshotLoader.h"

#if !defined(MARKTHEME_ICON_SERVICE_STORE_CONTROL)
#define MARKTHEME_ICON_SERVICE_STORE_CONTROL 1
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_STORE_CONTROL == 0 ||
               MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1,
    "MARKTHEME_ICON_SERVICE_STORE_CONTROL must be disabled or enabled");

static MTRuntimeKernel *MTIconServiceKernel;
static MTIconServiceImageResolver *MTIconServiceResolver;
static MTIconServiceStoreInvalidator *MTIconServiceInvalidator;

static os_log_t MTIconServiceLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create(
            "com.hmmzzz.marktheme", "icon-service-runtime");
    });
    return log;
}

static void MTIconServiceLogError(NSString *stage, NSError *error) {
    os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_ERROR,
        "icon service %{public}@ failed: %{public}@/%{public}ld",
        stage, error.domain ?: @"unknown", (long)error.code);
}

__attribute__((constructor))
static void MTIconServiceBootstrap(void) {
    @autoreleasepool {
        MTIconServiceRuntimeMode mode =
            MTIconServiceConfiguredRuntimeMode();
        // The release-development default performs no class lookup, framework
        // call, store read, listener registration, or Hook installation.
        if (mode == MTIconServiceRuntimeModeDisabled) return;

        NSError *error = nil;
        if (mode == MTIconServiceRuntimeModeSource) {
            MTRuntimeSnapshotLoader *loader =
                [MTRuntimeSnapshotLoader defaultLoaderWithError:&error];
            if (loader == nil) {
                MTIconServiceLogError(@"snapshot-loader", error);
                return;
            }
            __block __weak MTIconServiceImageResolver *weakResolver = nil;
            MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
                initWithLoader:loader
                notificationName:MTRuntimeInvalidationNotificationName
                reloadHandler:^(MTRuntimeReloadDisposition disposition,
                                __unused MTRuntimeSnapshot *snapshot,
                                NSError *reloadError) {
                    if (disposition ==
                        MTRuntimeReloadDispositionRetainedAfterFailure) {
                        MTIconServiceLogError(@"snapshot-reload", reloadError);
                        return;
                    }
                    [weakResolver reset];
                    if (MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1 &&
                        MTIconServiceProvenCanaryIsEnabled()) {
                        MTIconServiceStoreInvalidator *storeInvalidator =
                            MTIconServiceInvalidator;
                        [storeInvalidator
                            invalidateObservedMappingsForBundleIdentifier:
                                MTIconServiceProvenCanaryBundleIdentifier()
                            iconDigest:MTIconServiceProvenCanaryIconDigest()
                            descriptorDigest:
                                MTIconServiceProvenCanaryDescriptorDigest()
                            completion:
                                ^(MTIconServiceStoreInvalidationResult *result) {
                                    os_log_with_type(
                                        MTIconServiceLog(),
                                        result.isVerified
                                            ? OS_LOG_TYPE_DEFAULT
                                            : OS_LOG_TYPE_ERROR,
                                        "canary cache transaction "
                                        "outcome=%{public}@ removed=%{public}lu "
                                        "fallback=%{public}d",
                                        result.outcome,
                                        (unsigned long)
                                            result.removedValueCount,
                                        result.requiresBroadFallback);
                                }];
                    }
                }];
            MTIconServiceImageResolver *resolver =
                [[MTIconServiceImageResolver alloc]
                    initWithSnapshotProvider:^MTRuntimeSnapshot *{
                        return kernel.currentSnapshot;
                    }];
            if (kernel == nil || resolver == nil) return;
            weakResolver = resolver;
            if (![kernel startSynchronouslyWithError:&error]) {
                MTIconServiceLogError(@"initial-snapshot", error);
                // The Kernel retains its stock snapshot and can recover on a
                // later canonical Runtime notification.
            }
            MTIconServiceKernel = kernel;
            MTIconServiceResolver = resolver;
        }
        if (MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1) {
            MTIconServiceStoreInvalidator *invalidator =
                [[MTIconServiceStoreInvalidator alloc] init];
            if (![invalidator installWithError:&error]) {
                MTIconServiceLogError(@"store-control", error);
                MTIconServiceResolver = nil;
                MTIconServiceKernel = nil;
                return;
            }
            MTIconServiceInvalidator = invalidator;
        }
        if (!MTIconServiceGenerationAdapterInstall(
                mode, MTIconServiceResolver, &error)) {
            MTIconServiceLogError(@"generation-adapter", error);
            MTIconServiceResolver = nil;
            MTIconServiceKernel = nil;
            return;
        }
        os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_DEFAULT,
            "icon service runtime started mode=%{public}@",
            MTIconServiceRuntimeModeName(mode));
    }
}
