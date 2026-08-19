#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSArray<id> * _Nonnull
    (*MTPreferencesAttachedControllerProvider)(void);

typedef NS_ENUM(uint32_t, MTPreferencesIconImageCacheAdapterState) {
    MTPreferencesIconImageCacheAdapterStateDormant = 0,
    MTPreferencesIconImageCacheAdapterStateScheduled = 1,
    MTPreferencesIconImageCacheAdapterStateInstalled = 2,
    MTPreferencesIconImageCacheAdapterStateClassUnavailable = 10,
    MTPreferencesIconImageCacheAdapterStateClassImageMismatch = 11,
    MTPreferencesIconImageCacheAdapterStateMethodTypeMismatch = 12,
    MTPreferencesIconImageCacheAdapterStateImplementationImageMismatch = 13,
    MTPreferencesIconImageCacheAdapterStateResolverPreparationFailed = 14,
    MTPreferencesIconImageCacheAdapterStateOriginalUnavailable = 15,
    MTPreferencesIconImageCacheAdapterStateRefreshClassUnavailable = 16,
    MTPreferencesIconImageCacheAdapterStateRefreshClassImageMismatch = 17,
    MTPreferencesIconImageCacheAdapterStateRefreshMethodTypeMismatch = 18,
    MTPreferencesIconImageCacheAdapterStateRefreshImplementationImageMismatch = 19,
};

typedef struct MTPreferencesIconImageCacheAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) stringKeys;
    _Atomic(uint64_t) nilOriginalResults;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshPasses;
    _Atomic(uint64_t) refreshRecipients;
} MTPreferencesIconImageCacheAdapterObservation;

FOUNDATION_EXPORT MTPreferencesIconImageCacheAdapterObservation
    MTRuntimePreferencesIconImageCacheAdapterObservation;

// Schedules one exact 21D61 Preferences.framework Hook. The hook is
// original-first and the selected UI-resource module owns lookup/decode/cache.
FOUNDATION_EXPORT BOOL MTPreferencesIconImageCacheAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    MTPreferencesAttachedControllerProvider attachedControllerProvider,
    NSError **error);

// Main-queue only. Reloads attached PSListController instances through the
// exact validated 21D61 Preferences.framework implementation.
FOUNDATION_EXPORT void MTPreferencesIconImageCacheAdapterRefresh(void);

NS_ASSUME_NONNULL_END
