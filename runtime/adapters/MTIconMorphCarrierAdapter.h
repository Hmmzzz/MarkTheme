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
    _Atomic(uint64_t) scopeUpdates;
    _Atomic(uint64_t) squareContentsCalls;
    _Atomic(uint64_t) eligibleCarriers;
    _Atomic(uint64_t) prepareCalls;
    _Atomic(uint64_t) proxyActivations;
    _Atomic(uint64_t) fadeSynchronizations;
    _Atomic(uint64_t) cleanups;
} MTIconMorphCarrierAdapterObservation;

FOUNDATION_EXPORT MTIconMorphCarrierAdapterObservation
    MTRuntimeIconMorphCarrierAdapterObservation;

// Installs only SpringBoard's return-home carrier geometry bridge. It never
// resolves, composes, or replaces application-icon pixels: squareContentsImage
// remains Apple's result, which is already produced by the IconServices source.
FOUNDATION_EXPORT BOOL MTIconMorphCarrierAdapterSchedule(NSError **error);

// The immutable set contains only bundle identifiers whose current
// IconServices output differs from stock. An empty set restores the complete
// native morph path, including when theming is disabled.
FOUNDATION_EXPORT void MTIconMorphCarrierAdapterUpdateAffectedBundleIdentifiers(
    NSSet<NSString *> *bundleIdentifiers);

NS_ASSUME_NONNULL_END
