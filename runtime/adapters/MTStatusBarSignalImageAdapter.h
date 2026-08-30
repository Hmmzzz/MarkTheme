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
    _Atomic(uint64_t) wifiCommitCalls;
    _Atomic(uint64_t) cellularCommitCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) appliedResults;
    _Atomic(uint64_t) stockFallbacks;
    _Atomic(uint64_t) contractRejects;
} MTStatusBarSignalImageAdapterObservation;

FOUNDATION_EXPORT MTStatusBarSignalImageAdapterObservation
    MTRuntimeStatusBarSignalImageAdapterObservation;

FOUNDATION_EXPORT BOOL MTStatusBarSignalImageAdapterSchedule(
    MTStatusBarSignalImageResolver resolver,
    NSError **error);

NS_ASSUME_NONNULL_END
