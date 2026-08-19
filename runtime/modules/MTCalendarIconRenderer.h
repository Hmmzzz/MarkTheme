#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTCalendarIconConfiguration;
@class MTCalendarIconContent;
@class UIImage;

NS_ASSUME_NONNULL_BEGIN

typedef struct MTCalendarIconRendererObservation {
    uint32_t schemaVersion;
    _Atomic(uint64_t) renderAttempts;
    _Atomic(uint64_t) renderSuccesses;
    _Atomic(uint64_t) renderFailures;
} MTCalendarIconRendererObservation;

FOUNDATION_EXPORT MTCalendarIconRendererObservation
    MTRuntimeCalendarIconRendererObservation;

// Composites the dynamic labels over an already-decoded themed background.
// The caller retains only the returned image in its shared bounded cache.
FOUNDATION_EXPORT UIImage * _Nullable MTCalendarIconRenderBackground(
    UIImage *background,
    MTCalendarIconConfiguration *configuration,
    MTCalendarIconContent *content);

NS_ASSUME_NONNULL_END
