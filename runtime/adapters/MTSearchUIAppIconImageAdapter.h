#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTSystemIconSurfaceResolver)(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale,
    id _Nullable originalResult);
typedef void (*MTLateIconCacheInstaller)(void);

typedef NS_ENUM(uint32_t, MTSearchUIAppIconImageAdapterState) {
    MTSearchUIAppIconImageAdapterStateDormant = 0,
    MTSearchUIAppIconImageAdapterStateInstalling = 1,
    MTSearchUIAppIconImageAdapterStateInstalled = 2,
    MTSearchUIAppIconImageAdapterStateClassUnavailable = 10,
    MTSearchUIAppIconImageAdapterStateClassImageMismatch = 11,
    MTSearchUIAppIconImageAdapterStateMethodTypeMismatch = 12,
    MTSearchUIAppIconImageAdapterStateImplementationImageMismatch = 13,
    MTSearchUIAppIconImageAdapterStateResolverPreparationFailed = 14,
    MTSearchUIAppIconImageAdapterStateOriginalUnavailable = 15,
};

typedef struct MTSearchUIAppIconImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) genericCalls;
    _Atomic(uint64_t) calendarCalls;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) identityResults;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) trackedImages;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshInvalidations;
    _Atomic(uint64_t) homeScreenUpdates;
    _Atomic(uint64_t) lateCacheInstallTriggers;
    _Atomic(uint64_t) homeScreenHookInstallations;
} MTSearchUIAppIconImageAdapterObservation;

FOUNDATION_EXPORT MTSearchUIAppIconImageAdapterObservation
    MTRuntimeSearchUIAppIconImageAdapterObservation;

// Installs structurally validated SearchUI app/calendar image producers. Each call runs
// Apple's producer first, then passes bundle identity plus its explicit
// point-size/scale contract to the shared snapshot resolver. The exact Siri
// home-screen update boundary only triggers a late cache-Adapter ABI recheck;
// it does not replace or lay out a view. No UIKit singleton is read here.
FOUNDATION_EXPORT BOOL MTSearchUIAppIconImageAdapterInstall(
    MTSystemIconSurfaceResolver resolver,
    BOOL (*preparation)(void),
    MTLateIconCacheInstaller lateIconCacheInstaller,
    NSError **error);

// Invalidates only live SearchUI app-image objects after an accepted
// Generation change. SearchUI then re-enters its own normal load/cache path.
FOUNDATION_EXPORT void MTSearchUIAppIconImageAdapterRefresh(void);

NS_ASSUME_NONNULL_END
