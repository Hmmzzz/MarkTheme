#import "MTNotificationIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"

#include <string.h>

#define MT_ADAPTER_ID @"springboard.notification-icon"
#define MT_TARGET_CLASS "NCNotificationRequestContentProvider"
#define MT_REQUEST_CLASS "NCNotificationRequest"
#define MT_BULLETIN_CLASS "BBBulletin"
#define MT_ICONS_SELECTOR "icons"
#define MT_REQUEST_SELECTOR "notificationRequest"
#define MT_BULLETIN_SELECTOR "bulletin"
#define MT_SECTION_SELECTOR "sectionID"
#define MT_GETTER_ENCODING "@16@0:8"
#define MT_UNUIKIT_IMAGE \
    "/System/Library/PrivateFrameworks/" \
    "UserNotificationsUIKit.framework/UserNotificationsUIKit"
#define MT_MAX_INSTALL_ATTEMPTS 80
#define MT_INSTALL_RETRY_NS (250 * NSEC_PER_MSEC)

typedef id (*MTObjectGetterFunction)(id, SEL);

MTNotificationIconAdapterObservation
    MTRuntimeNotificationIconAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTNotificationIconAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .identityResults = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTNotificationIconAdapterObservation) == 40,
    "The notification-icon observation layout must remain fixed.");

static struct {
    Class requestClass;
    Class bulletinClass;
    Class imageClass;
    SEL requestSelector;
    SEL bulletinSelector;
    SEL sectionSelector;
    MTObjectGetterFunction originalIcons;
    MTObjectGetterFunction requestGetter;
    MTObjectGetterFunction bulletinGetter;
    MTObjectGetterFunction sectionGetter;
    MTRuntimeReplacementResolver resolver;
    MTRuntimeReplacementPreparation preparation;
} MTN;

static NSString *MTStateName(MTNotificationIconAdapterState state) {
    switch (state) {
        case MTNotificationIconAdapterStateDormant: return @"Dormant";
        case MTNotificationIconAdapterStateScheduled: return @"Scheduled";
        case MTNotificationIconAdapterStateInstalled: return @"Installed";
        case MTNotificationIconAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTNotificationIconAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTNotificationIconAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTNotificationIconAdapterStateImplementationUnavailable:
            return @"ImplementationUnavailable";
        case MTNotificationIconAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTNotificationIconAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
    }
    return @"Unknown";
}

static void MTSetState(MTNotificationIconAdapterState state) {
    atomic_store_explicit(
        &MTRuntimeNotificationIconAdapterObservation.state,
        (uint32_t)state, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MT_ADAPTER_ID, (uint32_t)state, MTStateName(state));
}

static NSString *MTApplicationBundleIdentifier(id provider) {
    id request = MTN.requestGetter(provider, MTN.requestSelector);
    if (![request isKindOfClass:MTN.requestClass]) return nil;
    id bulletin = MTN.bulletinGetter(request, MTN.bulletinSelector);
    if (![bulletin isKindOfClass:MTN.bulletinClass]) return nil;
    id sectionID = MTN.sectionGetter(bulletin, MTN.sectionSelector);
    return [sectionID isKindOfClass:NSString.class] &&
        [(NSString *)sectionID length] > 0 ? sectionID : nil;
}

static id MTHookedIcons(id self, SEL selector) {
    id originalResult = MTN.originalIcons(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (![originalResult isKindOfClass:NSArray.class] ||
        [(NSArray *)originalResult count] == 0) {
        return originalResult;
    }
    id originalIcon = [(NSArray *)originalResult objectAtIndex:0];
    if (![originalIcon isKindOfClass:MTN.imageClass]) {
        return originalResult;
    }
    NSString *bundleIdentifier = MTApplicationBundleIdentifier(self);
    if (bundleIdentifier.length == 0) {
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconAdapterObservation.identityResults,
        1, memory_order_relaxed);
    id replacement = MTN.resolver(
        bundleIdentifier, originalIcon);
    if (replacement == nil || replacement == originalIcon) {
        return originalResult;
    }
    NSMutableArray *icons = [(NSArray *)originalResult mutableCopy];
    if (icons == nil) return originalResult;
    icons[0] = replacement;
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconAdapterObservation.replacementResults,
        1, memory_order_relaxed);
    return icons;
}

