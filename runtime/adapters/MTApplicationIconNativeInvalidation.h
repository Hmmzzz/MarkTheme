#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, MTApplicationIconNativeInvalidationOwners) {
    MTApplicationIconNativeInvalidationOwnerLaunchServices = 1 << 0,
    MTApplicationIconNativeInvalidationOwnerNotificationImages = 1 << 1,
    MTApplicationIconNativeInvalidationOwnerPreferences = 1 << 2,
    MTApplicationIconNativeInvalidationOwnerShareSheet = 1 << 3,
};

typedef struct MTApplicationIconNativeInvalidationObservation {
    uint32_t schemaVersion;
    uint32_t reserved;
    _Atomic(uint64_t) requests;
    _Atomic(uint64_t) verifiedRequests;
    _Atomic(uint64_t) launchServicesSignals;
    _Atomic(uint64_t) notificationCacheClears;
    _Atomic(uint64_t) preferencesReloads;
    _Atomic(uint64_t) shareSheetCacheClears;
    _Atomic(uint64_t) shareSheetReloads;
    _Atomic(uint64_t) failures;
} MTApplicationIconNativeInvalidationObservation;

FOUNDATION_EXPORT MTApplicationIconNativeInvalidationObservation
    MTRuntimeApplicationIconNativeInvalidationObservation;

typedef void (^MTApplicationIconNativeInvalidationCompletion)(BOOL verified);

// Configures a process-local, no-Hook coordinator. It never returns or
// replaces image data. The caller selects only the native cache owners that
// exist in the resolved Runtime profile.
FOUNDATION_EXPORT BOOL MTApplicationIconNativeInvalidationConfigure(
    MTApplicationIconNativeInvalidationOwners owners,
    NSError **error);

// Exact installed application identities recovered from LaunchServices. This
// is exposed for low-frequency scope planning; it never mutates lsd state.
FOUNDATION_EXPORT NSSet<NSString *> *_Nullable
    MTApplicationIconNativeInvalidationInstalledBundleIdentifiers(void);

// Executes on the main queue. LaunchServices consumers receive Apple's local
// application-icon-change notification after the service StoreIndex barrier;
// owners without that signal use their sealed cache/reload methods. Completion
// means every live owner was handled, not that its later lazy image request has
// already rendered.
FOUNDATION_EXPORT void MTApplicationIconNativeInvalidationRefresh(
    MTApplicationIconNativeInvalidationCompletion completion);

// A non-nil set narrows the native LaunchServices signal to applications whose
// pixels changed between the previous and current Generation. Nil requests the
// correctness baseline for a global mask/overlay transition. Other owner modes
// ignore this set and still refresh only their active native owners.
FOUNDATION_EXPORT void
MTApplicationIconNativeInvalidationRefreshBundleIdentifiers(
    NSSet<NSString *> *_Nullable bundleIdentifiers,
    MTApplicationIconNativeInvalidationCompletion completion);

NS_ASSUME_NONNULL_END
