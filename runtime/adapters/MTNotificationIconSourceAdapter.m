#import "MTNotificationIconSourceAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"
#import "MTStaticIconConfiguration.h"

static NSString *const MTNotificationIconSourceAdapterID =
    @"springboard.notification-icon-source";
static const char *const MTNotificationProviderClassName =
    "NCNotificationRequestContentProvider";
static const char *const MTNotificationRequestClassName =
    "NCNotificationRequest";
static const char *const MTBulletinClassName = "BBBulletin";
static const char *const MTIconsSelectorName = "icons";
// This misspelling is the selector exported by UserNotificationsUIKit.
static const char *const MTDirectIdentitySelectorName =
    "_appBundleIdentifer";
static const char *const MTRequestSelectorName = "notificationRequest";
static const char *const MTBulletinSelectorName = "bulletin";
static const char *const MTSectionSelectorName = "sectionID";
static const char *const MTMappedCacheClassName = "NCUIMappedImageCache";
static const char *const MTSharedCacheSelectorName = "sharedCache";
static const char *const MTClearCacheSelectorName = "removeAllObjects";
static const char *const MTObjectGetterEncoding = "@16@0:8";
static const char *const MTVoidGetterEncoding = "v16@0:8";
static const char *const MTUserNotificationsUIKitPath =
    "/System/Library/PrivateFrameworks/"
    "UserNotificationsUIKit.framework/UserNotificationsUIKit";

typedef id (*MTNotificationObjectGetter)(id, SEL);
typedef void (*MTNotificationVoidGetter)(id, SEL);

MTNotificationIconSourceAdapterObservation
    MTRuntimeNotificationIconSourceAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(
            MTNotificationIconSourceAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .identityResults = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .mappedCacheClears = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTNotificationIconSourceAdapterObservation) == 64,
    "The notification icon source observation ABI changed");

static struct {
    Class imageClass;
    Class requestClass;
    Class bulletinClass;
    SEL directIdentitySelector;
    SEL requestSelector;
    SEL bulletinSelector;
    SEL sectionSelector;
    MTNotificationObjectGetter originalIcons;
    MTNotificationObjectGetter directIdentityGetter;
    MTNotificationObjectGetter requestGetter;
    MTNotificationObjectGetter bulletinGetter;
    MTNotificationObjectGetter sectionGetter;
    MTRuntimeReplacementResolver resolver;
    MTRuntimeReplacementPreparation preparation;
} MTNotificationSource;

static _Atomic(bool) MTNotificationInstallPassScheduled = false;

static NSString *MTNotificationSourceStateName(
    MTNotificationIconSourceAdapterState state) {
    switch (state) {
        case MTNotificationIconSourceAdapterStateDormant:
            return @"Dormant";
        case MTNotificationIconSourceAdapterStateScheduled:
            return @"Scheduled";
        case MTNotificationIconSourceAdapterStateInstalled:
            return @"Installed";
        case MTNotificationIconSourceAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTNotificationIconSourceAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTNotificationIconSourceAdapterStateImplementationUnavailable:
            return @"ImplementationUnavailable";
        case MTNotificationIconSourceAdapterStateIdentityRouteUnavailable:
            return @"IdentityRouteUnavailable";
        case MTNotificationIconSourceAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTNotificationIconSourceAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
    }
    return @"Unknown";
}

static void MTNotificationSourceSetState(
    MTNotificationIconSourceAdapterState state) {
    atomic_store_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation.state,
        (uint32_t)state, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTNotificationIconSourceAdapterID, (uint32_t)state,
        MTNotificationSourceStateName(state));
}

static BOOL MTNotificationGetterMethodMatches(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL &&
        strcmp(encoding, MTObjectGetterEncoding) == 0 &&
        MTRuntimeImplementationResolves(
            method_getImplementation(method));
}

