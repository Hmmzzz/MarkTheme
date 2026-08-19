#import "MTPreferencesIconImageCacheAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#import "MTPreferencesABI.h"
#import "MTRuntimeABIReport.h"

#include <string.h>

static NSString *const MTAdapterID = @"preferences.icon-image-cache";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTPreferencesTargetClassName = "PKIconImageCache";
static const char *const MTPreferencesTargetSelectorName = "imageForKey:";
static const char *const MTPreferencesTargetTypeEncoding = "@24@0:8@16";
static const char *const MTPreferencesRefreshClassName = "PSListController";
static const char *const MTPreferencesRefreshSelectorName = "reloadSpecifiers";
static const char *const MTPreferencesRefreshTypeEncoding = "v16@0:8";
static const uint32_t MTPreferencesMaximumInstallAttempts = 40;
static const int64_t MTPreferencesInstallRetryNanoseconds =
    250 * NSEC_PER_MSEC;

typedef id (*MTPreferencesImageForKeyFunction)(id, SEL, id);
typedef void (*MTPreferencesReloadSpecifiersFunction)(id, SEL);

MTPreferencesIconImageCacheAdapterObservation
    MTRuntimePreferencesIconImageCacheAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(
            MTPreferencesIconImageCacheAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .stringKeys = ATOMIC_VAR_INIT(0),
        .nilOriginalResults = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshPasses = ATOMIC_VAR_INIT(0),
        .refreshRecipients = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTPreferencesIconImageCacheAdapterObservation) == 72,
    "The Preferences ProcessAdapter observation layout must remain fixed.");

static MTPreferencesImageForKeyFunction MTPreferencesOriginalImageForKey;
static Class MTPreferencesRefreshControllerClass;
static SEL MTPreferencesRefreshSelector;
static MTPreferencesReloadSpecifiersFunction MTPreferencesReloadSpecifiers;
static MTRuntimeReplacementResolver MTPreferencesReplacementResolver;
static MTRuntimeReplacementPreparation MTPreferencesReplacementPreparation;
static MTPreferencesAttachedControllerProvider
    MTPreferencesControllerProvider;

static NSString *MTPreferencesStateName(
    MTPreferencesIconImageCacheAdapterState state) {
    switch (state) {
        case MTPreferencesIconImageCacheAdapterStateDormant:
            return @"Dormant";
        case MTPreferencesIconImageCacheAdapterStateScheduled:
            return @"Scheduled";
        case MTPreferencesIconImageCacheAdapterStateInstalled:
            return @"Installed";
        case MTPreferencesIconImageCacheAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTPreferencesIconImageCacheAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTPreferencesIconImageCacheAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTPreferencesIconImageCacheAdapterStateImplementationImageMismatch:
            return @"ImplementationImageMismatch";
        case MTPreferencesIconImageCacheAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTPreferencesIconImageCacheAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
        case MTPreferencesIconImageCacheAdapterStateRefreshClassUnavailable:
            return @"RefreshClassUnavailable";
        case MTPreferencesIconImageCacheAdapterStateRefreshClassImageMismatch:
            return @"RefreshClassImageMismatch";
        case MTPreferencesIconImageCacheAdapterStateRefreshMethodTypeMismatch:
            return @"RefreshMethodTypeMismatch";
        case MTPreferencesIconImageCacheAdapterStateRefreshImplementationImageMismatch:
            return @"RefreshImplementationImageMismatch";
    }
    return @"Unknown";
}

static void MTPreferencesSetState(
    MTPreferencesIconImageCacheAdapterState state) {
    atomic_store_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.state,
        (uint32_t)state, memory_order_release);
    // Every state change is recorded so a user report names the exact gate
    // that kept this surface stock on an untested device or build.
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, (uint32_t)state, MTPreferencesStateName(state));
}

static id MTPreferencesHookedImageForKey(id self,
                                         SEL selector,
                                         id key) {
    id originalResult =
        MTPreferencesOriginalImageForKey(self, selector, key);
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesIconImageCacheAdapterObservation
                .nilOriginalResults,
            1, memory_order_relaxed);
    }
    if (![key isKindOfClass:NSString.class]) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.stringKeys,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        (NSString *)key, originalResult,
        MTPreferencesReplacementResolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesIconImageCacheAdapterObservation
                .replacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

void MTPreferencesIconImageCacheAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.refreshRequests,
        1, memory_order_relaxed);

    if (atomic_load_explicit(
            &MTRuntimePreferencesIconImageCacheAdapterObservation.state,
            memory_order_acquire) !=
            MTPreferencesIconImageCacheAdapterStateInstalled) {
        return;
    }

    NSArray<id> *attachedControllers = MTPreferencesControllerProvider();
    uint64_t recipientCount = 0;
    for (id controller in attachedControllers) {
        if (![controller isKindOfClass:MTPreferencesRefreshControllerClass]) {
            continue;
        }
        MTPreferencesReloadSpecifiers(
            controller, MTPreferencesRefreshSelector);
        recipientCount++;
    }
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.refreshRecipients,
        recipientCount, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.refreshPasses,
        1, memory_order_relaxed);
}

