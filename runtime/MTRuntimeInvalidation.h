#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeInvalidationNotificationName;
FOUNDATION_EXPORT NSString *const MTIconServiceInvalidationNotificationName;

// A build- and PID-bound readiness record closes the cold-service race in
// which the Helper could post before iconservicesagent had mapped this image
// and registered its canonical-state listener. The state is diagnostic and
// advisory; the per-sequence acknowledgement remains the transaction proof.
typedef NS_ENUM(uint8_t, MTIconServiceRuntimeStage) {
    MTIconServiceRuntimeStageUnknown = 0,
    MTIconServiceRuntimeStageStarting = 1,
    MTIconServiceRuntimeStageSnapshotReady = 2,
    MTIconServiceRuntimeStageStoreControlReady = 3,
    MTIconServiceRuntimeStageReady = 4,
    MTIconServiceRuntimeStageTransactionFailed = 5,
    MTIconServiceRuntimeStageDisabled = 64,
    MTIconServiceRuntimeStageSnapshotLoaderFailed = 128,
    MTIconServiceRuntimeStageSourceStateFailed = 129,
    MTIconServiceRuntimeStageStoreControlFailed = 130,
    MTIconServiceRuntimeStageGenerationAdapterFailed = 131,
};

typedef struct MTIconServiceRuntimeStatus {
    uint32_t runtimeBuild;
    uint32_t processIdentifier;
    MTIconServiceRuntimeStage stage;
    uint8_t detail;
} MTIconServiceRuntimeStatus;

FOUNDATION_EXPORT BOOL MTIconServicePublishRuntimeStatus(
    MTIconServiceRuntimeStage stage,
    uint8_t detail);
FOUNDATION_EXPORT BOOL MTIconServiceReadRuntimeStatus(
    MTIconServiceRuntimeStatus *statusOut);
FOUNDATION_EXPORT BOOL MTIconServiceRuntimeStatusIsCurrentAndLive(
    MTIconServiceRuntimeStatus status);
FOUNDATION_EXPORT BOOL MTIconServiceRuntimeStatusCanReceiveTransactions(
    MTIconServiceRuntimeStatus status);
FOUNDATION_EXPORT NSString *MTIconServiceRuntimeStageName(
    MTIconServiceRuntimeStage stage);

// Best-effort wake-up only. Canonical state remains the sole source of truth.
FOUNDATION_EXPORT BOOL MTRuntimePostInvalidation(void);

// Apply delivery is a one-shot control-plane acknowledgement, not Runtime hot
// path IPC. The name contains both the exact package build generation and the
// canonical state sequence, so an older image still mapped in SpringBoard
// cannot acknowledge a newly installed Runtime build.
FOUNDATION_EXPORT NSString *MTRuntimeAcknowledgementNotificationName(
    uint64_t sequence);
FOUNDATION_EXPORT BOOL
    MTRuntimePostInvalidationAndWaitForAcknowledgement(uint64_t sequence);
FOUNDATION_EXPORT BOOL MTRuntimePostAcknowledgement(uint64_t sequence);

// The Helper uses a separate service phase so outer display owners cannot
// acknowledge before IconServices has reloaded the new Generation and
// completed its native whole-cache transaction.
FOUNDATION_EXPORT BOOL MTIconServicePostInvalidation(void);
FOUNDATION_EXPORT NSString *MTIconServiceAcknowledgementNotificationName(
    uint64_t sequence);
FOUNDATION_EXPORT BOOL
    MTIconServicePostInvalidationAndWaitForAcknowledgement(uint64_t sequence);
FOUNDATION_EXPORT BOOL MTIconServicePostAcknowledgement(uint64_t sequence);

NS_ASSUME_NONNULL_END
