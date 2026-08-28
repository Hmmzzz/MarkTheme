#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

@class MTRuntimeTargetedRefreshSnapshot;

typedef id _Nullable (*MTIconReadyReplacementResolver)(
    NSString *resourceIdentifier,
    CGSize pointSize,
    CGFloat scale);
typedef id _Nullable (*MTIconSystemSurfaceReplacementResolver)(
    NSString *resourceIdentifier,
    CGSize pointSize,
    CGFloat scale,
    id _Nullable originalResult);
typedef BOOL (*MTIconNativeSystemMaskRequirement)(void);
typedef uint64_t (*MTIconFinalDecorationVersionProvider)(
    id _Nullable candidateImage);

typedef NS_ENUM(NSUInteger, MTIconImageCacheAdapterMode) {
    // SpringBoard owns the SBIcon/SBApplicationIcon producers. Shared cache
    // and targeted-refresh contracts are installed when that OS exposes them,
    // but their removal must not suppress the still-valid producer Hooks.
    MTIconImageCacheAdapterModeSpringBoard = 0,
    // Spotlight embeds SpringBoardHome's SBHIconImageCache/SBIcon core but
    // does not load SpringBoard's SBApplicationIcon class. The cache, base
    // producer, identity and refresh contracts are still installed exactly.
    MTIconImageCacheAdapterModeEmbeddedCache = 1,
};

typedef NS_ENUM(uint32_t, MTIconImageCacheAdapterState) {
    MTIconImageCacheAdapterStateDormant = 0,
    MTIconImageCacheAdapterStateScheduled = 1,
    MTIconImageCacheAdapterStateInstalled = 2,
    MTIconImageCacheAdapterStateClassUnavailable = 10,
    MTIconImageCacheAdapterStateTargetClassImageMismatch = 11,
    MTIconImageCacheAdapterStateTargetMethodTypeMismatch = 12,
    MTIconImageCacheAdapterStateTargetImplementationImageMismatch = 13,
    MTIconImageCacheAdapterStateIdentityClassImageMismatch = 14,
    MTIconImageCacheAdapterStateIdentityMethodTypeMismatch = 15,
    MTIconImageCacheAdapterStateIdentityImplementationImageMismatch = 16,
    MTIconImageCacheAdapterStateOriginalUnavailable = 17,
    MTIconImageCacheAdapterStateResolverPreparationFailed = 18,
    MTIconImageCacheAdapterStateRefreshMethodUnavailable = 19,
    MTIconImageCacheAdapterStateRefreshMethodTypeMismatch = 20,
    MTIconImageCacheAdapterStateRefreshImplementationImageMismatch = 21,
    MTIconImageCacheAdapterStateRefreshNotificationMethodUnavailable = 22,
    MTIconImageCacheAdapterStateRefreshNotificationMethodTypeMismatch = 23,
    MTIconImageCacheAdapterStateRefreshNotificationImplementationImageMismatch =
        24,
    MTIconImageCacheAdapterStateTransitionMethodTypeMismatch = 25,
    MTIconImageCacheAdapterStateTransitionImplementationImageMismatch = 26,
    MTIconImageCacheAdapterStateCacheFillClassImageMismatch = 27,
    MTIconImageCacheAdapterStateCacheFillMethodTypeMismatch = 28,
    MTIconImageCacheAdapterStateCacheFillImplementationImageMismatch = 29,
    MTIconImageCacheAdapterStateSystemMaskMethodUnavailable = 30,
    MTIconImageCacheAdapterStateSystemMaskMethodTypeMismatch = 31,
    MTIconImageCacheAdapterStateSystemMaskImplementationImageMismatch = 32,
    MTIconImageCacheAdapterStateCacheRequestMethodUnavailable = 33,
    MTIconImageCacheAdapterStateCacheRequestMethodTypeMismatch = 34,
    MTIconImageCacheAdapterStateCacheRequestImplementationImageMismatch = 35,
};

typedef struct MTIconImageCacheAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    // ABI-reserved legacy counters. The compact observation report never
    // exposed these values, so the hot producer no longer mutates them.
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) identityClassMatches;
    _Atomic(uint64_t) identityStringResults;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) replacementResults;
    // Counts non-outer image paths: ordinary app producers plus special-icon
    // fallback fills. The fixed layout remains readable by the M5-B inspector.
    _Atomic(uint64_t) transitionCalls;
    _Atomic(uint64_t) transitionReplacements;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
    _Atomic(uint64_t) refreshCachePurges;
    _Atomic(uint64_t) refreshIconPurges;
    _Atomic(uint64_t) refreshObserverNotifications;
    _Atomic(uint64_t) cacheRequestCalls;
    _Atomic(uint64_t) cacheRequestRecipients;
    _Atomic(uint64_t) viewRecipientRecords;
    _Atomic(uint64_t) refreshNativeRecaches;
    // Counts the return-to-Home morph boundary and the square source proxy
    // used only for icon views carrying current MarkTheme pixels. The square
    // appearance compositions pre-round authored pixels because that proxy
    // suppresses SpringBoard's animated corner mask.
    _Atomic(uint64_t) morphPrepareCalls;
    _Atomic(uint64_t) morphProxyActivations;
    _Atomic(uint64_t) morphFadeSynchronizations;
    _Atomic(uint64_t) morphCleanups;
    _Atomic(uint64_t) squareMaskCompositions;
} MTIconImageCacheAdapterObservation;

FOUNDATION_EXPORT MTIconImageCacheAdapterObservation
    MTRuntimeIconImageCacheAdapterObservation;

