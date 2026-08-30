#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTCalendarApplicationAppearanceResolver)(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale,
    id _Nullable originalResult);

typedef struct MTCalendarApplicationIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) generatedCalls;
    _Atomic(uint64_t) appearanceReplacements;
} MTCalendarApplicationIconAdapterObservation;

FOUNDATION_EXPORT MTCalendarApplicationIconAdapterObservation
    MTRuntimeCalendarApplicationIconAdapterObservation;

// Final SpringBoard appearance semantics only. Raw Calendar pixels are owned
// by MTCalendarUIKitSourceAdapter; unmaskedIconImageWithInfo: stays native.
FOUNDATION_EXPORT BOOL MTCalendarApplicationIconAdapterInstall(
    MTCalendarApplicationAppearanceResolver appearanceResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
