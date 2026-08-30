#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*MTIconShadowViewResolver)(id iconView, id iconImageView);
typedef void (*MTIconShadowViewForgetter)(
    id iconView,
    id _Nullable iconImageView);

typedef NS_ENUM(uint32_t, MTIconShadowViewAdapterState) {
    MTIconShadowViewAdapterStateDormant = 0,
    MTIconShadowViewAdapterStateScheduled = 1,
    MTIconShadowViewAdapterStateInstalled = 2,
    MTIconShadowViewAdapterStateRejected = 10,
};

typedef struct MTIconShadowViewAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) configureCalls;
    _Atomic(uint64_t) imageInfoCalls;
    _Atomic(uint64_t) destroyCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) appliedResults;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
    _Atomic(uint64_t) applicationIconRefreshRequests;
    _Atomic(uint64_t) applicationIconCachePurges;
    _Atomic(uint64_t) applicationIconObserverSignals;
    _Atomic(uint64_t) applicationIconRefreshFailures;
} MTIconShadowViewAdapterObservation;

FOUNDATION_EXPORT MTIconShadowViewAdapterObservation
    MTRuntimeIconShadowViewAdapterObservation;

FOUNDATION_EXPORT BOOL MTIconShadowViewAdapterSchedule(
    MTIconShadowViewResolver resolver,
    MTIconShadowViewForgetter forgetter,
    NSError **error);
FOUNDATION_EXPORT void MTIconShadowViewAdapterRefresh(void);

// Invalidates only SpringBoardHome's native image-cache owner for currently
// visible application icons. No image is returned or replaced; after the
// IconServices client cache has been cleared, the native purge and observer
// notification force SpringBoard to demand the new service-produced pixels.
FOUNDATION_EXPORT BOOL
MTIconShadowViewAdapterRefreshVisibleApplicationIcons(
    NSSet<NSString *> *_Nullable bundleIdentifiers,
    NSUInteger *_Nullable cachePurgeCount,
    NSUInteger *_Nullable observerSignalCount);

NS_ASSUME_NONNULL_END
