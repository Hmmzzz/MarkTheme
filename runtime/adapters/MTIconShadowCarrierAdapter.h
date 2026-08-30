#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*MTIconShadowCarrierResolver)(id iconImageView);
typedef void (*MTIconShadowCarrierCleaner)(id iconImageView);

typedef NS_ENUM(uint32_t, MTIconShadowCarrierAdapterState) {
    MTIconShadowCarrierAdapterStateDormant = 0,
    MTIconShadowCarrierAdapterStateScheduled = 1,
    MTIconShadowCarrierAdapterStateInstalled = 2,
    MTIconShadowCarrierAdapterStateRejected = 10,
};

typedef struct MTIconShadowCarrierAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) layoutCalls;
    _Atomic(uint64_t) reuseCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) folderExclusions;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) appliedResults;
    _Atomic(uint64_t) cleanupCalls;
    _Atomic(uint64_t) contractRejects;
} MTIconShadowCarrierAdapterObservation;

FOUNDATION_EXPORT MTIconShadowCarrierAdapterObservation
    MTRuntimeIconShadowCarrierAdapterObservation;

// Installs only on SBIconImageView itself. Layout is the first boundary at
// which Apple's carrier has final traits, geometry, and a superlayer; reuse is
// the corresponding native cleanup boundary. Theme changes recreate these
// carriers through the product-wide Respring policy.
FOUNDATION_EXPORT BOOL MTIconShadowCarrierAdapterSchedule(
    MTIconShadowCarrierResolver resolver,
    MTIconShadowCarrierCleaner cleaner,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
