#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef CGImageRef _Nullable (*MTCalendarUIKitSourceResolver)(
    NSDateComponents *dateComponents,
    NSCalendar *calendar,
    NSInteger format,
    CGSize pointSize,
    CGFloat scale);

typedef NS_ENUM(uint32_t, MTCalendarUIKitSourceAdapterState) {
    MTCalendarUIKitSourceAdapterStateDormant = 0,
    MTCalendarUIKitSourceAdapterStateScheduled = 1,
    MTCalendarUIKitSourceAdapterStateInstalled = 2,
    MTCalendarUIKitSourceAdapterStateRejected = 10,
};

typedef struct MTCalendarUIKitSourceAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) outOfScopeCalls;
    _Atomic(uint64_t) originalFailures;
    _Atomic(uint64_t) resolverMisses;
    _Atomic(uint64_t) rasterRejects;
    _Atomic(uint64_t) replacements;
} MTCalendarUIKitSourceAdapterObservation;

FOUNDATION_EXPORT MTCalendarUIKitSourceAdapterObservation
    MTRuntimeCalendarUIKitSourceAdapterObservation;

// Hooks CalendarUIKit's process-local application-icon raster format only.
// The resolver returns a +1 CGImage matching CalendarUIKit's private ownership
// convention; CUIKIcon and downstream descriptor/image-bag behavior remain
// native. Other CalendarUIKit formats pass through untouched.
FOUNDATION_EXPORT BOOL MTCalendarUIKitSourceAdapterSchedule(
    MTCalendarUIKitSourceResolver resolver,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
