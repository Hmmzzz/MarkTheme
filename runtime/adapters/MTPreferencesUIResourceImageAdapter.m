#import "MTPreferencesUIResourceImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "MTPreferencesABI.h"
#import "MTRuntimeABIReport.h"

#include <stdbool.h>
#include <string.h>

static NSString *const MTAdapterID = @"preferences.ui-resource-image";

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

typedef id (*MTPreferencesImageForKeyFunction)(id, SEL, id);

MTPreferencesUIResourceImageAdapterObservation
    MTRuntimePreferencesUIResourceImageAdapterObservation = {
        .schemaVersion = 3,
        .state = ATOMIC_VAR_INIT(
            MTPreferencesUIResourceImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .stringKeys = ATOMIC_VAR_INIT(0),
        .nilOriginalResults = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTPreferencesUIResourceImageAdapterObservation) == 48,
    "The Preferences ProcessAdapter observation layout must remain fixed.");

static MTPreferencesImageForKeyFunction MTPreferencesOriginalImageForKey;
static MTRuntimeReplacementResolver MTPreferencesReplacementResolver;
static MTRuntimeReplacementPreparation MTPreferencesReplacementPreparation;
static _Atomic(bool) MTPreferencesInstallPassScheduled = false;

static NSString *MTPreferencesStateName(
    MTPreferencesUIResourceImageAdapterState state) {
    switch (state) {
        case MTPreferencesUIResourceImageAdapterStateDormant:
            return @"Dormant";
        case MTPreferencesUIResourceImageAdapterStateScheduled:
            return @"Scheduled";
        case MTPreferencesUIResourceImageAdapterStateInstalled:
            return @"Installed";
        case MTPreferencesUIResourceImageAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTPreferencesUIResourceImageAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTPreferencesUIResourceImageAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTPreferencesUIResourceImageAdapterStateImplementationImageMismatch:
            return @"ImplementationImageMismatch";
        case MTPreferencesUIResourceImageAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTPreferencesUIResourceImageAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
    }
    return @"Unknown";
}

static void MTPreferencesSetState(
    MTPreferencesUIResourceImageAdapterState state) {
    atomic_store_explicit(
        &MTRuntimePreferencesUIResourceImageAdapterObservation.state,
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
        &MTRuntimePreferencesUIResourceImageAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesUIResourceImageAdapterObservation
                .nilOriginalResults,
            1, memory_order_relaxed);
    }
    if (![key isKindOfClass:NSString.class]) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesUIResourceImageAdapterObservation.stringKeys,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        (NSString *)key, originalResult,
        MTPreferencesReplacementResolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesUIResourceImageAdapterObservation
                .replacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

static void MTPreferencesAttemptInstallation(void);

static void MTPreferencesScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimePreferencesUIResourceImageAdapterObservation.state,
            memory_order_acquire) !=
        MTPreferencesUIResourceImageAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTPreferencesInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTPreferencesInstallPassScheduled, false,
            memory_order_release);
        MTPreferencesAttemptInstallation();
    });
}

static void MTPreferencesRuntimeImageAdded(
    const struct mach_header *header,
    intptr_t slide) {
    (void)header;
    (void)slide;
    MTPreferencesScheduleInstallPass();
}

static void MTPreferencesAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTPreferencesScheduleInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimePreferencesUIResourceImageAdapterObservation.state,
            memory_order_acquire) !=
        MTPreferencesUIResourceImageAdapterStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesUIResourceImageAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class targetClass = objc_getClass(MTPreferencesTargetClassName);
    SEL targetSelector = sel_registerName(MTPreferencesTargetSelectorName);
    Method targetMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, targetSelector);
    if (targetMethod == NULL) return;
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:PKIconImageCache", targetClass != Nil);
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
    if (!MTPreferencesClassMatchesExpectedImage(targetClass)) {
        MTPreferencesSetState(
            MTPreferencesUIResourceImageAdapterStateClassImageMismatch);
        return;
    }
    const char *typeEncoding = method_getTypeEncoding(targetMethod);
    if (typeEncoding == NULL ||
        strcmp(typeEncoding, MTPreferencesTargetTypeEncoding) != 0) {
        MTPreferencesSetState(
            MTPreferencesUIResourceImageAdapterStateMethodTypeMismatch);
        return;
    }
    IMP targetImplementation = method_getImplementation(targetMethod);
    if (!MTPreferencesImplementationMatchesExpectedImage(
            targetImplementation)) {
        MTPreferencesSetState(
            MTPreferencesUIResourceImageAdapterStateImplementationImageMismatch);
        return;
    }
    if (!MTPreferencesReplacementPreparation()) {
        MTPreferencesSetState(
            MTPreferencesUIResourceImageAdapterStateResolverPreparationFailed);
        return;
    }

    MTPreferencesOriginalImageForKey =
        (MTPreferencesImageForKeyFunction)targetImplementation;
    MSHookMessageEx(targetClass, targetSelector,
                    (IMP)MTPreferencesHookedImageForKey,
                    (IMP *)&MTPreferencesOriginalImageForKey);
    if (MTPreferencesOriginalImageForKey == NULL) {
        MTPreferencesOriginalImageForKey =
            (MTPreferencesImageForKeyFunction)targetImplementation;
        MTPreferencesSetState(
            MTPreferencesUIResourceImageAdapterStateOriginalUnavailable);
        return;
    }
    MTPreferencesSetState(
        MTPreferencesUIResourceImageAdapterStateInstalled);
}

BOOL MTPreferencesUIResourceImageAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTPreferencesUIResourceImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimePreferencesUIResourceImageAdapterObservation.state,
            &expected,
            MTPreferencesUIResourceImageAdapterStateScheduled,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected == MTPreferencesUIResourceImageAdapterStateScheduled ||
            expected == MTPreferencesUIResourceImageAdapterStateInstalled;
    }
    MTPreferencesReplacementResolver = resolver;
    MTPreferencesReplacementPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTPreferencesUIResourceImageAdapterStateScheduled,
        @"Scheduled");
    _dyld_register_func_for_add_image(MTPreferencesRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTPreferencesAttemptInstallation();
        }
    } else {
        MTPreferencesScheduleInstallPass();
    }
    return YES;
}
