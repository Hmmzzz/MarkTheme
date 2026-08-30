#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct MTShareSheetActivityGlyphAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) requestCalls;
    _Atomic(uint64_t) deliveryCalls;
    _Atomic(uint64_t) applicationContexts;
    _Atomic(uint64_t) customContexts;
    _Atomic(uint64_t) nativeApplicationBridgeResults;
    _Atomic(uint64_t) replacements;
    _Atomic(uint64_t) providersTracked;
    _Atomic(uint64_t) contextMisses;
    _Atomic(uint64_t) contractRejects;
} MTShareSheetActivityGlyphAdapterObservation;

FOUNDATION_EXPORT MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation;

// Hooks SharingUI's central request and delivery boundaries. Request metadata
// supplies the live activity identity; delivery substitutes either UIActivity's
// native IconServices application image or one custom activity glyph before
// SFUIImageProvider commits the result to its native NSCache. No activity
// getter, proxy image getter, cell, or display-layer Hook remains.
FOUNDATION_EXPORT BOOL MTShareSheetActivityGlyphAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
