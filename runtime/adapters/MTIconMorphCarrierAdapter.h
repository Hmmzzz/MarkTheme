#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTIconMorphCarrierAdapterState) {
    MTIconMorphCarrierAdapterStateDormant = 0,
    MTIconMorphCarrierAdapterStateScheduled = 1,
    MTIconMorphCarrierAdapterStateInstalled = 2,
    MTIconMorphCarrierAdapterStateRejected = 10,
};

typedef struct MTIconMorphCarrierAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) squareContentsCalls;
    _Atomic(uint64_t) eligibleCarriers;
    _Atomic(uint64_t) prepareCalls;
    _Atomic(uint64_t) proxyActivations;
    _Atomic(uint64_t) fadeSynchronizations;
    _Atomic(uint64_t) cleanups;
} MTIconMorphCarrierAdapterObservation;

FOUNDATION_EXPORT MTIconMorphCarrierAdapterObservation
    MTRuntimeIconMorphCarrierAdapterObservation;

typedef BOOL (^MTIconMorphCarrierScopeResolver)(
    NSString *bundleIdentifier);
typedef id _Nullable (^MTIconMorphCarrierImageResolver)(
    NSString *bundleIdentifier,
    id originalImage);
typedef void (*MTIconMorphCarrierTransitionCallback)(id iconImageView);

// Installs SpringBoard's return-home carrier geometry bridge. Apple's original
// squareContentsImage remains the native return value; imageResolver supplies
// only the private crossfade proxy raster so a raw square carrier cannot bypass
// the active custom mask or the system-mask fallback during the animation.
FOUNDATION_EXPORT BOOL MTIconMorphCarrierAdapterSchedule(
    MTIconMorphCarrierScopeResolver scopeResolver,
    MTIconMorphCarrierImageResolver imageResolver,
    MTIconMorphCarrierTransitionCallback transitionWillBegin,
    MTIconMorphCarrierTransitionCallback transitionDidEnd,
    NSError **error);

NS_ASSUME_NONNULL_END
