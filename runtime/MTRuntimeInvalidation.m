#import "MTRuntimeInvalidation.h"

#import <dispatch/dispatch.h>
#import <notify.h>

#include <errno.h>
#include <signal.h>
#include <unistd.h>

#if !defined(MARKTHEME_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME_RUNTIME_BUILD_NUMBER must identify the exact Runtime build"
#endif

_Static_assert(MARKTHEME_RUNTIME_BUILD_NUMBER > 0 &&
               MARKTHEME_RUNTIME_BUILD_NUMBER <= UINT16_MAX,
    "Runtime build must fit the IconServices readiness protocol");

NSString *const MTRuntimeInvalidationNotificationName =
    @"com.hmmzzz.marktheme.runtime-store-changed";
NSString *const MTIconServiceInvalidationNotificationName =
    @"com.hmmzzz.marktheme.icon-service-store-changed";
static NSString *const MTIconServiceRuntimeStatusNotificationName =
    @"com.hmmzzz.marktheme.icon-service-runtime-status";

static const uint64_t MTIconServiceStatusBuildShift = 48;
static const uint64_t MTIconServiceStatusPIDShift = 24;
static const uint64_t MTIconServiceStatusStageShift = 16;
static const uint64_t MTIconServiceStatusBuildMask = UINT64_C(0xffff);
static const uint64_t MTIconServiceStatusPIDMask = UINT64_C(0xffffff);
static const uint64_t MTIconServiceStatusByteMask = UINT64_C(0xff);

// Each phase is a verified transaction, not a UI animation deadline. Five
// seconds leaves room for a native IconServices clear operation or a busy
// SpringBoard main queue without turning a successful apply into a false
// reload request.
static const int64_t MTRuntimeAcknowledgementTimeoutNanoseconds =
    5000LL * NSEC_PER_MSEC;
static const int64_t MTIconServiceAcknowledgementTimeoutNanoseconds =
    5000LL * NSEC_PER_MSEC;

static uint64_t MTIconServiceRuntimeStatusWord(
    MTIconServiceRuntimeStage stage,
    uint8_t detail) {
    uint64_t build = (uint64_t)MARKTHEME_RUNTIME_BUILD_NUMBER;
    uint64_t processIdentifier = (uint64_t)getpid();
    return ((build & MTIconServiceStatusBuildMask)
                << MTIconServiceStatusBuildShift) |
        ((processIdentifier & MTIconServiceStatusPIDMask)
                << MTIconServiceStatusPIDShift) |
        (((uint64_t)stage & MTIconServiceStatusByteMask)
                << MTIconServiceStatusStageShift) |
        ((uint64_t)detail & MTIconServiceStatusByteMask);
}

BOOL MTIconServicePublishRuntimeStatus(MTIconServiceRuntimeStage stage,
                                       uint8_t detail) {
    static int token = NOTIFY_TOKEN_INVALID;
    static int registration = NOTIFY_STATUS_FAILED;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registration = notify_register_check(
            MTIconServiceRuntimeStatusNotificationName.UTF8String,
            &token);
    });
    if (registration != NOTIFY_STATUS_OK ||
        token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t status = MTIconServiceRuntimeStatusWord(stage, detail);
    return notify_set_state(token, status) == NOTIFY_STATUS_OK &&
        notify_post(
            MTIconServiceRuntimeStatusNotificationName.UTF8String) ==
            NOTIFY_STATUS_OK;
}

