#import "MTShareSheetActivityGlyphAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"
#import "MTApplicationIconNativeInvalidation.h"
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
static const char *const MTApplicationImageTypeEncoding = "@24@0:8@16";
static const char *const MTNativeApplicationImageSelectorName =
    "_activityImageForApplicationBundleIdentifier:";
static const char *const MTNativeApplicationSettingsImageSelectorName =
    "_activitySettingsImageForApplicationBundleIdentifier:";
static const char *const MTProviderClassName =
    "SFUIActivityImageProvider";
static const char *const MTProviderRequestSelectorName =
    "performImageRequest:";
static const char *const MTProviderRequestTypeEncoding = "@24@0:8@16";
static const char *const MTSharingUIImagePath =
    "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI";

typedef id (*MTImageFunction)(id, SEL);
typedef id (*MTApplicationImageFunction)(id, SEL, id);
typedef id (*MTProviderRequestFunction)(id, SEL, id);

enum {
    MTShareGlyphStateDormant = 0,
    MTShareGlyphStateScheduled = 1,
    MTShareGlyphStateInstalled = 2,
    MTShareGlyphStateRejected = 10,
};

MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(MTShareGlyphStateDormant),
        .calls = ATOMIC_VAR_INIT(0),
        .applicationActivitiesPreserved = ATOMIC_VAR_INIT(0),
        .customActivityIdentities = ATOMIC_VAR_INIT(0),
        .replacements = ATOMIC_VAR_INIT(0),
        .nativeApplicationBridgeRequests = ATOMIC_VAR_INIT(0),
        .nativeApplicationBridgeResults = ATOMIC_VAR_INIT(0),
        .providerRequestsTracked = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTShareSheetActivityGlyphAdapterObservation) == 64,
    "Share Sheet activity-glyph observation ABI changed");

static Class MTProxyClass;
static Class MTExtensionActivityClass;
static MTImageFunction MTOriginalActivityImage;
static MTImageFunction MTOriginalActivitySettingsImage;
static MTImageFunction MTOriginalExtensionImage;
static MTImageFunction MTOriginalExtensionSettingsImage;
static MTImageFunction MTOriginalProxyImage;
static MTImageFunction MTOriginalProxySettingsImage;
static MTApplicationImageFunction MTNativeApplicationImage;
static MTApplicationImageFunction MTNativeApplicationSettingsImage;
static MTProviderRequestFunction MTOriginalProviderRequest;
static Class MTActivityClass;
static SEL MTNativeApplicationImageSelector;
static SEL MTNativeApplicationSettingsImageSelector;
static MTRuntimeReplacementResolver MTGlyphResolver;
static MTRuntimeReplacementPreparation MTGlyphPreparation;
static BOOL MTPreparationComplete;
static BOOL MTActivityHooksInstalled;
static BOOL MTProxyHooksInstalled;
static BOOL MTProviderHookInstalled;
static _Atomic(bool) MTInstallPassScheduled = false;

static id MTResolveActivity(id receiver,
                            id originalResult,
                            BOOL proxy,
                            BOOL settingsImage) {
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
        // A resolved bundle means the live activity is semantically an
        // application icon, even when Photos wraps Mail/Messages in its own
        // PUActivity subclasses or an extension exposes a containing App.
        // Re-enter UIActivity's native IconServices factory so every such
        // surface shares the one service-side pixel source.
        if (MTActivityClass != Nil) {
            atomic_fetch_add_explicit(
                &MTRuntimeShareSheetActivityGlyphAdapterObservation
                     .nativeApplicationBridgeRequests,
                1, memory_order_relaxed);
            MTApplicationImageFunction bridge = settingsImage
                ? MTNativeApplicationSettingsImage
                : MTNativeApplicationImage;
            SEL bridgeSelector = settingsImage
                ? MTNativeApplicationSettingsImageSelector
                : MTNativeApplicationImageSelector;
            id nativeResult = bridge == NULL ? nil : bridge(
                MTActivityClass, bridgeSelector, bundleIdentifier);
            if (nativeResult != nil) {
                atomic_fetch_add_explicit(
                    &MTRuntimeShareSheetActivityGlyphAdapterObservation
                         .nativeApplicationBridgeResults,
                    1, memory_order_relaxed);
                return nativeResult;
            }
        }
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
        ? result : MTResolveActivity(self, result, NO, NO);
}

