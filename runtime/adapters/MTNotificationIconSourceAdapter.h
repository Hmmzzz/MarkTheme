#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTNotificationIconSourceAdapterState) {
    MTNotificationIconSourceAdapterStateDormant = 0,
    MTNotificationIconSourceAdapterStateScheduled = 1,
    MTNotificationIconSourceAdapterStateInstalled = 2,
    MTNotificationIconSourceAdapterStateClassImageMismatch = 10,
    MTNotificationIconSourceAdapterStateMethodTypeMismatch = 11,
    MTNotificationIconSourceAdapterStateImplementationUnavailable = 12,
    MTNotificationIconSourceAdapterStateIdentityRouteUnavailable = 13,
    MTNotificationIconSourceAdapterStateResolverPreparationFailed = 14,
    MTNotificationIconSourceAdapterStateOriginalUnavailable = 15,
};

typedef struct MTNotificationIconSourceAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) identityResults;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) mappedCacheClears;
    _Atomic(uint64_t) contractRejects;
} MTNotificationIconSourceAdapterObservation;

FOUNDATION_EXPORT MTNotificationIconSourceAdapterObservation
    MTRuntimeNotificationIconSourceAdapterObservation;

// UserNotificationsUIKit materializes application icons into its own mapped
// image cache instead of asking IconServices again at notification display
// time. This installs one original-first source-boundary bridge: identity is
// recovered from the semantic request provider and only the first UIImage in
// its icon result may be replaced. No notification view or layout is Hooked.
FOUNDATION_EXPORT BOOL MTNotificationIconSourceAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
