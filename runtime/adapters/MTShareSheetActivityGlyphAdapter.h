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
} MTShareSheetActivityGlyphAdapterObservation;

FOUNDATION_EXPORT MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation;

// Themes only custom activity glyphs. Whenever identity recovery proves an
// application bundle, the stock result is returned unchanged so its image is
// supplied by the new IconServices source.
FOUNDATION_EXPORT BOOL MTShareSheetActivityGlyphAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