static id MTHookedActivitySettingsImage(id self, SEL selector) {
    id result = MTOriginalActivitySettingsImage(self, selector);
    return MTReceiverNeedsSubclassHook(self)
        ? result : MTResolveActivity(self, result, NO, YES);
}

static id MTHookedExtensionImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalExtensionImage(self, selector), NO, NO);
}

static id MTHookedExtensionSettingsImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalExtensionSettingsImage(self, selector), NO, YES);
}

static id MTHookedProxyImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalProxyImage(self, selector), YES, NO);
}

static id MTHookedProxySettingsImage(id self, SEL selector) {
    return MTResolveActivity(
        self, MTOriginalProxySettingsImage(self, selector), YES, YES);
}

static id MTHookedProviderRequest(id self, SEL selector, id request) {
    MTApplicationIconNativeInvalidationTrackShareImageProvider(self);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation
             .providerRequestsTracked,
        1, memory_order_relaxed);
    return MTOriginalProviderRequest(self, selector, request);
}

static BOOL MTValidateMethod(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL && strcmp(encoding, MTImageTypeEncoding) == 0 &&
        MTShareSheetImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static BOOL MTValidateShareMethod(Method method,
                                  const char *typeEncoding) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL && strcmp(encoding, typeEncoding) == 0 &&
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
            SEL nativeImageSelector = sel_registerName(
                MTNativeApplicationImageSelectorName);
            SEL nativeSettingsSelector = sel_registerName(
                MTNativeApplicationSettingsImageSelectorName);
            Method nativeImageMethod = class_getClassMethod(
                activityClass, nativeImageSelector);
            Method nativeSettingsMethod = class_getClassMethod(
                activityClass, nativeSettingsSelector);
            BOOL nativeBridgeValid = MTValidateShareMethod(
                nativeImageMethod, MTApplicationImageTypeEncoding) &&
                MTValidateShareMethod(
                    nativeSettingsMethod,
                    MTApplicationImageTypeEncoding);
            MTRuntimeABIReportProbePresence(
                MTShareGlyphAdapterID,
                @"capability:native-application-icon-bridge",
                nativeBridgeValid);
            if (nativeBridgeValid) {
                MTActivityClass = activityClass;
                MTNativeApplicationImageSelector = nativeImageSelector;
                MTNativeApplicationSettingsImageSelector =
                    nativeSettingsSelector;
                MTNativeApplicationImage = (MTApplicationImageFunction)
                    method_getImplementation(nativeImageMethod);
                MTNativeApplicationSettingsImage =
                    (MTApplicationImageFunction)
                        method_getImplementation(nativeSettingsMethod);
            }
            MTExtensionActivityClass = extensionClass;
            BOOL activityInstalled = nativeBridgeValid && MTInstallPair(
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
    if (!MTProviderHookInstalled) {
        Class providerClass = objc_getClass(MTProviderClassName);
        SEL requestSelector = sel_registerName(
            MTProviderRequestSelectorName);
        Method requestMethod = providerClass == Nil ? NULL :
            class_getInstanceMethod(providerClass, requestSelector);
        const char *encoding = requestMethod == NULL ? NULL :
            method_getTypeEncoding(requestMethod);
        BOOL providerValid =
            MTRuntimeClassMatchesImagePath(
                providerClass, MTSharingUIImagePath) &&
            encoding != NULL &&
            strcmp(encoding, MTProviderRequestTypeEncoding) == 0 &&
            MTRuntimeImplementationResolves(
                method_getImplementation(requestMethod));
        if (providerClass != Nil) {
            MTRuntimeABIReportProbePresence(
                MTShareGlyphAdapterID,
                @"capability:share-provider-cache-tracking",
                providerValid);
        }
        if (providerValid) {
            MTOriginalProviderRequest = (MTProviderRequestFunction)
                method_getImplementation(requestMethod);
            MSHookMessageEx(
                providerClass, requestSelector,
                (IMP)MTHookedProviderRequest,
                (IMP *)&MTOriginalProviderRequest);
            MTProviderHookInstalled = MTOriginalProviderRequest != NULL;
        }
    }
    if (MTActivityHooksInstalled || MTProxyHooksInstalled ||
        MTProviderHookInstalled) {
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
