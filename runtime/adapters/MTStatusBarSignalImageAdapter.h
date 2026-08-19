#import <Foundation/Foundation.h>

#import "MTStatusBarContract.h"

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*MTStatusBarSignalImageResolver)(
    id signalView,
    id _Nullable activeColor,
    MTStatusBarSignalKind kind,
    NSInteger level);

typedef NS_ENUM(uint32_t, MTStatusBarSignalImageAdapterState) {
    MTStatusBarSignalImageAdapterStateDormant = 0,
    MTStatusBarSignalImageAdapterStateScheduled = 1,
    MTStatusBarSignalImageAdapterStateInstalled = 2,
    MTStatusBarSignalImageAdapterStateRejected = 10,
};

typedef struct MTStatusBarSignalImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) setActiveCalls;
    _Atomic(uint64_t) styleCalls;
    _Atomic(uint64_t) wifiLayoutCalls;
    _Atomic(uint64_t) cellularLayoutCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) appliedResults;
    _Atomic(uint64_t) stockRestores;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
    _Atomic(uint64_t) discoveryPasses;
    _Atomic(uint64_t) enumeratedWindows;
    _Atomic(uint64_t) visitedViews;
    _Atomic(uint64_t) discoveredSignalViews;
} MTStatusBarSignalImageAdapterObservation;

FOUNDATION_EXPORT MTStatusBarSignalImageAdapterObservation
    MTRuntimeStatusBarSignalImageAdapterObservation;

FOUNDATION_EXPORT BOOL MTStatusBarSignalImageAdapterSchedule(
    MTStatusBarSignalImageResolver resolver,
    NSError **error);
FOUNDATION_EXPORT void MTStatusBarSignalImageAdapterRefresh(void);

NS_ASSUME_NONNULL_END
