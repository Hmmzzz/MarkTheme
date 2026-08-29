#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTPreferencesUIResourceImageAdapterState) {
    MTPreferencesUIResourceImageAdapterStateDormant = 0,
    MTPreferencesUIResourceImageAdapterStateScheduled = 1,
    MTPreferencesUIResourceImageAdapterStateInstalled = 2,
    MTPreferencesUIResourceImageAdapterStateClassUnavailable = 10,
    MTPreferencesUIResourceImageAdapterStateClassImageMismatch = 11,
    MTPreferencesUIResourceImageAdapterStateMethodTypeMismatch = 12,
    MTPreferencesUIResourceImageAdapterStateImplementationImageMismatch = 13,
    MTPreferencesUIResourceImageAdapterStateResolverPreparationFailed = 14,
    MTPreferencesUIResourceImageAdapterStateOriginalUnavailable = 15,
};

typedef struct MTPreferencesUIResourceImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) stringKeys;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) replacementResults;
} MTPreferencesUIResourceImageAdapterObservation;

FOUNDATION_EXPORT MTPreferencesUIResourceImageAdapterObservation
    MTRuntimePreferencesUIResourceImageAdapterObservation;

// Schedules one structurally validated Preferences.framework Hook for
// non-application Settings glyphs. Application icons and controller refresh
// stay on the native IconServices/Preferences path.
FOUNDATION_EXPORT BOOL MTPreferencesUIResourceImageAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