static void MTPreferencesAttemptInstallation(void) {
    uint32_t attempts = atomic_fetch_add_explicit(
        &MTRuntimePreferencesIconImageCacheAdapterObservation.installAttempts,
        1, memory_order_relaxed) + 1;
    Class targetClass = objc_getClass(MTPreferencesTargetClassName);
    SEL targetSelector = sel_registerName(MTPreferencesTargetSelectorName);
    Method targetMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, targetSelector);
    Class refreshClass = objc_getClass(MTPreferencesRefreshClassName);
    SEL refreshSelector = sel_registerName(MTPreferencesRefreshSelectorName);
    Method refreshMethod = refreshClass == Nil ? NULL :
        class_getInstanceMethod(refreshClass, refreshSelector);
    if (targetMethod == NULL || refreshMethod == NULL) {
        if (attempts < MTPreferencesMaximumInstallAttempts) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              MTPreferencesInstallRetryNanoseconds),
                dispatch_get_main_queue(), ^{
                    MTPreferencesAttemptInstallation();
                });
            return;
        }
        MTPreferencesSetState(
            targetMethod == NULL
                ? MTPreferencesIconImageCacheAdapterStateClassUnavailable
                : MTPreferencesIconImageCacheAdapterStateRefreshClassUnavailable);
        return;
    }
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:PKIconImageCache", targetClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:PSListController", refreshClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:PKIconImageCache",
        MTPreferencesClassMatchesExpectedImage(targetClass),
        @"Preferences", MTReportImageName(targetClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:PKIconImageCache.imageForKey:",
        targetMethod, MTPreferencesTargetTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:PKIconImageCache.imageForKey:",
        method_getImplementation(targetMethod));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:PSListController",
        MTPreferencesClassMatchesExpectedImage(refreshClass),
        @"Preferences", MTReportImageName(refreshClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:PSListController.reloadSpecifiers",
        refreshMethod, MTPreferencesRefreshTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:PSListController.reloadSpecifiers",
        method_getImplementation(refreshMethod));
    if (!MTPreferencesClassMatchesExpectedImage(targetClass)) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateClassImageMismatch);
        return;
    }
    const char *typeEncoding = method_getTypeEncoding(targetMethod);
    if (typeEncoding == NULL ||
        strcmp(typeEncoding, MTPreferencesTargetTypeEncoding) != 0) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateMethodTypeMismatch);
        return;
    }
    IMP targetImplementation = method_getImplementation(targetMethod);
    if (!MTPreferencesImplementationMatchesExpectedImage(
            targetImplementation)) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateImplementationImageMismatch);
        return;
    }
    if (!MTPreferencesClassMatchesExpectedImage(refreshClass)) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateRefreshClassImageMismatch);
        return;
    }
    const char *refreshTypeEncoding = method_getTypeEncoding(refreshMethod);
    if (refreshTypeEncoding == NULL ||
        strcmp(refreshTypeEncoding, MTPreferencesRefreshTypeEncoding) != 0) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateRefreshMethodTypeMismatch);
        return;
    }
    IMP refreshImplementation = method_getImplementation(refreshMethod);
    if (!MTPreferencesImplementationMatchesExpectedImage(
            refreshImplementation)) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateRefreshImplementationImageMismatch);
        return;
    }
    if (!MTPreferencesReplacementPreparation()) {
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateResolverPreparationFailed);
        return;
    }

    MTPreferencesOriginalImageForKey =
        (MTPreferencesImageForKeyFunction)targetImplementation;
    MTPreferencesRefreshControllerClass = refreshClass;
    MTPreferencesRefreshSelector = refreshSelector;
    MTPreferencesReloadSpecifiers =
        (MTPreferencesReloadSpecifiersFunction)refreshImplementation;
    MSHookMessageEx(targetClass, targetSelector,
                    (IMP)MTPreferencesHookedImageForKey,
                    (IMP *)&MTPreferencesOriginalImageForKey);
    if (MTPreferencesOriginalImageForKey == NULL) {
        MTPreferencesOriginalImageForKey =
            (MTPreferencesImageForKeyFunction)targetImplementation;
        MTPreferencesSetState(
            MTPreferencesIconImageCacheAdapterStateOriginalUnavailable);
        return;
    }
    MTPreferencesSetState(
        MTPreferencesIconImageCacheAdapterStateInstalled);
}

BOOL MTPreferencesIconImageCacheAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    MTPreferencesAttachedControllerProvider attachedControllerProvider,
    NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL ||
        attachedControllerProvider == NULL) return NO;
    uint32_t expected = MTPreferencesIconImageCacheAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimePreferencesIconImageCacheAdapterObservation.state,
            &expected,
            MTPreferencesIconImageCacheAdapterStateScheduled,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected == MTPreferencesIconImageCacheAdapterStateScheduled ||
            expected == MTPreferencesIconImageCacheAdapterStateInstalled;
    }
    MTPreferencesReplacementResolver = resolver;
    MTPreferencesReplacementPreparation = preparation;
    MTPreferencesControllerProvider = attachedControllerProvider;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTPreferencesIconImageCacheAdapterStateScheduled,
        @"Scheduled");
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTPreferencesAttemptInstallation();
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                MTPreferencesAttemptInstallation();
            }
        });
    }
    return YES;
}
