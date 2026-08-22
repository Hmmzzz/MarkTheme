#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

#import "MTRuntimeReplacement.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTNotificationIconAdapterState) {
    MTNotificationIconAdapterStateDormant = 0,
    MTNotificationIconAdapterStateScheduled = 1,
    MTNotificationIconAdapterStateInstalled = 2,
    MTNotificationIconAdapterStateClassUnavailable = 10,
    MTNotificationIconAdapterStateClassImageMismatch = 11,
    MTNotificationIconAdapterStateMethodTypeMismatch = 12,
    MTNotificationIconAdapterStateImplementationUnavailable = 13,
    MTNotificationIconAdapterStateResolverPreparationFailed = 14,
    MTNotificationIconAdapterStateOriginalUnavailable = 15,
};

typedef struct MTNotificationIconAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint32_t) installAttempts;
    uint32_t reserved;
    _Atomic(uint64_t) totalCalls;
    _Atomic(uint64_t) identityResults;
    _Atomic(uint64_t) replacementResults;
} MTNotificationIconAdapterObservation;

FOUNDATION_EXPORT MTNotificationIconAdapterObservation
    MTRuntimeNotificationIconAdapterObservation;

// Hooks the exact UserNotificationsUIKit content-provider boundary proven on
// iOS 17.3.1. Stock runs first. The application identity is recovered only
// through notificationRequest -> bulletin -> sectionID, and only the first
// UIImage in the returned icon array may be replaced. Every failed contract
// leaves the complete stock result untouched.
FOUNDATION_EXPORT BOOL MTNotificationIconAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error);

NS_ASSUME_NONNULL_END
