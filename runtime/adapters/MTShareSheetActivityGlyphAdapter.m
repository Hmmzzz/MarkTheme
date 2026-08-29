#import "MTShareSheetActivityGlyphAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTShareSheetABI.h"
#import "MTShareSheetActivityIdentity.h"

static NSString *const MTShareGlyphAdapterID =
    @"share-sheet.activity-glyph";
static const char *const MTUIActivityClassName = "UIActivity";
static const char *const MTExtensionActivityClassName =
    "UIApplicationExtensionActivity";
static const char *const MTProxyClassName = "SUIHostActivityProxy";
static const char *const MTActivityImageSelectorName = "_activityImage";
static const char *const MTProxyImageSelectorName = "activityImage";
static const char *const MTSettingsImageSelectorName =
    "_activitySettingsImage";
static const char *const MTImageTypeEncoding = "@16@0:8";

typedef id (*MTImageFunction)(id, SEL);

enum {
    MTShareGlyphStateDormant = 0,
    MTShareGlyphStateScheduled = 1,
    MTShareGlyphStateInstalled = 2,
    MTShareGlyphStateRejected = 10,
};

MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTShareGlyphStateDormant),
        .calls = ATOMIC_VAR_INIT(0),
        .applicationActivitiesPreserved = ATOMIC_VAR_INIT(0),
        .customActivityIdentities = ATOMIC_VAR_INIT(0),
        .replacements = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTShareSheetActivityGlyphAdapterObservation) == 40,
    "Share Sheet activity-glyph observation ABI changed");

static Class MTProxyClass;
static Class MTExtensionActivityClass;
static MTImageFunction MTOriginalActivityImage;
static MTImageFunction MTOriginalActivitySettingsImage;
static MTImageFunction MTOriginalExtensionImage;
static MTImageFunction MTOriginalExtensionSettingsImage;
static MTImageFunction MTOriginalProxyImage;
static MTImageFunction MTOriginalProxySettingsImage;
static MTRuntimeReplacementResolver MTGlyphResolver;
static MTRuntimeReplacementPreparation MTGlyphPreparation;
static BOOL MTPreparationComplete;
static BOOL MTActivityHooksInstalled;
static BOOL MTProxyHooksInstalled;
static _Atomic(bool) MTInstallPassScheduled = false;

static id MTResolveActivity(id receiver, id originalResult, BOOL proxy) {
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.calls,
        1, memory_order_relaxed);
    NSString *activityIdentity = nil;
    NSString *bundleIdentifier = proxy
        ? MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
              receiver, &activityIdentity)
        : MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
              receiver, &activityIdentity);
    if (bundleIdentifier.length > 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation
                .applicationActivitiesPreserved,
            1, memory_order_relaxed);
        return originalResult;
    }
    if (activityIdentity.length == 0) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation
            .customActivityIdentities,
        1, memory_order_relaxed);
    BOOL replaced = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        activityIdentity, originalResult, MTGlyphResolver, &replaced);
    if (replaced) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.replacements,
            1, memory_order_relaxed);
    }
    return result;
}

static BOOL MTReceiverNeedsSubclassHook(id receiver) {
    return (MTProxyClass != Nil && [receiver isKindOfClass:MTProxyClass]) ||
        (MTExtensionActivityClass != Nil &&
         [receiver isKindOfClass:MTExtensionActivityClass]);
}

static id MTHookedActivityImage(id self, SEL selector) {
    id result = MTOriginalActivityImage(self, selector);
    return MTReceiverNeedsSubclassHook(self)
        ? result : MTResolveActivity(self, result, NO);
}

static id MTHookedActivitySettingsImage(id self, SEL selector) {
    id result = MTOriginalActivitySettingsImage(self, selector);
    return MTReceiverNeedsSubclassHook(self)
        ? result : MTResolveActivity(self, result, NO);
}

static id MTHookedExtensionImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalExtensionImage(self, selector), NO);
}

static id MTHookedExtensionSettingsImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalExtensionSettingsImage(self, selector), NO);
}

static id MTHookedProxyImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalProxyImage(self, selector), YES);
}

static id MTHookedProxySettingsImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalProxySettingsImage(self, selector), YES);
}