static void MTAttemptInstallation(void) {
    uint32_t attempts = atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconAdapterObservation.installAttempts,
        1, memory_order_relaxed) + 1;
    Class targetClass = objc_getClass(MT_TARGET_CLASS);
    Class requestClass = objc_getClass(MT_REQUEST_CLASS);
    Class bulletinClass = objc_getClass(MT_BULLETIN_CLASS);
    Class imageClass = objc_getClass("UIImage");
    SEL iconsSelector = sel_registerName(MT_ICONS_SELECTOR);
    SEL requestSelector = sel_registerName(MT_REQUEST_SELECTOR);
    SEL bulletinSelector = sel_registerName(MT_BULLETIN_SELECTOR);
    SEL sectionIDSelector = sel_registerName(MT_SECTION_SELECTOR);
    Method iconsMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, iconsSelector);
    Method requestMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, requestSelector);
    Method bulletinMethod = requestClass == Nil ? NULL :
        class_getInstanceMethod(requestClass, bulletinSelector);
    Method sectionIDMethod = bulletinClass == Nil ? NULL :
        class_getInstanceMethod(bulletinClass, sectionIDSelector);
    if (imageClass == Nil || iconsMethod == NULL || requestMethod == NULL ||
        bulletinMethod == NULL || sectionIDMethod == NULL) {
        if (attempts < MT_MAX_INSTALL_ATTEMPTS) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              MT_INSTALL_RETRY_NS),
                dispatch_get_main_queue(), ^{
                    MTAttemptInstallation();
                });
            return;
        }
        MTSetState(MTNotificationIconAdapterStateClassUnavailable);
        return;
    }

    BOOL targetImageMatches = MTRuntimeClassMatchesImagePath(
        targetClass, MT_UNUIKIT_IMAGE);
    Method methods[] = {
        iconsMethod, requestMethod, bulletinMethod, sectionIDMethod,
    };
    BOOL methodTypesMatch = YES;
    BOOL implementationsResolve = YES;
    for (NSUInteger index = 0;
         index < sizeof(methods) / sizeof(methods[0]); index++) {
        const char *encoding = method_getTypeEncoding(methods[index]);
        methodTypesMatch = encoding != NULL &&
            strcmp(encoding, MT_GETTER_ENCODING) == 0 &&
            methodTypesMatch;
        implementationsResolve = MTRuntimeImplementationResolves(
            method_getImplementation(methods[index])) &&
            implementationsResolve;
    }
    if (!targetImageMatches) {
        MTSetState(MTNotificationIconAdapterStateClassImageMismatch);
        return;
    }
    if (!methodTypesMatch) {
        MTSetState(MTNotificationIconAdapterStateMethodTypeMismatch);
        return;
    }
    if (!implementationsResolve) {
        MTSetState(
            MTNotificationIconAdapterStateImplementationUnavailable);
        return;
    }
    if (!MTN.preparation()) {
        MTSetState(
            MTNotificationIconAdapterStateResolverPreparationFailed);
        return;
    }

    MTN.requestClass = requestClass;
    MTN.bulletinClass = bulletinClass;
    MTN.imageClass = imageClass;
    MTN.requestSelector = requestSelector;
    MTN.bulletinSelector = bulletinSelector;
    MTN.sectionSelector = sectionIDSelector;
    MTN.originalIcons =
        (MTObjectGetterFunction)method_getImplementation(iconsMethod);
    MTN.requestGetter =
        (MTObjectGetterFunction)method_getImplementation(requestMethod);
    MTN.bulletinGetter =
        (MTObjectGetterFunction)method_getImplementation(bulletinMethod);
    MTN.sectionGetter =
        (MTObjectGetterFunction)method_getImplementation(sectionIDMethod);
    MSHookMessageEx(targetClass, iconsSelector,
                    (IMP)MTHookedIcons, (IMP *)&MTN.originalIcons);
    if (MTN.originalIcons == NULL) {
        MTSetState(MTNotificationIconAdapterStateOriginalUnavailable);
        return;
    }
    MTSetState(MTNotificationIconAdapterStateInstalled);
}

BOOL MTNotificationIconAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTNotificationIconAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeNotificationIconAdapterObservation.state,
            &expected, MTNotificationIconAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTNotificationIconAdapterStateScheduled ||
            expected == MTNotificationIconAdapterStateInstalled;
    }
    MTN.resolver = resolver;
    MTN.preparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MT_ADAPTER_ID, MTNotificationIconAdapterStateScheduled,
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
