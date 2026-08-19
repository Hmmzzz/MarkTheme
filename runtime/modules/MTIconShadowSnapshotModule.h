#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconShadowSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTIconShadowSnapshotModuleState) {
    MTIconShadowSnapshotModuleStateDormant = 0,
    MTIconShadowSnapshotModuleStateConfigured = 1,
    MTIconShadowSnapshotModuleStateReady = 2,
};

typedef struct MTIconShadowSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) viewResolutions;
    _Atomic(uint64_t) layersCreated;
    _Atomic(uint64_t) layerUpdates;
    _Atomic(uint64_t) layersRemoved;
    _Atomic(uint64_t) contextMisses;
} MTIconShadowSnapshotObservation;

FOUNDATION_EXPORT MTIconShadowSnapshotObservation
    MTRuntimeIconShadowSnapshotObservation;

FOUNDATION_EXPORT BOOL MTIconShadowSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT void MTIconShadowSnapshotReload(void);
FOUNDATION_EXPORT void MTIconShadowSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);

// Called only after SBIconView has completed its own configuration. A miss
// removes a previous MarkTheme layer and leaves the stock icon hierarchy.
FOUNDATION_EXPORT BOOL MTIconShadowSnapshotResolveView(
    id iconView,
    id iconImageView);
FOUNDATION_EXPORT void MTIconShadowSnapshotForgetView(
    id iconView,
    id _Nullable iconImageView);

NS_ASSUME_NONNULL_END
