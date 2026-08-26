#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconOverlaySnapshotModuleID;

typedef NS_ENUM(uint32_t, MTIconOverlaySnapshotModuleState) {
    MTIconOverlaySnapshotModuleStateDormant = 0,
    MTIconOverlaySnapshotModuleStateConfigured = 1,
    MTIconOverlaySnapshotModuleStateReady = 2,
};

typedef struct MTIconOverlaySnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) overlayResourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) resolutionCalls;
    _Atomic(uint64_t) unsupportedCandidateMisses;
    _Atomic(uint64_t) alreadyProcessedHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) compositions;
    _Atomic(uint64_t) restores;
    _Atomic(uint64_t) memoryPressurePurges;
    _Atomic(uint64_t) cacheEvictions;
} MTIconOverlaySnapshotObservation;

FOUNDATION_EXPORT MTIconOverlaySnapshotObservation
    MTRuntimeIconOverlaySnapshotObservation;

FOUNDATION_EXPORT BOOL MTIconOverlaySnapshotConfigure(
    MTRuntimeKernel *kernel,
    BOOL systemSurfaceContractsEnabled,
    NSError **error);
FOUNDATION_EXPORT BOOL MTIconOverlaySnapshotPrepare(void);

// Bootstrap calls this before installing the shared icon-cache adapter. Later
// calls run on the Kernel reload queue and atomically publish one global
// overlay.
FOUNDATION_EXPORT void MTIconOverlaySnapshotReload(void);
FOUNDATION_EXPORT BOOL MTIconOverlaySnapshotIsReadyForGeneration(
    NSString *generationIdentifier);
FOUNDATION_EXPORT BOOL MTIconOverlaySnapshotIsEnabled(void);

// A nil result means this module did not change the candidate. When the
// candidate carries an older MarkTheme overlay, a disabled/new snapshot returns
// the retained pre-overlay source so rollback and theme switches never compound
// two layers of authored artwork on one icon.
FOUNDATION_EXPORT id _Nullable MTIconOverlaySnapshotResolve(
    NSString *bundleIdentifier,
    id _Nullable candidateImage);

// Applies the authored overlay to an explicit point-size/scale contract from a
// proven system producer. This never consults UIScreen or another process
// singleton.
FOUNDATION_EXPORT id _Nullable MTIconOverlaySnapshotResolveSystemSurface(
    NSString *bundleIdentifier,
    id _Nullable candidateImage,
    CGSize pointSize,
    CGFloat scale);

// Returns candidate unchanged when no global overlay is active, or an already
// composed object for the current overlay. A nil result means the active
// overlay still requires composition, so the Adapter must keep its
// original-first path. This function never creates pixels.
FOUNDATION_EXPORT id _Nullable MTIconOverlaySnapshotResolveReady(
    NSString *bundleIdentifier,
    id _Nullable candidateImage);

NS_ASSUME_NONNULL_END
