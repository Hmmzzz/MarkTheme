#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTClockNativeFaceResolver)(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale,
    BOOL includingMask,
    id originalResult);

typedef NS_ENUM(uint32_t, MTClockNativeSourceAdapterState) {
    MTClockNativeSourceAdapterStateDormant = 0,
    MTClockNativeSourceAdapterStateScheduled = 1,
    MTClockNativeSourceAdapterStateInstalled = 2,
    MTClockNativeSourceAdapterStateRejected = 10,
};

typedef struct MTClockNativeSourceAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) faceSourceCalls;
    _Atomic(uint64_t) maskedFaceCalls;
    _Atomic(uint64_t) unmaskedFaceCalls;
    _Atomic(uint64_t) themedFaces;
    _Atomic(uint64_t) handSourceCalls;
    _Atomic(uint64_t) themedHandSets;
    _Atomic(uint64_t) originalFailures;
    _Atomic(uint64_t) resolverMisses;
    _Atomic(uint64_t) contractRejects;
} MTClockNativeSourceAdapterObservation;

FOUNDATION_EXPORT MTClockNativeSourceAdapterObservation
    MTRuntimeClockNativeSourceAdapterObservation;

// Replaces only SpringBoardHome's two native Clock producers. The face
// resolver receives the exact SBIconImageInfo geometry and mask intent. The
// hand producer is changed before imageSetForMetrics: stores its result in the
// native process cache; all view/layer construction and animation stay Apple-
// owned. Process restart is the cache invalidation boundary.
FOUNDATION_EXPORT BOOL MTClockNativeSourceAdapterSchedule(
    MTClockNativeFaceResolver faceResolver,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
