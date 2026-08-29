#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MTCalendarApplicationIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) generatedCalls;
    _Atomic(uint64_t) unmaskedCalls;
    _Atomic(uint64_t) appearanceReplacements;
    _Atomic(uint64_t) sourceReplacements;
} MTCalendarApplicationIconAdapterObservation;

FOUNDATION_EXPORT MTCalendarApplicationIconAdapterObservation
    MTRuntimeCalendarApplicationIconAdapterObservation;

// Dedicated live-Calendar boundary. It does not interpose SBApplicationIcon,
// SBIconImageCache, SBIconImageView, transitions, or any ordinary application
// icon producer now owned by IconServices.
FOUNDATION_EXPORT BOOL MTCalendarApplicationIconAdapterInstall(
    MTRuntimeReplacementResolver appearanceResolver,
    MTRuntimeReplacementResolver sourceResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
