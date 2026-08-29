#import <Foundation/Foundation.h>

#import <os/log.h>

#include <stdatomic.h>

#import "MTIconServiceGenerationAdapter.h"
#import "MTIconServiceImageResolver.h"
#import "MTIconServiceProvenCanary.h"
#import "MTIconServiceRuntimeMode.h"
#import "MTIconServiceSourcePolicy.h"
#import "MTIconServiceStoreInvalidator.h"
#import "MTApplicationIconInvalidationScope.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeFeatureState.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"

#if !defined(MARKTHEME_ICON_SERVICE_STORE_CONTROL)
#define MARKTHEME_ICON_SERVICE_STORE_CONTROL 1
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_STORE_CONTROL == 0 ||
               MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1,
    "MARKTHEME_ICON_SERVICE_STORE_CONTROL must be disabled or enabled");

static MTRuntimeKernel *MTIconServiceKernel;
static MTIconServiceImageResolver *MTIconServiceResolver;
static MTIconServiceStoreInvalidator *MTIconServiceInvalidator;
static atomic_bool MTIconServiceRuntimeReady;
static NSString *MTIconServiceCompletedSourceFingerprint;

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

static uint8_t MTIconServiceErrorDetail(NSError *error) {
    if (error == nil || error.code <= 0) return 0;
    return (uint8_t)MIN((NSUInteger)error.code, (NSUInteger)UINT8_MAX);
}

static void MTIconServiceCompleteSourceState(
    MTRuntimeSnapshot *snapshot) {
    MTRuntimeFeatureState *state =
        MTApplicationIconSourceFeatureState(snapshot);
    MTIconServiceImageResolver *resolver = MTIconServiceResolver;
    if (state == nil || resolver == nil ||
        ![resolver updateSourceFingerprint:state.fingerprint]) {
        MTIconServiceLogError(@"source-fingerprint", nil);
        (void)MTIconServicePublishRuntimeStatus(
            MTIconServiceRuntimeStageTransactionFailed, 1);
        return;
    }
    if (!atomic_load_explicit(
            &MTIconServiceRuntimeReady, memory_order_acquire) ||
        MARKTHEME_ICON_SERVICE_STORE_CONTROL != 1) {
        return;
    }
    uint64_t sequence = snapshot.state.sequence;
    @synchronized (MTIconServiceImageResolver.class) {
        if ([MTIconServiceCompletedSourceFingerprint
                isEqualToString:state.fingerprint]) {
            os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_DEFAULT,
                "application-icon source unchanged sequence=%{public}llu; "
                "native cache transaction skipped",
                (unsigned long long)sequence);
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageReady, 0);
            (void)MTIconServicePostAcknowledgement(sequence);
            return;
        }
    }
    if (MTIconServiceGenerationRolloutIsEnabled() ||
        MTIconServiceProvenCanaryIsEnabled()) {
        MTIconServiceStoreInvalidator *storeInvalidator =
            MTIconServiceInvalidator;
        [storeInvalidator invalidateWholeStoreWithCompletion:
            ^(MTIconServiceStoreInvalidationResult *result) {
                os_log_with_type(
                    MTIconServiceLog(),
                    result.isVerified
                        ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
                    "native whole-cache transaction outcome=%{public}@",
                    result.outcome);
                if (result.isVerified) {
                    @synchronized (MTIconServiceImageResolver.class) {
                        MTIconServiceCompletedSourceFingerprint =
                            state.fingerprint;
                    }
                    (void)MTIconServicePublishRuntimeStatus(
                        MTIconServiceRuntimeStageReady, 0);
                    (void)MTIconServicePostAcknowledgement(sequence);
                } else {
                    (void)MTIconServicePublishRuntimeStatus(
                        MTIconServiceRuntimeStageTransactionFailed, 2);
                }
            }];
        return;
    }
    // A deny-all source build admits no themed pixel request. Publishing its
    // fingerprint is enough to complete this phase without cache mutation.
    @synchronized (MTIconServiceImageResolver.class) {
        MTIconServiceCompletedSourceFingerprint = state.fingerprint;
    }
    (void)MTIconServicePublishRuntimeStatus(
        MTIconServiceRuntimeStageReady, 0);
    (void)MTIconServicePostAcknowledgement(sequence);
}

