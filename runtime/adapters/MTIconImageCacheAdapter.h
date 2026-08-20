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
} MTIconImageCacheAdapterObservation;

FOUNDATION_EXPORT MTIconImageCacheAdapterObservation
    MTRuntimeIconImageCacheAdapterObservation;
// Schedules the mandatory shared SBIcon producer and, in SpringBoard mode,
// the ordinary SBApplicationIcon producers. Guarded cache lookup, fill,
// recipient tracking, and targeted refresh boundaries are optional OS
// capabilities installed independently when their exact ABIs are present.
// SpringBoard mode additionally owns the ordinary SBApplicationIcon masked
// and unmasked producers; embedded-cache mode deliberately does not require
// that SpringBoard-only class. Recording every actual cache recipient lets App
// Switcher and SearchUI participate in the same targeted Generation
// invalidation. SpringBoard additionally guards iOS 18's single native image
// commit boundary so direct, cache, and placeholder animation carriers cannot
// diverge; this boundary is invoked only for image updates, never per frame.
FOUNDATION_EXPORT BOOL MTIconImageCacheAdapterSchedule(
    MTIconImageCacheAdapterMode mode,
    MTRuntimeReplacementResolver appearanceResolver,
    MTRuntimeReplacementResolver sourceResolver,
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
