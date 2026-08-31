#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTDialerSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTDialerSnapshotModuleState) {
    MTDialerSnapshotModuleStateDormant = 0,
    MTDialerSnapshotModuleStateConfigured = 1,
    MTDialerSnapshotModuleStateReady = 2,
};

typedef struct MTDialerSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) imageRequests;
    _Atomic(uint64_t) contractRejects;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) completeSetChecks;
    _Atomic(uint64_t) completeSetPasses;
} MTDialerSnapshotObservation;

FOUNDATION_EXPORT MTDialerSnapshotObservation
    MTRuntimeDialerSnapshotObservation;

FOUNDATION_EXPORT BOOL MTDialerSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT BOOL MTDialerSnapshotPrepare(void);

// Produces one fixed 75-point legacy canvas at the scale of Apple's original
// source image. The bounded process-local cache is generation/content keyed;
// native glyph layers and UIButton carriers retain the returned UIImage.
FOUNDATION_EXPORT id _Nullable MTDialerSnapshotResolveImage(
    NSString *subject,
    id originalResult);

// Number canvases are activated only as one complete, successfully decoded
// 0...11 set. This keeps the native circle-alpha decision consistent with the
// image-source decision and makes partial/corrupt themes fail wholly to stock.
FOUNDATION_EXPORT BOOL MTDialerSnapshotHasCompleteNumberSet(void);

NS_ASSUME_NONNULL_END