static BOOL MTNotificationClearMappedImageCache(void) {
    Class cacheClass = objc_getClass(MTMappedCacheClassName);
    SEL sharedSelector = sel_registerName(MTSharedCacheSelectorName);
    Method sharedMethod = cacheClass == Nil ? NULL :
        class_getClassMethod(cacheClass, sharedSelector);
    if (!MTNotificationGetterMethodMatches(sharedMethod)) return NO;
    id cache = ((MTNotificationObjectGetter)
        method_getImplementation(sharedMethod))(cacheClass, sharedSelector);
    SEL clearSelector = sel_registerName(MTClearCacheSelectorName);
    Method clearMethod = cache == nil ? NULL :
        class_getInstanceMethod(object_getClass(cache), clearSelector);
    const char *encoding = clearMethod == NULL ? NULL :
        method_getTypeEncoding(clearMethod);
    if (encoding == NULL || strcmp(encoding, MTVoidGetterEncoding) != 0 ||
        !MTRuntimeImplementationResolves(
            method_getImplementation(clearMethod))) {
        return NO;
    }
    @try {
        ((MTNotificationVoidGetter)method_getImplementation(clearMethod))(
            cache, clearSelector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *MTNotificationApplicationBundleIdentifier(id provider) {
    @try {
        if (MTNotificationSource.directIdentityGetter != NULL) {
            id direct = MTNotificationSource.directIdentityGetter(
                provider, MTNotificationSource.directIdentitySelector);
            if (MTStaticIconBundleIdentifierIsValid(direct)) {
                return direct;
            }
        }
        if (MTNotificationSource.requestGetter == NULL ||
            MTNotificationSource.bulletinGetter == NULL ||
            MTNotificationSource.sectionGetter == NULL) {
            return nil;
        }
        id request = MTNotificationSource.requestGetter(
            provider, MTNotificationSource.requestSelector);
        if (![request isKindOfClass:MTNotificationSource.requestClass]) {
            return nil;
        }
        id bulletin = MTNotificationSource.bulletinGetter(
            request, MTNotificationSource.bulletinSelector);
        if (![bulletin isKindOfClass:MTNotificationSource.bulletinClass]) {
            return nil;
        }
        id section = MTNotificationSource.sectionGetter(
            bulletin, MTNotificationSource.sectionSelector);
        return MTStaticIconBundleIdentifierIsValid(section) ? section : nil;
    } @catch (__unused NSException *exception) {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .contractRejects,
            1, memory_order_relaxed);
        return nil;
    }
}

static id MTNotificationHookedIcons(id self, SEL selector) {
    id originalResult = MTNotificationSource.originalIcons(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (![originalResult isKindOfClass:NSArray.class] ||
        [(NSArray *)originalResult count] == 0) {
        return originalResult;
    }
    id originalIcon = [(NSArray *)originalResult objectAtIndex:0];
    if (![originalIcon isKindOfClass:MTNotificationSource.imageClass]) {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .contractRejects,
            1, memory_order_relaxed);
        return originalResult;
    }
    NSString *bundleIdentifier =
        MTNotificationApplicationBundleIdentifier(self);
    if (bundleIdentifier.length == 0) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation.identityResults,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    id replacement = nil;
    @try {
        replacement = MTNotificationSource.resolver(
            bundleIdentifier, originalIcon);
    } @catch (__unused NSException *exception) {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .contractRejects,
            1, memory_order_relaxed);
        return originalResult;
    }
    if (replacement == nil || replacement == originalIcon) {
        return originalResult;
    }
    if (![replacement isKindOfClass:MTNotificationSource.imageClass]) {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .contractRejects,
            1, memory_order_relaxed);
        return originalResult;
    }
    NSMutableArray *icons = [(NSArray *)originalResult mutableCopy];
    if (icons == nil) return originalResult;
    icons[0] = replacement;
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation
            .replacementResults,
        1, memory_order_relaxed);
    return icons;
}

static void MTNotificationAttemptInstallation(void);

static void MTNotificationScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTNotificationIconSourceAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTNotificationInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTNotificationInstallPassScheduled, false,
            memory_order_release);
        MTNotificationAttemptInstallation();
    });
}

static void MTNotificationRuntimeImageAdded(
    const struct mach_header *header,
    intptr_t slide) {
    (void)header;
    (void)slide;
    MTNotificationScheduleInstallPass();
}

