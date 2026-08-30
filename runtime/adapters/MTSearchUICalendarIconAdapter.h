#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTSearchUICalendarSurfaceResolver)(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale,
    id _Nullable originalResult);

typedef struct MTSearchUICalendarIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) replacements;
    _Atomic(uint64_t) trackedImages;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshInvalidations;
} MTSearchUICalendarIconAdapterObservation;

FOUNDATION_EXPORT MTSearchUICalendarIconAdapterObservation
    MTRuntimeSearchUICalendarIconAdapterObservation;

// Applies only SearchUI's final mask/overlay semantics. Raw dynamic Calendar
// pixels come from CalendarUIKit's shared source adapter, while ordinary
// SearchUIAppIconImage requests remain fully native.
FOUNDATION_EXPORT BOOL MTSearchUICalendarIconAdapterSchedule(
    MTSearchUICalendarSurfaceResolver resolver,
    BOOL (*preparation)(void),
    NSError **error);

FOUNDATION_EXPORT void MTSearchUICalendarIconAdapterRefresh(void);

NS_ASSUME_NONNULL_END
