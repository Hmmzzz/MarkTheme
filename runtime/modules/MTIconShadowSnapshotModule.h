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
    _Atomic(uint64_t) preparationAttempts;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) carrierResolutions;
    _Atomic(uint64_t) attachmentsCreated;
    _Atomic(uint64_t) attachmentUpdates;
    _Atomic(uint64_t) attachmentsRemoved;
    _Atomic(uint64_t) contextMisses;
} MTIconShadowSnapshotObservation;

FOUNDATION_EXPORT MTIconShadowSnapshotObservation
    MTRuntimeIconShadowSnapshotObservation;

FOUNDATION_EXPORT BOOL MTIconShadowSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);

// Installation preparation is Foundation-only. The first real carrier layout
// supplies exact traits and performs at most one decode for that immutable
// context. The process snapshot is intentionally frozen until Respring.
FOUNDATION_EXPORT BOOL MTIconShadowSnapshotPrepare(void);

// Adds one associated sibling layer immediately below Apple's icon-image
// carrier. False means the carrier stays stock and any stale attachment is
// removed.
FOUNDATION_EXPORT BOOL MTIconShadowSnapshotApplyToCarrier(id iconImageView);
FOUNDATION_EXPORT void MTIconShadowSnapshotClearCarrier(id iconImageView);

NS_ASSUME_NONNULL_END
