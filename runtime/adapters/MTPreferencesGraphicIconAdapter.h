#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTPreferencesGraphicIconResolver)(
    NSString *type, id originalImage, id descriptor);

typedef NS_ENUM(uint32_t, MTPreferencesGraphicIconAdapterState) {
    MTPreferencesGraphicIconAdapterStateDormant = 0,
    MTPreferencesGraphicIconAdapterStateScheduled = 1,
    MTPreferencesGraphicIconAdapterStateInstalled = 2,
    MTPreferencesGraphicIconAdapterStateRejected = 10,
};

typedef struct MTPreferencesGraphicIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) synchronousCalls;
    _Atomic(uint64_t) asynchronousCalls;
    _Atomic(uint64_t) identityResults;
    _Atomic(uint64_t) unsupportedCompletions;
    _Atomic(uint64_t) replacementResults;
} MTPreferencesGraphicIconAdapterObservation;

FOUNDATION_EXPORT MTPreferencesGraphicIconAdapterObservation
    MTRuntimePreferencesGraphicIconAdapterObservation;

// Independent from the legacy PKIconImageCache adapter. Installs only inside
// Preferences, and changes only exact ISTypeIcon graphic-icon requests.
FOUNDATION_EXPORT BOOL MTPreferencesGraphicIconAdapterSchedule(
    MTPreferencesGraphicIconResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
