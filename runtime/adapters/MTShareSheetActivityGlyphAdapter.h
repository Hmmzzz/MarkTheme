#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MTShareSheetActivityGlyphAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) applicationActivitiesPreserved;
    _Atomic(uint64_t) customActivityIdentities;
    _Atomic(uint64_t) replacements;
    _Atomic(uint64_t) nativeApplicationBridgeRequests;
    _Atomic(uint64_t) nativeApplicationBridgeResults;
    _Atomic(uint64_t) providerRequestsTracked;
} MTShareSheetActivityGlyphAdapterObservation;

FOUNDATION_EXPORT MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation;

// Themes only custom activity glyphs. Every activity with a verified owning
// application bundle is bridged through UIActivity's own native IconServices
// factory, including Photos' Mail/Messages wrappers and application-extension
// activities. The provider request hook records cache ownership only and
// returns Apple's original result unchanged.
FOUNDATION_EXPORT BOOL MTShareSheetActivityGlyphAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