__attribute__((constructor))
static void MTIconServiceBootstrap(void) {
    @autoreleasepool {
        MTIconServiceRuntimeMode mode =
            MTIconServiceConfiguredRuntimeMode();
        // The release-development default performs no class lookup, framework
        // call, store read, listener registration, or Hook installation.
        if (mode == MTIconServiceRuntimeModeDisabled) {
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageDisabled, 0);
            return;
        }
        (void)MTIconServicePublishRuntimeStatus(
            MTIconServiceRuntimeStageStarting, 0);

        NSError *error = nil;
        if (mode == MTIconServiceRuntimeModeSource) {
            MTRuntimeSnapshotLoader *loader =
                [MTRuntimeSnapshotLoader defaultLoaderWithError:&error];
            if (loader == nil) {
                MTIconServiceLogError(@"snapshot-loader", error);
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageSnapshotLoaderFailed,
                    MTIconServiceErrorDetail(error));
                return;
            }
            MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
                initWithLoader:loader
                notificationName:MTIconServiceInvalidationNotificationName
                reloadHandler:^(MTRuntimeReloadDisposition disposition,
                                MTRuntimeSnapshot *snapshot,
                                NSError *reloadError) {
                    if (disposition ==
                        MTRuntimeReloadDispositionRetainedAfterFailure) {
                        MTIconServiceLogError(@"snapshot-reload", reloadError);
                        return;
                    }
                    MTIconServiceCompleteSourceState(snapshot);
                }];
            MTIconServiceImageResolver *resolver =
                [[MTIconServiceImageResolver alloc]
                    initWithSnapshotProvider:^MTRuntimeSnapshot *{
                        return kernel.currentSnapshot;
                    }];
            if (kernel == nil || resolver == nil) return;
            MTIconServiceKernel = kernel;
            MTIconServiceResolver = resolver;
            if (![kernel startSynchronouslyWithError:&error]) {
                MTIconServiceLogError(@"initial-snapshot", error);
                // The Kernel retains its stock snapshot and can recover on a
                // later canonical Runtime notification.
            }
            MTRuntimeFeatureState *initialState =
                MTApplicationIconSourceFeatureState(kernel.currentSnapshot);
            if (initialState == nil ||
                ![resolver updateSourceFingerprint:
                    initialState.fingerprint]) {
                MTIconServiceLogError(@"initial-source-fingerprint", nil);
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageSourceStateFailed, 0);
                MTIconServiceResolver = nil;
                MTIconServiceKernel = nil;
                return;
            }
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageSnapshotReady, 0);
        }
        if (MARKTHEME_ICON_SERVICE_STORE_CONTROL == 1) {
            MTIconServiceStoreInvalidator *invalidator =
                [[MTIconServiceStoreInvalidator alloc] init];
            if (![invalidator installWithError:&error]) {
                MTIconServiceLogError(@"store-control", error);
                (void)MTIconServicePublishRuntimeStatus(
                    MTIconServiceRuntimeStageStoreControlFailed,
                    MTIconServiceErrorDetail(error));
                MTIconServiceResolver = nil;
                MTIconServiceKernel = nil;
                return;
            }
            MTIconServiceInvalidator = invalidator;
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageStoreControlReady, 0);
        }
        if (!MTIconServiceGenerationAdapterInstall(
                mode, MTIconServiceResolver, &error)) {
            MTIconServiceLogError(@"generation-adapter", error);
            (void)MTIconServicePublishRuntimeStatus(
                MTIconServiceRuntimeStageGenerationAdapterFailed,
                MTIconServiceErrorDetail(error));
            MTIconServiceResolver = nil;
            MTIconServiceKernel = nil;
            return;
        }
        atomic_store_explicit(
            &MTIconServiceRuntimeReady, true, memory_order_release);
        (void)MTIconServicePublishRuntimeStatus(
            MTIconServiceRuntimeStageReady, 0);
        os_log_with_type(MTIconServiceLog(), OS_LOG_TYPE_DEFAULT,
            "icon service runtime started mode=%{public}@",
            MTIconServiceRuntimeModeName(mode));
    }
}