static BOOL MTValidateMethod(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL && strcmp(encoding, MTImageTypeEncoding) == 0 &&
        MTShareSheetImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static BOOL MTPrepareIfNeeded(void) {
    if (MTPreparationComplete) return YES;
    MTPreparationComplete = MTGlyphPreparation();
    return MTPreparationComplete;
}

static BOOL MTInstallPair(Class cls,
                          SEL firstSelector,
                          SEL secondSelector,
                          IMP firstReplacement,
                          IMP secondReplacement,
                          MTImageFunction *firstOriginal,
                          MTImageFunction *secondOriginal) {
    Method first = class_getInstanceMethod(cls, firstSelector);
    Method second = class_getInstanceMethod(cls, secondSelector);
    if (!MTValidateMethod(first) || !MTValidateMethod(second)) return NO;
    *firstOriginal = (MTImageFunction)method_getImplementation(first);
    *secondOriginal = (MTImageFunction)method_getImplementation(second);
    MSHookMessageEx(
        cls, firstSelector, firstReplacement, (IMP *)firstOriginal);
    MSHookMessageEx(
        cls, secondSelector, secondReplacement, (IMP *)secondOriginal);
    return *firstOriginal != NULL && *secondOriginal != NULL;
}

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    uint32_t state = atomic_load_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
        memory_order_acquire);
    if (state != MTShareGlyphStateScheduled &&
        state != MTShareGlyphStateInstalled) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTInstallPassScheduled, false, memory_order_release);
        MTAttemptInstallation();
    });
}

static void MTRuntimeImageAdded(const struct mach_header *header,
                                intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleInstallPass();
}

static void MTAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleInstallPass();
        return;
    }
    if (!MTPrepareIfNeeded()) {
        atomic_store_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            MTShareGlyphStateRejected, memory_order_release);
        return;
    }
    SEL imageSelector = sel_registerName(MTActivityImageSelectorName);
    SEL proxyImageSelector = sel_registerName(MTProxyImageSelectorName);
    SEL settingsSelector = sel_registerName(MTSettingsImageSelectorName);
    if (!MTActivityHooksInstalled) {
        Class activityClass = objc_getClass(MTUIActivityClassName);
        Class extensionClass = objc_getClass(MTExtensionActivityClassName);
        if (activityClass != Nil && extensionClass != Nil &&
            MTShareSheetClassMatchesExpectedImage(activityClass) &&
            MTShareSheetClassMatchesExpectedImage(extensionClass)) {
            MTExtensionActivityClass = extensionClass;
            BOOL activityInstalled = MTInstallPair(
                activityClass, imageSelector, settingsSelector,
                (IMP)MTHookedActivityImage,
                (IMP)MTHookedActivitySettingsImage,
                &MTOriginalActivityImage,
                &MTOriginalActivitySettingsImage);
            BOOL extensionInstalled = activityInstalled && MTInstallPair(
                extensionClass, imageSelector, settingsSelector,
                (IMP)MTHookedExtensionImage,
                (IMP)MTHookedExtensionSettingsImage,
                &MTOriginalExtensionImage,
                &MTOriginalExtensionSettingsImage);
            MTActivityHooksInstalled =
                activityInstalled && extensionInstalled;
        }
    }
    if (!MTProxyHooksInstalled) {
        Class proxyClass = objc_getClass(MTProxyClassName);
        if (proxyClass != Nil &&
            MTShareSheetClassMatchesExpectedImage(proxyClass)) {
            MTProxyClass = proxyClass;
            MTProxyHooksInstalled = MTInstallPair(
                proxyClass, proxyImageSelector, settingsSelector,
                (IMP)MTHookedProxyImage,
                (IMP)MTHookedProxySettingsImage,
                &MTOriginalProxyImage,
                &MTOriginalProxySettingsImage);
        }
    }
    if (MTActivityHooksInstalled || MTProxyHooksInstalled) {
        atomic_store_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            MTShareGlyphStateInstalled, memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTShareGlyphAdapterID,
            MTShareGlyphStateInstalled, @"Installed");
    }
}

BOOL MTShareSheetActivityGlyphAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTShareGlyphStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            &expected, MTShareGlyphStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTShareGlyphStateScheduled ||
            expected == MTShareGlyphStateInstalled;
    }
    MTGlyphResolver = resolver;
    MTGlyphPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTShareGlyphAdapterID,
        MTShareGlyphStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) MTAttemptInstallation();
    else MTScheduleInstallPass();
    return YES;
}
