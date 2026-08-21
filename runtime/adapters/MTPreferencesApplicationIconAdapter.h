#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTPreferencesApplicationIconAdapterState) {
    MTPreferencesApplicationIconAdapterStateDormant = 0,
    MTPreferencesApplicationIconAdapterStateScheduled = 1,
    MTPreferencesApplicationIconAdapterStateInstalled = 2,
    MTPreferencesApplicationIconAdapterStateClassUnavailable = 10,
    MTPreferencesApplicationIconAdapterStateClassImageMismatch = 11,
    MTPreferencesApplicationIconAdapterStateMethodTypeMismatch = 12,
    MTPreferencesApplicationIconAdapterStateImplementationImageMismatch = 13,
    MTPreferencesApplicationIconAdapterStateResolverPreparationFailed = 14,
    MTPreferencesApplicationIconAdapterStateOriginalUnavailable = 15,
};

typedef struct MTPreferencesApplicationIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) identifierResults;
    _Atomic(uint64_t) identifierMisses;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) replacementResults;
} MTPreferencesApplicationIconAdapterObservation;

FOUNDATION_EXPORT MTPreferencesApplicationIconAdapterObservation
    MTRuntimePreferencesApplicationIconAdapterObservation;

// Hooks Preferences.framework's final lazy-icon producer shared by iOS 16,
// 17, and 18. The system producer always runs first; only a string bundle-ID
// hit may replace the returned application image.
FOUNDATION_EXPORT BOOL MTPreferencesApplicationIconAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
