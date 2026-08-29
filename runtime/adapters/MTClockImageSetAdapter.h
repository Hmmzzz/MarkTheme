#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTClockImageSetAdapterState) {
    MTClockImageSetAdapterStateDormant = 0,
    MTClockImageSetAdapterStateScheduled = 1,
    MTClockImageSetAdapterStateInstalled = 2,
    MTClockImageSetAdapterStateRejected = 10,
};

typedef struct MTClockImageSetAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) imageSetCalls;
    _Atomic(uint64_t) themedImageSets;
    // ABI-stable field names; these now count final contents/square face
    // outlets rather than the normal-path-inactive fallback factory.
    _Atomic(uint64_t) backgroundCalls;
    _Atomic(uint64_t) themedBackgrounds;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
} MTClockImageSetAdapterObservation;

FOUNDATION_EXPORT MTClockImageSetAdapterObservation
    MTRuntimeClockImageSetAdapterObservation;

FOUNDATION_EXPORT BOOL MTClockImageSetAdapterSchedule(
    MTRuntimeReplacementResolver faceResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);
FOUNDATION_EXPORT void MTClockImageSetAdapterRefresh(void);

NS_ASSUME_NONNULL_END