BOOL MTIconServiceReadRuntimeStatus(
    MTIconServiceRuntimeStatus *statusOut) {
    if (statusOut == NULL) return NO;
    *statusOut = (MTIconServiceRuntimeStatus){0};
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_check(
        MTIconServiceRuntimeStatusNotificationName.UTF8String, &token);
    if (registration != NOTIFY_STATUS_OK ||
        token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t status = 0;
    int readResult = notify_get_state(token, &status);
    notify_cancel(token);
    if (readResult != NOTIFY_STATUS_OK || status == 0) return NO;
    statusOut->runtimeBuild = (uint32_t)(
        (status >> MTIconServiceStatusBuildShift) &
        MTIconServiceStatusBuildMask);
    statusOut->processIdentifier = (uint32_t)(
        (status >> MTIconServiceStatusPIDShift) &
        MTIconServiceStatusPIDMask);
    statusOut->stage = (MTIconServiceRuntimeStage)(
        (status >> MTIconServiceStatusStageShift) &
        MTIconServiceStatusByteMask);
    statusOut->detail = (uint8_t)(status & MTIconServiceStatusByteMask);
    return statusOut->runtimeBuild > 0 &&
        statusOut->processIdentifier > 1 &&
        statusOut->stage != MTIconServiceRuntimeStageUnknown;
}

BOOL MTIconServiceRuntimeStatusIsCurrentAndLive(
    MTIconServiceRuntimeStatus status) {
    if (status.runtimeBuild != MARKTHEME_RUNTIME_BUILD_NUMBER ||
        status.processIdentifier <= 1 ||
        status.processIdentifier > INT32_MAX) {
        return NO;
    }
    if (kill((pid_t)status.processIdentifier, 0) == 0) return YES;
    return errno == EPERM;
}

BOOL MTIconServiceRuntimeStatusCanReceiveTransactions(
    MTIconServiceRuntimeStatus status) {
    return MTIconServiceRuntimeStatusIsCurrentAndLive(status) &&
        (status.stage == MTIconServiceRuntimeStageReady ||
         status.stage == MTIconServiceRuntimeStageTransactionFailed);
}

NSString *MTIconServiceRuntimeStageName(
    MTIconServiceRuntimeStage stage) {
    switch (stage) {
        case MTIconServiceRuntimeStageUnknown:
            return @"unknown";
        case MTIconServiceRuntimeStageStarting:
            return @"starting";
        case MTIconServiceRuntimeStageSnapshotReady:
            return @"snapshot-ready";
        case MTIconServiceRuntimeStageStoreControlReady:
            return @"store-control-ready";
        case MTIconServiceRuntimeStageReady:
            return @"ready";
        case MTIconServiceRuntimeStageTransactionFailed:
            return @"transaction-failed";
        case MTIconServiceRuntimeStageDisabled:
            return @"disabled";
        case MTIconServiceRuntimeStageSnapshotLoaderFailed:
            return @"snapshot-loader-failed";
        case MTIconServiceRuntimeStageSourceStateFailed:
            return @"source-state-failed";
        case MTIconServiceRuntimeStageStoreControlFailed:
            return @"store-control-failed";
        case MTIconServiceRuntimeStageGenerationAdapterFailed:
            return @"generation-adapter-failed";
    }
    return @"invalid";
}

static BOOL MTPostNotificationAndWaitForAcknowledgement(
    NSString *notificationName,
    NSString *acknowledgementName,
    int64_t timeoutNanoseconds,
    uint64_t expectedAcknowledgementState) {
    if (notificationName.length == 0 || acknowledgementName.length == 0) {
        return NO;
    }
    dispatch_semaphore_t acknowledgement = dispatch_semaphore_create(0);
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_dispatch(
        acknowledgementName.UTF8String,
        &token,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(__unused int callbackToken) {
            dispatch_semaphore_signal(acknowledgement);
        });
    if (registration != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    uint64_t state = 0;
    BOOL received = expectedAcknowledgementState != 0 &&
        notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
        state == expectedAcknowledgementState;
    BOOL posted = notify_post(notificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
    if (!received && posted) {
        BOOL callbackReceived = dispatch_semaphore_wait(
            acknowledgement,
            dispatch_time(DISPATCH_TIME_NOW,
                          timeoutNanoseconds)) == 0;
        if (callbackReceived && expectedAcknowledgementState == 0) {
            received = YES;
        }
    }
    if (!received && expectedAcknowledgementState != 0) {
        state = 0;
        received = notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
            state == expectedAcknowledgementState;
    }
    notify_cancel(token);
    return received;
}

static BOOL MTPostAcknowledgementNamed(NSString *name,
                                       uint64_t acknowledgementState) {
    if (name.length == 0) return NO;
    if (acknowledgementState == 0) {
        return notify_post(name.UTF8String) == NOTIFY_STATUS_OK;
    }
    int token = NOTIFY_TOKEN_INVALID;
    int registration = notify_register_check(name.UTF8String, &token);
    if (registration != NOTIFY_STATUS_OK || token == NOTIFY_TOKEN_INVALID) {
        return NO;
    }
    BOOL statePublished = notify_set_state(
        token, acknowledgementState) == NOTIFY_STATUS_OK;
    BOOL posted = notify_post(name.UTF8String) == NOTIFY_STATUS_OK;
    notify_cancel(token);
    return statePublished && posted;
}

BOOL MTRuntimePostInvalidation(void) {
    return notify_post(MTRuntimeInvalidationNotificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
}

NSString *MTRuntimeAcknowledgementNotificationName(uint64_t sequence) {
    return [NSString stringWithFormat:
        @"com.hmmzzz.marktheme.runtime-applied.b%llu.s%llu",
        (unsigned long long)MARKTHEME_RUNTIME_BUILD_NUMBER,
        (unsigned long long)sequence];
}

BOOL MTRuntimePostInvalidationAndWaitForAcknowledgement(uint64_t sequence) {
    return MTPostNotificationAndWaitForAcknowledgement(
        MTRuntimeInvalidationNotificationName,
        MTRuntimeAcknowledgementNotificationName(sequence),
        MTRuntimeAcknowledgementTimeoutNanoseconds, 0);
}

BOOL MTRuntimePostAcknowledgement(uint64_t sequence) {
    NSString *name = MTRuntimeAcknowledgementNotificationName(sequence);
    return MTPostAcknowledgementNamed(name, 0);
}

BOOL MTIconServicePostInvalidation(void) {
    return notify_post(MTIconServiceInvalidationNotificationName.UTF8String) ==
        NOTIFY_STATUS_OK;
}

NSString *MTIconServiceAcknowledgementNotificationName(uint64_t sequence) {
    return [NSString stringWithFormat:
        @"com.hmmzzz.marktheme.icon-service-applied.b%llu.s%llu",
        (unsigned long long)MARKTHEME_RUNTIME_BUILD_NUMBER,
        (unsigned long long)sequence];
}

BOOL MTIconServicePostInvalidationAndWaitForAcknowledgement(
    uint64_t sequence) {
    MTIconServiceRuntimeStatus status = {0};
    if (!MTIconServiceReadRuntimeStatus(&status) ||
        !MTIconServiceRuntimeStatusCanReceiveTransactions(status)) {
        return NO;
    }
    return MTPostNotificationAndWaitForAcknowledgement(
        MTIconServiceInvalidationNotificationName,
        MTIconServiceAcknowledgementNotificationName(sequence),
        MTIconServiceAcknowledgementTimeoutNanoseconds,
        status.processIdentifier);
}

BOOL MTIconServicePostAcknowledgement(uint64_t sequence) {
    NSString *name = MTIconServiceAcknowledgementNotificationName(sequence);
    return MTPostAcknowledgementNamed(name, (uint64_t)getpid());
}
