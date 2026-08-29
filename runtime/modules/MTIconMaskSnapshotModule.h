#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconMaskSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTIconMaskSnapshotModuleState) {
    MTIconMaskSnapshotModuleStateDormant = 0,
    MTIconMaskSnapshotModuleStateConfigured = 1,
    MTIconMaskSnapshotModuleStateReady = 2,
};

typedef struct MTIconMaskSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) maskResourceHits;
    _Atomic(uint64_t) patternResourceHits;
    _Atomic(uint64_t) patternDigestMatches;
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
} MTIconMaskSnapshotObservation;

FOUNDATION_EXPORT MTIconMaskSnapshotObservation
    MTRuntimeIconMaskSnapshotObservation;

FOUNDATION_EXPORT BOOL MTIconMaskSnapshotConfigure(
    MTRuntimeKernel *kernel,
    BOOL systemSurfaceContractsEnabled,
    NSError **error);
FOUNDATION_EXPORT BOOL MTIconMaskSnapshotPrepare(void);

// Bootstrap calls this before installing the shared icon-cache adapter. Later
// calls run on the Kernel reload queue and atomically publish one global mask.
FOUNDATION_EXPORT void MTIconMaskSnapshotReload(void);
FOUNDATION_EXPORT BOOL MTIconMaskSnapshotIsReadyForGeneration(
    NSString *generationIdentifier);
FOUNDATION_EXPORT BOOL MTIconMaskSnapshotIsEnabled(void);
FOUNDATION_EXPORT BOOL MTIconMaskSnapshotUsesSystemMask(void);

// A nil result means this module did not change the candidate. When the
// candidate was produced by an older MarkTheme mask, a disabled/new snapshot
// returns the retained unmasked source so rollback and switches do not compound
// alpha edges across the three existing icon-cache entry points.
FOUNDATION_EXPORT id _Nullable MTIconMaskSnapshotResolve(
    NSString *bundleIdentifier,
    id _Nullable candidateImage,
    id _Nullable systemMaskImage);

// Applies either the authored mask or the one native IconServices squircle to
// an explicit point-size/scale contract supplied by a proven system producer.
// The already-produced stock image is retained only as a transparent-alpha
// fallback carrier. This never consults UIScreen or another process singleton.
FOUNDATION_EXPORT id _Nullable MTIconMaskSnapshotResolveSystemSurface(
    NSString *bundleIdentifier,
    id _Nullable candidateImage,
    id _Nullable systemMaskImage,
    CGSize pointSize,
    CGFloat scale);

// Returns candidate unchanged when no global mask is active, or an already
// composed object for the current mask. A nil result means the active mask
// still requires composition, so the Adapter must keep its original-first
// path. This function never creates pixels.
FOUNDATION_EXPORT id _Nullable MTIconMaskSnapshotResolveReady(
    NSString *bundleIdentifier,
    id _Nullable candidateImage);

// Returns immutable CALayer-compatible contents for one exact image result.
// The ProcessAdapter treats this as an opaque carrier proof and performs no
// raster inspection or visual composition of its own.
FOUNDATION_EXPORT id _Nullable MTIconMaskSnapshotLayerContents(
    id _Nullable candidateImage);

NS_ASSUME_NONNULL_END