static void MTNotificationAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTNotificationScheduleInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTNotificationIconSourceAdapterStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeNotificationIconSourceAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class providerClass = objc_getClass(
        MTNotificationProviderClassName);
    SEL iconsSelector = sel_registerName(MTIconsSelectorName);
    Method iconsMethod = providerClass == Nil ? NULL :
        class_getInstanceMethod(providerClass, iconsSelector);
    if (providerClass == Nil || iconsMethod == NULL) return;

    SEL directSelector = sel_registerName(
        MTDirectIdentitySelectorName);
    Method directMethod = class_getInstanceMethod(
        providerClass, directSelector);
    SEL requestSelector = sel_registerName(MTRequestSelectorName);
    Method requestMethod = class_getInstanceMethod(
        providerClass, requestSelector);
    Class requestClass = objc_getClass(MTNotificationRequestClassName);
    SEL bulletinSelector = sel_registerName(MTBulletinSelectorName);
    Method bulletinMethod = requestClass == Nil ? NULL :
        class_getInstanceMethod(requestClass, bulletinSelector);
    Class bulletinClass = objc_getClass(MTBulletinClassName);
    SEL sectionSelector = sel_registerName(MTSectionSelectorName);
    Method sectionMethod = bulletinClass == Nil ? NULL :
        class_getInstanceMethod(bulletinClass, sectionSelector);
    Class imageClass = objc_getClass("UIImage");

    MTRuntimeABIReportProbePresence(
        MTNotificationIconSourceAdapterID,
        @"class:NCNotificationRequestContentProvider",
        providerClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTNotificationIconSourceAdapterID,
        @"image:NCNotificationRequestContentProvider",
        MTRuntimeClassMatchesImagePath(
            providerClass, MTUserNotificationsUIKitPath),
        @"UserNotificationsUIKit",
        class_getImageName(providerClass) == NULL ? nil :
            @(class_getImageName(providerClass)));
    MTRuntimeABIReportProbeMethodType(
        MTNotificationIconSourceAdapterID,
        @"encoding:NCNotificationRequestContentProvider.icons",
        iconsMethod, MTObjectGetterEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTNotificationIconSourceAdapterID,
        @"impl:NCNotificationRequestContentProvider.icons",
        method_getImplementation(iconsMethod));

    if (!MTRuntimeClassMatchesImagePath(
            providerClass, MTUserNotificationsUIKitPath)) {
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateClassImageMismatch);
        return;
    }
    const char *iconsEncoding = method_getTypeEncoding(iconsMethod);
    if (iconsEncoding == NULL ||
        strcmp(iconsEncoding, MTObjectGetterEncoding) != 0) {
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateMethodTypeMismatch);
        return;
    }
    IMP iconsImplementation = method_getImplementation(iconsMethod);
    if (!MTRuntimeImplementationResolves(iconsImplementation)) {
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateImplementationUnavailable);
        return;
    }

    BOOL directRoute = MTNotificationGetterMethodMatches(directMethod);
    BOOL requestRoute = requestClass != Nil && bulletinClass != Nil &&
        MTNotificationGetterMethodMatches(requestMethod) &&
        MTNotificationGetterMethodMatches(bulletinMethod) &&
        MTNotificationGetterMethodMatches(sectionMethod);
    MTRuntimeABIReportRecordContract(
        MTNotificationIconSourceAdapterID,
        @"identity:application-bundle-identifier",
        directRoute || requestRoute,
        @"direct-or-request-bulletin",
        [NSString stringWithFormat:@"direct=%d request=%d",
            directRoute, requestRoute]);
    if (!directRoute && !requestRoute) {
        // A dependent framework may still be entering the process. A later
        // dyld callback retries the complete capability probe.
        if (requestClass == Nil || bulletinClass == Nil) return;
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateIdentityRouteUnavailable);
        return;
    }
    if (imageClass == Nil || !MTNotificationSource.preparation()) {
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateResolverPreparationFailed);
        return;
    }

    MTNotificationSource.imageClass = imageClass;
    MTNotificationSource.requestClass = requestRoute ? requestClass : Nil;
    MTNotificationSource.bulletinClass = requestRoute ? bulletinClass : Nil;
    MTNotificationSource.directIdentitySelector = directSelector;
    MTNotificationSource.requestSelector = requestSelector;
    MTNotificationSource.bulletinSelector = bulletinSelector;
    MTNotificationSource.sectionSelector = sectionSelector;
    MTNotificationSource.directIdentityGetter = directRoute ?
        (MTNotificationObjectGetter)method_getImplementation(directMethod) :
        NULL;
    MTNotificationSource.requestGetter = requestRoute ?
        (MTNotificationObjectGetter)method_getImplementation(requestMethod) :
        NULL;
    MTNotificationSource.bulletinGetter = requestRoute ?
        (MTNotificationObjectGetter)method_getImplementation(bulletinMethod) :
        NULL;
    MTNotificationSource.sectionGetter = requestRoute ?
        (MTNotificationObjectGetter)method_getImplementation(sectionMethod) :
        NULL;
    MTNotificationSource.originalIcons =
        (MTNotificationObjectGetter)iconsImplementation;
    MSHookMessageEx(
        providerClass, iconsSelector, (IMP)MTNotificationHookedIcons,
        (IMP *)&MTNotificationSource.originalIcons);
    if (MTNotificationSource.originalIcons == NULL) {
        MTNotificationSource.originalIcons =
            (MTNotificationObjectGetter)iconsImplementation;
        MTNotificationSourceSetState(
            MTNotificationIconSourceAdapterStateOriginalUnavailable);
        return;
    }
    if (MTNotificationClearMappedImageCache()) {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .mappedCacheClears,
            1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation
                .contractRejects,
            1, memory_order_relaxed);
    }
    MTNotificationSourceSetState(
        MTNotificationIconSourceAdapterStateInstalled);
}

BOOL MTNotificationIconSourceAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTNotificationIconSourceAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeNotificationIconSourceAdapterObservation.state,
            &expected,
            MTNotificationIconSourceAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTNotificationIconSourceAdapterStateScheduled ||
            expected == MTNotificationIconSourceAdapterStateInstalled;
    }
    MTNotificationSource.resolver = resolver;
    MTNotificationSource.preparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTNotificationIconSourceAdapterID,
        MTNotificationIconSourceAdapterStateScheduled,
        @"Scheduled");
    _dyld_register_func_for_add_image(MTNotificationRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTNotificationAttemptInstallation();
        }
    } else {
        MTNotificationScheduleInstallPass();
    }
    return YES;
}