// Keeps the final SBIconImageView commit boundaries separate from the broad
// producer/cache counters above. This is intentionally diagnostic-only: it
// tells a field report whether a stationary icon reached contentsImage, was
// skipped as a real non-animated display update, lost its bundle identity, or
// reached the decoration resolver and was accepted/rejected there.
typedef struct MTIconImageViewDiagnosticsObservation {
    uint32_t schemaVersion;
    uint32_t reserved;
    _Atomic(uint64_t) contentsCalls;
    _Atomic(uint64_t) displayCalls;
    _Atomic(uint64_t) displayStationaryRealCalls;
    _Atomic(uint64_t) identityMisses;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) alreadyCurrentResults;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) resolverMisses;
} MTIconImageViewDiagnosticsObservation;

FOUNDATION_EXPORT MTIconImageViewDiagnosticsObservation
    MTRuntimeIconImageViewDiagnosticsObservation;
// Schedules the mandatory shared SBIcon producer and, in SpringBoard mode,
// the ordinary SBApplicationIcon producers. Guarded cache lookup, fill,
// recipient tracking, and targeted refresh boundaries are optional OS
// capabilities installed independently when their exact ABIs are present.
// SpringBoard mode additionally owns the ordinary SBApplicationIcon masked
// and unmasked producers; embedded-cache mode deliberately does not require
// that SpringBoard-only class. Recording every actual cache recipient lets App
// Switcher and SearchUI participate in the same targeted Generation
// invalidation. SpringBoard additionally guards iOS 18's contextual producer
// so its real image and backing contentsLayer stay identical, then uses the
// final image-update boundary for async placeholders and for one narrow final
// decoration pass on real animation contents. iOS 16 and early iOS 17 instead
// commit stationary icons through SBIconImageView.contentsImage, so the same
// final-decoration resolver guards that exact getter before its bitmap is
// assigned to the layer. These boundaries let a module restore decoration
// that native pooling did not preserve without rerunning static replacement
// or mask composition, and neither performs per-frame work. The return-to-Home
// square carrier is deliberately unmasked by the OS
// and is rounded by an animated corner mask that the morph square proxy
// suppresses, so its dedicated resolver must compose the active mask into the
// pixels before the overlay; only a pre-rounded carrier may activate the
// proxy. On a resolver miss the carrier may still be pre-rounded from an
// earlier pass, so the proxy is conceded only when the pixel-free ready
// resolver confirms authored pixels for that bundle; otherwise the native
// carrier is kept and SpringBoard's animated mask rounds the morph.
FOUNDATION_EXPORT BOOL MTIconImageCacheAdapterSchedule(
    MTIconImageCacheAdapterMode mode,
    MTRuntimeReplacementResolver appearanceResolver,
    MTRuntimeReplacementResolver sourceResolver,
    // Must resolve only the final decoration layer and return the same object
    // when that layer is already current. It is used at animated real-image
    // and legacy stationary contents boundaries where repeating source or mask
    // work would corrupt composition.
    MTRuntimeReplacementResolver finalDecorationResolver,
    // Returns zero when the candidate needs no final-decoration work,
    // otherwise a version that changes whenever immutable artwork changes.
    // The provider must also return a stable nonzero cleanup version when an
    // inactive module recognizes its own prior result, preserving rollback.
    MTIconFinalDecorationVersionProvider finalDecorationVersionProvider,
    // Must resolve the unmasked square carrier with the active mask composed
    // into pixels before any overlay, and return nil whenever that carrier
    // does not gain authored decoration, so the native carrier keeps
    // SpringBoard's animated corner mask.
    MTRuntimeReplacementResolver squareAppearanceResolver,
    MTIconReadyReplacementResolver readyResolver,
    MTIconSystemSurfaceReplacementResolver systemSurfaceResolver,
    MTIconNativeSystemMaskRequirement nativeSystemMaskRequirement,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

// Rechecks the same exact ABI immediately at a proven main-thread host
// lifecycle boundary. A late-loaded framework can therefore install before
// its first icon update without a timer or background polling loop.
FOUNDATION_EXPORT void MTIconImageCacheAdapterInstallIfAvailable(void);

// Arms the one current Runtime sequence before refresh-snapshot capture. A
// SpringBoard process can load an already-active Generation before its first
// SBIconView exists; the lifecycle bridge below then performs exactly one
// native recache for each late icon object in that sequence.
FOUNDATION_EXPORT void MTIconImageCacheAdapterArmRefreshSequence(
    uint64_t sequence);

// Records the exact icon/cache pair already owned by one configured
// SBIconView. iOS 18 can satisfy the view entirely from its existing cache and
// therefore never cross either cache-request Hook; this main-thread lifecycle
// bridge lets Apply invoke the ABI-probed native recache operation without
// retaining the private objects beyond the next refresh snapshot.
FOUNDATION_EXPORT void MTIconImageCacheAdapterTrackVisibleIcon(
    id _Nullable cache,
    id _Nullable icon);

// Captures only weakly tracked cache/icon pairs. The coordinator may prewarm
// one identifier subset before invoking either the legacy purge/observer pair
// or the native per-icon recache operation on main.
FOUNDATION_EXPORT MTRuntimeTargetedRefreshSnapshot *
    MTIconImageCacheAdapterCaptureRefreshSnapshot(void);
FOUNDATION_EXPORT void MTIconImageCacheAdapterRefreshSnapshot(
    MTRuntimeTargetedRefreshSnapshot *snapshot,
    NSSet<NSString *> * _Nullable identifiers);

// Returns the original result with the selected snapshot resolver applied.
// Clock's live face uses this to share the same decoded object and cache as
// the ordinary/transition icon paths without importing image semantics into
// its ProcessAdapter.
FOUNDATION_EXPORT id _Nullable MTIconImageCacheAdapterResolveReplacement(
    NSString *identifier,
    id _Nullable originalResult,
    BOOL * _Nullable didReplace);

NS_ASSUME_NONNULL_END
