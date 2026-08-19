#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTShareSheetActivityImageAdapterState) {
    MTShareSheetActivityImageAdapterStateDormant = 0,
    MTShareSheetActivityImageAdapterStateScheduled = 1,
    MTShareSheetActivityImageAdapterStateInstalled = 2,
    MTShareSheetActivityImageAdapterStateClassUnavailable = 10,
    MTShareSheetActivityImageAdapterStateClassImageMismatch = 11,
    MTShareSheetActivityImageAdapterStateMethodTypeMismatch = 12,
    MTShareSheetActivityImageAdapterStateImplementationImageMismatch = 13,
    MTShareSheetActivityImageAdapterStateResolverPreparationFailed = 14,
};

typedef struct MTShareSheetActivityImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) uiActivityImageCalls;
    _Atomic(uint64_t) uiActivitySettingsImageCalls;
    _Atomic(uint64_t) proxyImageCalls;
    _Atomic(uint64_t) proxySettingsImageCalls;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) identityResults;
    _Atomic(uint64_t) identityMisses;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) applicationIconCalls;
    _Atomic(uint64_t) applicationIconIdentityResults;
    _Atomic(uint64_t) applicationIconIdentityMisses;
    _Atomic(uint64_t) applicationIconReplacementResults;
    _Atomic(uint64_t) uiKitApplicationIconCalls;
    _Atomic(uint64_t) uiKitApplicationIconReplacementResults;
    _Atomic(uint64_t) activityApplicationIconCalls;
    _Atomic(uint64_t) activityApplicationIconReplacementResults;
    _Atomic(uint64_t) activityApplicationSettingsIconCalls;
    _Atomic(uint64_t) activityApplicationSettingsIconReplacementResults;
} MTShareSheetActivityImageAdapterObservation;

FOUNDATION_EXPORT MTShareSheetActivityImageAdapterObservation
    MTRuntimeShareSheetActivityImageAdapterObservation;

// Schedules one build-pinned ShareSheet-host adapter. UIKitCore's bundle-aware
// producer installs as soon as UIKit is present, while ShareSheet/SharingUI
// producers install when those images arrive. The exact UIActivity class
// methods cover in-process hosts such as Photos that request App artwork by
// bundle identifier without entering the provider or UIImage producer. The
// UIActivity plus UIApplicationExtensionActivity's two exact image overrides
// recover the containing App identity before reusing the same static/mask
// resolver. This keeps a host App's first share presentation covered without
// polling. Every Hook calls stock first, and exact misses preserve the original
// result.
FOUNDATION_EXPORT BOOL MTShareSheetActivityImageAdapterSchedule(
    MTRuntimeReplacementResolver activityResolver,
    MTRuntimeReplacementResolver applicationIconResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
