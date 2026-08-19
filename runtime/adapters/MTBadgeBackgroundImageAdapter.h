#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTBadgeBackgroundImageResolver)(
    id badgeView,
    id backgroundView,
    id _Nullable originalImage,
    BOOL *didReplace);
typedef void (*MTBadgeViewForgetter)(
    id badgeView,
    id _Nullable backgroundView);

typedef NS_ENUM(uint32_t, MTBadgeBackgroundImageAdapterState) {
    MTBadgeBackgroundImageAdapterStateDormant = 0,
    MTBadgeBackgroundImageAdapterStateScheduled = 1,
    MTBadgeBackgroundImageAdapterStateInstalled = 2,
    MTBadgeBackgroundImageAdapterStateRejected = 10,
};

typedef struct MTBadgeBackgroundImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) configureCalls;
    _Atomic(uint64_t) animatedConfigureCalls;
    _Atomic(uint64_t) reuseCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
} MTBadgeBackgroundImageAdapterObservation;

FOUNDATION_EXPORT MTBadgeBackgroundImageAdapterObservation
    MTRuntimeBadgeBackgroundImageAdapterObservation;

FOUNDATION_EXPORT BOOL MTBadgeBackgroundImageAdapterSchedule(
    MTBadgeBackgroundImageResolver resolver,
    MTBadgeViewForgetter forgetter,
    NSError **error);
FOUNDATION_EXPORT void MTBadgeBackgroundImageAdapterRefresh(void);

NS_ASSUME_NONNULL_END
