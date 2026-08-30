#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTDialerImageResolver)(
    NSString *subject,
    id originalResult);
typedef BOOL (*MTDialerCompleteNumberSetResolver)(void);
typedef BOOL (*MTDialerButtonPreparation)(void);

typedef NS_ENUM(uint32_t, MTDialerButtonAdapterState) {
    MTDialerButtonAdapterStateDormant = 0,
    MTDialerButtonAdapterStateScheduled = 1,
    MTDialerButtonAdapterStateInstalled = 2,
    MTDialerButtonAdapterStateRejected = 10,
};

typedef struct MTDialerButtonAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) numberSourceCalls;
    _Atomic(uint64_t) numberNormalCalls;
    _Atomic(uint64_t) numberHighlightedCalls;
    _Atomic(uint64_t) circleAlphaCalls;
    _Atomic(uint64_t) circleSuppressions;
    _Atomic(uint64_t) callButtonCreations;
    _Atomic(uint64_t) callNormalReplacements;
    _Atomic(uint64_t) callOverlayRequests;
    _Atomic(uint64_t) callPressedReplacements;
    _Atomic(uint64_t) resolverMisses;
    _Atomic(uint64_t) contractRejects;
} MTDialerButtonAdapterObservation;

FOUNDATION_EXPORT MTDialerButtonAdapterObservation
    MTRuntimeDialerButtonAdapterObservation;

// Replaces the one inherited TelephonyUI number-art producer and its two
// native circle-alpha sources. The existing glyph layers, press transitions,
// layout, and UIControl lifecycle remain Apple-owned. The Dialer call button
// keeps PHBottomBarButton's factory and native pressed-overlay lifecycle while
// its complete legacy canvas lives in UIButton's background-image carrier and
// the independent stock foreground-image source is cleared for every state.
FOUNDATION_EXPORT BOOL MTDialerButtonAdapterSchedule(
    MTDialerImageResolver resolver,
    MTDialerCompleteNumberSetResolver completeNumberSetResolver,
    MTDialerButtonPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
