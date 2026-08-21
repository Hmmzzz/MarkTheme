#import "MTPreferencesApplicationIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTPreferencesABI.h"
#import "MTRuntimeABIReport.h"

#include <string.h>

static NSString *const MTAdapterID = @"preferences.application-icon-image";
static const char *const MTTargetClassName = "PSTableCell";
static const char *const MTTargetSelectorName = "getLazyIcon";
static const char *const MTIdentifierSelectorName = "getLazyIconID";
static const char *const MTMethodTypeEncoding = "@16@0:8";
static const uint32_t MTMaximumInstallAttempts = 40;
static const int64_t MTInstallRetryNanoseconds = 250 * NSEC_PER_MSEC;

typedef id (*MTPreferencesLazyIconFunction)(id, SEL);

MTPreferencesApplicationIconAdapterObservation
    MTRuntimePreferencesApplicationIconAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(
            MTPreferencesApplicationIconAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .identifierResults = ATOMIC_VAR_INIT(0),
        .identifierMisses = ATOMIC_VAR_INIT(0),
        .nilOriginalResults = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTPreferencesApplicationIconAdapterObservation) == 56,
    "The Preferences application-icon observation layout must remain fixed.");

static MTPreferencesLazyIconFunction MTOriginalGetLazyIcon;
static SEL MTGetLazyIconIDSelector;
static MTRuntimeReplacementResolver MTReplacementResolver;
static MTRuntimeReplacementPreparation MTReplacementPreparation;

static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static NSString *MTStateName(
    MTPreferencesApplicationIconAdapterState state) {
    switch (state) {
        case MTPreferencesApplicationIconAdapterStateDormant:
            return @"Dormant";
        case MTPreferencesApplicationIconAdapterStateScheduled:
            return @"Scheduled";
        case MTPreferencesApplicationIconAdapterStateInstalled:
            return @"Installed";
        case MTPreferencesApplicationIconAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTPreferencesApplicationIconAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTPreferencesApplicationIconAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTPreferencesApplicationIconAdapterStateImplementationImageMismatch:
            return @"ImplementationImageMismatch";
        case MTPreferencesApplicationIconAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTPreferencesApplicationIconAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
    }
    return @"Unknown";
}

static void MTSetState(MTPreferencesApplicationIconAdapterState state) {
    atomic_store_explicit(
        &MTRuntimePreferencesApplicationIconAdapterObservation.state,
        (uint32_t)state, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, (uint32_t)state, MTStateName(state));
}

static id MTHookedGetLazyIcon(id self, SEL selector) {
    id originalResult = MTOriginalGetLazyIcon(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesApplicationIconAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesApplicationIconAdapterObservation
                .nilOriginalResults,
            1, memory_order_relaxed);
    }
    id identifier = ((id (*)(id, SEL))objc_msgSend)(
        self, MTGetLazyIconIDSelector);
    if (![identifier isKindOfClass:NSString.class]) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesApplicationIconAdapterObservation
                .identifierMisses,
            1, memory_order_relaxed);
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesApplicationIconAdapterObservation
            .identifierResults,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        (NSString *)identifier, originalResult,
        MTReplacementResolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesApplicationIconAdapterObservation
                .replacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

static BOOL MTMethodMatches(Method method) {
    const char *typeEncoding =
        method == NULL ? NULL : method_getTypeEncoding(method);
    return typeEncoding != NULL &&
        strcmp(typeEncoding, MTMethodTypeEncoding) == 0;
}

static void MTAttemptInstallation(void) {
    uint32_t attempts = atomic_fetch_add_explicit(
        &MTRuntimePreferencesApplicationIconAdapterObservation
            .installAttempts,
        1, memory_order_relaxed) + 1;
    Class targetClass = objc_getClass(MTTargetClassName);
    SEL targetSelector = sel_registerName(MTTargetSelectorName);
    SEL identifierSelector = sel_registerName(MTIdentifierSelectorName);
    Method targetMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, targetSelector);
    Method identifierMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, identifierSelector);
    if (targetMethod == NULL || identifierMethod == NULL) {
        if (attempts < MTMaximumInstallAttempts) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              MTInstallRetryNanoseconds),
                dispatch_get_main_queue(), ^{
                    MTAttemptInstallation();
                });
            return;
        }
        MTSetState(
            MTPreferencesApplicationIconAdapterStateClassUnavailable);
        return;
    }

    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:PSTableCell", targetClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:PSTableCell",
        MTPreferencesClassMatchesExpectedImage(targetClass),
        @"Preferences", MTReportImageName(targetClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:PSTableCell.getLazyIcon",
        targetMethod, MTMethodTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:PSTableCell.getLazyIconID",
        identifierMethod, MTMethodTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:PSTableCell.getLazyIcon",
        method_getImplementation(targetMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:PSTableCell.getLazyIconID",
        method_getImplementation(identifierMethod));

    if (!MTPreferencesClassMatchesExpectedImage(targetClass)) {
        MTSetState(
            MTPreferencesApplicationIconAdapterStateClassImageMismatch);
        return;
    }
    if (!MTMethodMatches(targetMethod) || !MTMethodMatches(identifierMethod)) {
        MTSetState(
            MTPreferencesApplicationIconAdapterStateMethodTypeMismatch);
        return;
    }
    IMP targetImplementation = method_getImplementation(targetMethod);
    IMP identifierImplementation = method_getImplementation(identifierMethod);
    if (!MTPreferencesImplementationMatchesExpectedImage(
            targetImplementation) ||
        !MTPreferencesImplementationMatchesExpectedImage(
            identifierImplementation)) {
        MTSetState(
            MTPreferencesApplicationIconAdapterStateImplementationImageMismatch);
        return;
    }
    if (!MTReplacementPreparation()) {
        MTSetState(
            MTPreferencesApplicationIconAdapterStateResolverPreparationFailed);
        return;
    }

    MTOriginalGetLazyIcon =
        (MTPreferencesLazyIconFunction)targetImplementation;
    MTGetLazyIconIDSelector = identifierSelector;
    MSHookMessageEx(targetClass, targetSelector,
                    (IMP)MTHookedGetLazyIcon,
                    (IMP *)&MTOriginalGetLazyIcon);
    if (MTOriginalGetLazyIcon == NULL) {
        MTOriginalGetLazyIcon =
            (MTPreferencesLazyIconFunction)targetImplementation;
        MTSetState(
            MTPreferencesApplicationIconAdapterStateOriginalUnavailable);
        return;
    }
    MTSetState(MTPreferencesApplicationIconAdapterStateInstalled);
}

BOOL MTPreferencesApplicationIconAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTPreferencesApplicationIconAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimePreferencesApplicationIconAdapterObservation.state,
            &expected,
            MTPreferencesApplicationIconAdapterStateScheduled,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected ==
                MTPreferencesApplicationIconAdapterStateScheduled ||
            expected == MTPreferencesApplicationIconAdapterStateInstalled;
    }
    MTReplacementResolver = resolver;
    MTReplacementPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTPreferencesApplicationIconAdapterStateScheduled,
        @"Scheduled");
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTAttemptInstallation();
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                MTAttemptInstallation();
            }
        });
    }
    return YES;
}
