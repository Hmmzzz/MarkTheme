#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTStaticIconSnapshotModuleID;
FOUNDATION_EXPORT NSString *const MTStaticIconSnapshotModuleErrorDomain;
FOUNDATION_EXPORT const NSUInteger MTStaticIconSnapshotPrewarmBatchLimit;

typedef NS_ENUM(uint32_t, MTStaticIconSnapshotModuleState) {
    MTStaticIconSnapshotModuleStateDormant = 0,
    MTStaticIconSnapshotModuleStateConfigured = 1,
    MTStaticIconSnapshotModuleStatePrepared = 2,
};

typedef struct MTStaticIconSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) lookupCalls;
    _Atomic(uint64_t) unsupportedOriginalMisses;
    _Atomic(uint64_t) snapshotMisses;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) cacheHits;
    _Atomic(uint64_t) decodeScheduled;
    _Atomic(uint64_t) pendingMisses;
    _Atomic(uint64_t) failureMisses;
    _Atomic(uint64_t) saturatedMisses;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) staleCompletions;
    _Atomic(uint64_t) memoryPressurePurges;
    _Atomic(uint64_t) cacheEvictions;
    _Atomic(uint64_t) prewarmBatches;
    _Atomic(uint64_t) prewarmIdentifiers;
    _Atomic(uint64_t) prewarmResourceHits;
} MTStaticIconSnapshotObservation;

FOUNDATION_EXPORT MTStaticIconSnapshotObservation
    MTRuntimeStaticIconSnapshotObservation;

typedef void (^MTStaticIconSnapshotImageReadyHandler)(
    NSString *bundleIdentifier,
    NSString *generationIdentifier);
typedef void (^MTStaticIconSnapshotPrewarmCompletion)(
    NSSet<NSString *> *resolvedIdentifiers);

// Configures one process-local module against the already-created Kernel.
// Preparation runs on the Adapter's guarded main-queue install path.
FOUNDATION_EXPORT BOOL MTStaticIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    BOOL calendarCompositeEnabled,
    NSError **error);
FOUNDATION_EXPORT BOOL MTStaticIconSnapshotPrepare(void);
FOUNDATION_EXPORT void MTStaticIconSnapshotSetImageReadyHandler(
    MTStaticIconSnapshotImageReadyHandler _Nullable handler);

// A ready lookup is keyed directly by immutable Generation + bundle + image
// contract, so animation calls do not rebuild canonical resource keys or touch
// the Generation index. A valid foreground miss is still decoded once before
// returning, preserving the first observable themed result. Background
// prewarming shares that same bounded cache.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolve(
    NSString *bundleIdentifier,
    id _Nullable originalResult);

// Resolves one exact square application-icon contract supplied by a proven
// system producer such as SearchUI. Unlike the UIImage-shaped convenience
// entry above, this does not infer scale from a potentially rewrapped stock
// carrier.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolveSystemSurface(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale);

// Returns only an already-decoded primary SpringBoard icon. It performs no
// resource resolution, decode, pending wait, or Calendar composition and is
// therefore safe to query before the exact original animation image producer.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolveReady(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale);

// Resolves the same icons.static resource for SharingUI's image-provider and
// built-in activity boundaries. The stock image-like object supplies CGImage
// dimensions and scale; the returned UIImage preserves the proven 60pt top-row
// or 29pt More-list contract without adding another resource copy.
FOUNDATION_EXPORT id _Nullable MTStaticIconSnapshotResolveShareProviderImage(
    NSString *bundleIdentifier,
    id _Nullable originalResult,
    CGSize * _Nullable pointSizeOut,
    CGFloat * _Nullable scaleOut);

// Prepares one bounded identifier batch on the existing decode queue. The
// completion runs only after every earlier decode for that batch has settled
// and returns only identifiers resolved by the active Generation.
FOUNDATION_EXPORT void MTStaticIconSnapshotPrewarmBundleIdentifiers(
    NSArray<NSString *> *bundleIdentifiers,
    NSString *expectedGenerationIdentifier,
    MTStaticIconSnapshotPrewarmCompletion completion);

NS_ASSUME_NONNULL_END
