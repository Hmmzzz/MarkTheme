#import "MTShareSheetActivityImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTShareSheetABI.h"
#import "MTShareSheetActivityIdentity.h"
#import "MTShareSheetProviderABI.h"
#import "MTUIKitCoreApplicationIconABI.h"

#include <stdbool.h>
#include <string.h>

static NSString *const MTAdapterID = @"share-sheet.activity-image";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTShareSheetUIActivityClassName = "UIActivity";
static const char *const MTShareSheetApplicationExtensionActivityClassName =
    "UIApplicationExtensionActivity";
static const char *const MTShareSheetProxyClassName = "SUIHostActivityProxy";
static const char *const MTShareSheetImageSelectorName = "_activityImage";
static const char *const MTShareSheetSettingsImageSelectorName =
    "_activitySettingsImage";
static const char *const MTShareSheetImageTypeEncoding = "@16@0:8";
static const char *const MTShareSheetApplicationIconSelectorName =
    "_activityImageForApplicationBundleIdentifier:";
static const char *const MTShareSheetApplicationSettingsIconSelectorName =
    "_activitySettingsImageForApplicationBundleIdentifier:";
static const char *const MTShareSheetApplicationIconTypeEncoding =
    "@24@0:8@16";
static const char *const MTShareSheetProviderClassName =
    "SFUIActivityImageProvider";
static const char *const MTShareSheetProviderHandleSelectorName =
    "_handleIconImage:bundleIdentifier:activityCategory:contentSizeCategory:placeholder:";
static const char *const MTShareSheetProviderHandleTypeEncoding =
    "v52@0:8@16@24q32@40B48";
static const char *const MTUIKitImageClassName = "UIImage";
static const char *const MTUIKitApplicationIconSelectorName =
    "_applicationIconImageForBundleIdentifier:format:scale:";
static const char *const MTUIKitApplicationIconTypeEncoding =
    "@36@0:8@16i24d28";
typedef id (*MTShareSheetImageFunction)(id, SEL);
typedef id (*MTShareSheetApplicationIconFunction)(id, SEL, id);
typedef void (*MTShareSheetProviderHandleFunction)(
    id, SEL, id, id, NSInteger, id, BOOL);
typedef id (*MTUIKitApplicationIconFunction)(id, SEL, id, int, CGFloat);

MTShareSheetActivityImageAdapterObservation
    MTRuntimeShareSheetActivityImageAdapterObservation = {
        .schemaVersion = 4,
        .state = ATOMIC_VAR_INIT(
            MTShareSheetActivityImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .reserved = 0,
        .totalCalls = ATOMIC_VAR_INIT(0),
        .uiActivityImageCalls = ATOMIC_VAR_INIT(0),
        .uiActivitySettingsImageCalls = ATOMIC_VAR_INIT(0),
        .proxyImageCalls = ATOMIC_VAR_INIT(0),
        .proxySettingsImageCalls = ATOMIC_VAR_INIT(0),
        .nilOriginalResults = ATOMIC_VAR_INIT(0),
        .identityResults = ATOMIC_VAR_INIT(0),
        .identityMisses = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .applicationIconCalls = ATOMIC_VAR_INIT(0),
        .applicationIconIdentityResults = ATOMIC_VAR_INIT(0),
        .applicationIconIdentityMisses = ATOMIC_VAR_INIT(0),
        .applicationIconReplacementResults = ATOMIC_VAR_INIT(0),
        .uiKitApplicationIconCalls = ATOMIC_VAR_INIT(0),
        .uiKitApplicationIconReplacementResults = ATOMIC_VAR_INIT(0),
        .activityApplicationIconCalls = ATOMIC_VAR_INIT(0),
        .activityApplicationIconReplacementResults = ATOMIC_VAR_INIT(0),
        .activityApplicationSettingsIconCalls = ATOMIC_VAR_INIT(0),
        .activityApplicationSettingsIconReplacementResults =
            ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTShareSheetActivityImageAdapterObservation) == 168,
    "The Share Sheet ProcessAdapter observation layout must remain fixed.");

static Class MTShareSheetProxyClass;
static Class MTShareSheetApplicationExtensionActivityClass;
static MTShareSheetImageFunction MTShareSheetOriginalUIActivityImage;
static MTShareSheetImageFunction MTShareSheetOriginalUIActivitySettingsImage;
static MTShareSheetImageFunction
    MTShareSheetOriginalApplicationExtensionActivityImage;
static MTShareSheetImageFunction
    MTShareSheetOriginalApplicationExtensionActivitySettingsImage;
static MTShareSheetImageFunction MTShareSheetOriginalProxyImage;
static MTShareSheetImageFunction MTShareSheetOriginalProxySettingsImage;
static MTShareSheetApplicationIconFunction
    MTShareSheetOriginalActivityApplicationIcon;
static MTShareSheetApplicationIconFunction
    MTShareSheetOriginalActivityApplicationSettingsIcon;
static MTShareSheetProviderHandleFunction MTShareSheetOriginalProviderHandle;
static MTUIKitApplicationIconFunction MTOriginalUIKitApplicationIcon;
static MTRuntimeReplacementResolver MTShareSheetActivityResolver;
static MTRuntimeReplacementResolver MTShareSheetApplicationIconResolver;
static MTRuntimeReplacementPreparation MTShareSheetReplacementPreparation;
static _Atomic(bool) MTShareSheetInstallPassScheduled = false;
static BOOL MTShareSheetReplacementPrepared;
static BOOL MTShareSheetUIKitProducerInstalled;
static BOOL MTShareSheetFrameworkProducersInstalled;

static void MTShareSheetAttemptInstallation(void);

static void MTShareSheetScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation.state,
            memory_order_acquire) !=
            MTShareSheetActivityImageAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTShareSheetInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTShareSheetInstallPassScheduled, false,
            memory_order_release);
        if (atomic_load_explicit(
                &MTRuntimeShareSheetActivityImageAdapterObservation.state,
                memory_order_acquire) ==
                MTShareSheetActivityImageAdapterStateScheduled) {
            MTShareSheetAttemptInstallation();
        }
    });
}

static void MTShareSheetRuntimeImageAdded(
    const struct mach_header *header,
    intptr_t slide) {
    (void)header;
    (void)slide;
    MTShareSheetScheduleInstallPass();
}

static NSString *MTShareSheetStateName(
    MTShareSheetActivityImageAdapterState state) {
    switch (state) {
        case MTShareSheetActivityImageAdapterStateDormant:
            return @"Dormant";
        case MTShareSheetActivityImageAdapterStateScheduled:
            return @"Scheduled";
        case MTShareSheetActivityImageAdapterStateInstalled:
            return @"Installed";
        case MTShareSheetActivityImageAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTShareSheetActivityImageAdapterStateClassImageMismatch:
            return @"ClassImageMismatch";
        case MTShareSheetActivityImageAdapterStateMethodTypeMismatch:
            return @"MethodTypeMismatch";
        case MTShareSheetActivityImageAdapterStateImplementationImageMismatch:
            return @"ImplementationImageMismatch";
        case MTShareSheetActivityImageAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
    }
    return @"Unknown";
}

static void MTShareSheetSetState(MTShareSheetActivityImageAdapterState state) {
    atomic_store_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation.state,
        (uint32_t)state, memory_order_release);
    // Every state change is recorded so a user report names the exact gate
    // that kept this surface stock on an untested device or build.
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, (uint32_t)state, MTShareSheetStateName(state));
}

static id MTShareSheetResolveResult(
    NSString *identity,
    id originalResult,
    MTRuntimeReplacementResolver resolver,
    BOOL applicationIcon) {
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .nilOriginalResults,
            1, memory_order_relaxed);
    }
    if (identity == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation.identityMisses,
            1, memory_order_relaxed);
        if (applicationIcon) {
            atomic_fetch_add_explicit(
                &MTRuntimeShareSheetActivityImageAdapterObservation
                    .applicationIconIdentityMisses,
                1, memory_order_relaxed);
        }
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation.identityResults,
        1, memory_order_relaxed);
    if (applicationIcon) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .applicationIconIdentityResults,
            1, memory_order_relaxed);
    }
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        identity, originalResult, resolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .replacementResults,
            1, memory_order_relaxed);
        if (applicationIcon) {
            atomic_fetch_add_explicit(
                &MTRuntimeShareSheetActivityImageAdapterObservation
                    .applicationIconReplacementResults,
                1, memory_order_relaxed);
        }
    }
    return result;
}

static BOOL MTShareSheetReceiverIsProxy(id receiver) {
    return MTShareSheetProxyClass != Nil &&
        [receiver isKindOfClass:MTShareSheetProxyClass];
}

static BOOL MTShareSheetReceiverIsApplicationExtensionActivity(id receiver) {
    return MTShareSheetApplicationExtensionActivityClass != Nil &&
        [receiver isKindOfClass:
            MTShareSheetApplicationExtensionActivityClass];
}

static id MTShareSheetResolveActivityResult(
    NSString *activityIdentity,
    NSString *applicationBundleIdentifier,
    id originalResult) {
    if (applicationBundleIdentifier != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .applicationIconCalls,
            1, memory_order_relaxed);
        return MTShareSheetResolveResult(
            applicationBundleIdentifier, originalResult,
            MTShareSheetApplicationIconResolver, YES);
    }
    return MTShareSheetResolveResult(
        activityIdentity, originalResult,
        MTShareSheetActivityResolver, NO);
}

static id MTShareSheetHookedUIActivityImage(id self, SEL selector) {
    id originalResult = MTShareSheetOriginalUIActivityImage(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .uiActivityImageCalls,
        1, memory_order_relaxed);
    if (MTShareSheetReceiverIsProxy(self) ||
        MTShareSheetReceiverIsApplicationExtensionActivity(self)) {
        return originalResult;
    }
    return MTShareSheetResolveActivityResult(
        MTShareSheetUIActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivity(self),
        originalResult);
}

static id MTShareSheetHookedUIActivitySettingsImage(id self, SEL selector) {
    id originalResult =
        MTShareSheetOriginalUIActivitySettingsImage(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .uiActivitySettingsImageCalls,
        1, memory_order_relaxed);
    if (MTShareSheetReceiverIsProxy(self) ||
        MTShareSheetReceiverIsApplicationExtensionActivity(self)) {
        return originalResult;
    }
    return MTShareSheetResolveActivityResult(
        MTShareSheetUIActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivity(self),
        originalResult);
}

static id MTShareSheetHookedApplicationExtensionActivityImage(
    id self, SEL selector) {
    id originalResult =
        MTShareSheetOriginalApplicationExtensionActivityImage(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .uiActivityImageCalls,
        1, memory_order_relaxed);
    return MTShareSheetResolveActivityResult(
        MTShareSheetUIActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivity(self),
        originalResult);
}

static id MTShareSheetHookedApplicationExtensionActivitySettingsImage(
    id self, SEL selector) {
    id originalResult =
        MTShareSheetOriginalApplicationExtensionActivitySettingsImage(
            self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .uiActivitySettingsImageCalls,
        1, memory_order_relaxed);
    return MTShareSheetResolveActivityResult(
        MTShareSheetUIActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivity(self),
        originalResult);
}

static id MTShareSheetHookedProxyImage(id self, SEL selector) {
    id originalResult = MTShareSheetOriginalProxyImage(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation.proxyImageCalls,
        1, memory_order_relaxed);
    return MTShareSheetResolveActivityResult(
        MTShareSheetProxyActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivityProxy(self),
        originalResult);
}

static id MTShareSheetHookedProxySettingsImage(id self, SEL selector) {
    id originalResult = MTShareSheetOriginalProxySettingsImage(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .proxySettingsImageCalls,
        1, memory_order_relaxed);
    return MTShareSheetResolveActivityResult(
        MTShareSheetProxyActivityIdentity(self),
        MTShareSheetApplicationBundleIdentityForActivityProxy(self),
        originalResult);
}

static void MTShareSheetHookedProviderHandle(id self,
                                             SEL selector,
                                             id image,
                                             id bundleIdentifier,
                                             NSInteger activityCategory,
                                             id contentSizeCategory,
                                             BOOL placeholder) {
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .applicationIconCalls,
        1, memory_order_relaxed);
    id resolvedImage = MTShareSheetResolveResult(
        MTShareSheetApplicationBundleIdentity(bundleIdentifier),
        image, MTShareSheetApplicationIconResolver, YES);
    MTShareSheetOriginalProviderHandle(
        self, selector, resolvedImage, bundleIdentifier,
        activityCategory, contentSizeCategory, placeholder);
}

static id MTShareSheetHookedUIKitApplicationIcon(id self,
                                                 SEL selector,
                                                 id bundleIdentifier,
                                                 int format,
                                                 CGFloat scale) {
    id originalResult = MTOriginalUIKitApplicationIcon(
        self, selector, bundleIdentifier, format, scale);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .applicationIconCalls,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .uiKitApplicationIconCalls,
        1, memory_order_relaxed);
    id result = MTShareSheetResolveResult(
        MTShareSheetApplicationBundleIdentity(bundleIdentifier),
        originalResult, MTShareSheetApplicationIconResolver, YES);
    if (result != originalResult) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .uiKitApplicationIconReplacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

static id MTShareSheetHookedActivityApplicationIcon(
    id self, SEL selector, id bundleIdentifier) {
    id originalResult = MTShareSheetOriginalActivityApplicationIcon(
        self, selector, bundleIdentifier);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .applicationIconCalls,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .activityApplicationIconCalls,
        1, memory_order_relaxed);
    id result = MTShareSheetResolveResult(
        MTShareSheetApplicationBundleIdentity(bundleIdentifier),
        originalResult, MTShareSheetApplicationIconResolver, YES);
    if (result != originalResult) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .activityApplicationIconReplacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

static id MTShareSheetHookedActivityApplicationSettingsIcon(
    id self, SEL selector, id bundleIdentifier) {
    id originalResult =
        MTShareSheetOriginalActivityApplicationSettingsIcon(
            self, selector, bundleIdentifier);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .applicationIconCalls,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation
            .activityApplicationSettingsIconCalls,
        1, memory_order_relaxed);
    id result = MTShareSheetResolveResult(
        MTShareSheetApplicationBundleIdentity(bundleIdentifier),
        originalResult, MTShareSheetApplicationIconResolver, YES);
    if (result != originalResult) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation
                .activityApplicationSettingsIconReplacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

typedef struct MTShareSheetHookContract {
    Class targetClass;
    SEL selector;
    Method method;
    IMP replacement;
    IMP *original;
    const char *typeEncoding;
    BOOL (*implementationValidator)(IMP);
} MTShareSheetHookContract;

static BOOL MTShareSheetValidateHook(MTShareSheetHookContract *contract,
                                     MTShareSheetActivityImageAdapterState *state) {
    const char *typeEncoding = method_getTypeEncoding(contract->method);
    if (typeEncoding == NULL ||
        strcmp(typeEncoding, contract->typeEncoding) != 0) {
        *state = MTShareSheetActivityImageAdapterStateMethodTypeMismatch;
        return NO;
    }
    IMP implementation = method_getImplementation(contract->method);
    if (!contract->implementationValidator(implementation)) {
        *state =
            MTShareSheetActivityImageAdapterStateImplementationImageMismatch;
        return NO;
    }
    *contract->original = implementation;
    return YES;
}

static void MTShareSheetInstallContracts(
    MTShareSheetHookContract *contracts,
    NSUInteger count) {
    for (NSUInteger index = 0; index < count; index++) {
        MSHookMessageEx(contracts[index].targetClass,
                        contracts[index].selector,
                        contracts[index].replacement,
                        (IMP *)contracts[index].original);
    }
}

static BOOL MTShareSheetPrepareReplacementIfNeeded(void) {
    if (MTShareSheetReplacementPrepared) return YES;
    if (!MTShareSheetReplacementPreparation()) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateResolverPreparationFailed);
        return NO;
    }
    MTShareSheetReplacementPrepared = YES;
    return YES;
}

static void MTShareSheetInstallUIKitProducerIfAvailable(void) {
    if (MTShareSheetUIKitProducerInstalled) return;
    Class uiImageClass = objc_getClass(MTUIKitImageClassName);
    if (uiImageClass == Nil) return;
    SEL uiKitApplicationIconSelector =
        sel_registerName(MTUIKitApplicationIconSelectorName);
    Method uiKitApplicationIcon =
        class_getClassMethod(uiImageClass, uiKitApplicationIconSelector);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:UIImage",
        MTUIKitCoreApplicationIconClassMatchesExpectedImage(uiImageClass),
        @"UIKitCore", MTReportImageName(uiImageClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:UIImage."
         "_applicationIconImageForBundleIdentifier:format:scale:",
        uiKitApplicationIcon, MTUIKitApplicationIconTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID,
        @"impl:UIImage."
         "_applicationIconImageForBundleIdentifier:format:scale:",
        uiKitApplicationIcon == NULL ? NULL :
            method_getImplementation(uiKitApplicationIcon));
    if (uiKitApplicationIcon == NULL) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateClassUnavailable);
        return;
    }
    if (!MTUIKitCoreApplicationIconClassMatchesExpectedImage(uiImageClass)) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateClassImageMismatch);
        return;
    }
    MTShareSheetHookContract contract = {
        object_getClass(uiImageClass), uiKitApplicationIconSelector,
        uiKitApplicationIcon,
        (IMP)MTShareSheetHookedUIKitApplicationIcon,
        (IMP *)&MTOriginalUIKitApplicationIcon,
        MTUIKitApplicationIconTypeEncoding,
        MTUIKitCoreApplicationIconImplementationMatchesExpectedImage,
    };
    MTShareSheetActivityImageAdapterState rejectedState =
        MTShareSheetActivityImageAdapterStateInstalled;
    if (!MTShareSheetValidateHook(&contract, &rejectedState)) {
        MTShareSheetSetState(rejectedState);
        return;
    }
    if (!MTShareSheetPrepareReplacementIfNeeded()) return;
    MTShareSheetInstallContracts(&contract, 1);
    MTShareSheetUIKitProducerInstalled = YES;
}

static void MTShareSheetInstallFrameworkProducersIfAvailable(void) {
    if (MTShareSheetFrameworkProducersInstalled) return;
    Class uiActivityClass = objc_getClass(MTShareSheetUIActivityClassName);
    Class applicationExtensionActivityClass = objc_getClass(
        MTShareSheetApplicationExtensionActivityClassName);
    Class proxyClass = objc_getClass(MTShareSheetProxyClassName);
    Class providerClass = objc_getClass(MTShareSheetProviderClassName);
    if (uiActivityClass == Nil ||
        applicationExtensionActivityClass == Nil ||
        proxyClass == Nil || providerClass == Nil) {
        return;
    }
    SEL imageSelector = sel_registerName(MTShareSheetImageSelectorName);
    SEL settingsSelector =
        sel_registerName(MTShareSheetSettingsImageSelectorName);
    SEL applicationIconSelector =
        sel_registerName(MTShareSheetApplicationIconSelectorName);
    SEL applicationSettingsIconSelector =
        sel_registerName(MTShareSheetApplicationSettingsIconSelectorName);
    SEL providerHandleSelector =
        sel_registerName(MTShareSheetProviderHandleSelectorName);
    Method uiActivityImage = uiActivityClass == Nil ? NULL :
        class_getInstanceMethod(uiActivityClass, imageSelector);
    Method uiActivitySettings = uiActivityClass == Nil ? NULL :
        class_getInstanceMethod(uiActivityClass, settingsSelector);
    Method applicationExtensionActivityImage =
        class_getInstanceMethod(
            applicationExtensionActivityClass, imageSelector);
    Method applicationExtensionActivitySettings =
        class_getInstanceMethod(
            applicationExtensionActivityClass, settingsSelector);
    Method proxyImage = proxyClass == Nil ? NULL :
        class_getInstanceMethod(proxyClass, imageSelector);
    Method proxySettings = proxyClass == Nil ? NULL :
        class_getInstanceMethod(proxyClass, settingsSelector);
    Method activityApplicationIcon =
        class_getClassMethod(uiActivityClass, applicationIconSelector);
    Method activityApplicationSettingsIcon =
        class_getClassMethod(
            uiActivityClass, applicationSettingsIconSelector);
    Method providerHandle = providerClass == Nil ? NULL :
        class_getInstanceMethod(providerClass, providerHandleSelector);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIActivity", uiActivityClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIApplicationExtensionActivity",
        applicationExtensionActivityClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SUIHostActivityProxy", proxyClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SFUIActivityImageProvider",
        providerClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:UIActivity",
        MTShareSheetClassMatchesExpectedImage(uiActivityClass),
        @"ShareSheet", MTReportImageName(uiActivityClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:UIApplicationExtensionActivity",
        MTShareSheetClassMatchesExpectedImage(
            applicationExtensionActivityClass),
        @"ShareSheet",
        MTReportImageName(applicationExtensionActivityClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SUIHostActivityProxy",
        MTShareSheetClassMatchesExpectedImage(proxyClass),
        @"ShareSheet", MTReportImageName(proxyClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SFUIActivityImageProvider",
        MTShareSheetProviderClassMatchesExpectedImage(providerClass),
        @"SharingUI", MTReportImageName(providerClass));
    if (uiActivityImage == NULL || uiActivitySettings == NULL ||
        applicationExtensionActivityImage == NULL ||
        applicationExtensionActivitySettings == NULL ||
        proxyImage == NULL || proxySettings == NULL ||
        activityApplicationIcon == NULL ||
        activityApplicationSettingsIcon == NULL ||
        providerHandle == NULL) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateClassUnavailable);
        return;
    }
    if (!MTShareSheetClassMatchesExpectedImage(uiActivityClass) ||
        !MTShareSheetClassMatchesExpectedImage(
            applicationExtensionActivityClass) ||
        !MTShareSheetClassMatchesExpectedImage(proxyClass) ||
        !MTShareSheetProviderClassMatchesExpectedImage(providerClass)) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateClassImageMismatch);
        return;
    }

    MTShareSheetHookContract contracts[] = {
        { uiActivityClass, imageSelector, uiActivityImage,
          (IMP)MTShareSheetHookedUIActivityImage,
          (IMP *)&MTShareSheetOriginalUIActivityImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { uiActivityClass, settingsSelector, uiActivitySettings,
          (IMP)MTShareSheetHookedUIActivitySettingsImage,
          (IMP *)&MTShareSheetOriginalUIActivitySettingsImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { applicationExtensionActivityClass, imageSelector,
          applicationExtensionActivityImage,
          (IMP)MTShareSheetHookedApplicationExtensionActivityImage,
          (IMP *)&MTShareSheetOriginalApplicationExtensionActivityImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { applicationExtensionActivityClass, settingsSelector,
          applicationExtensionActivitySettings,
          (IMP)MTShareSheetHookedApplicationExtensionActivitySettingsImage,
          (IMP *)&
              MTShareSheetOriginalApplicationExtensionActivitySettingsImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { proxyClass, imageSelector, proxyImage,
          (IMP)MTShareSheetHookedProxyImage,
          (IMP *)&MTShareSheetOriginalProxyImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { proxyClass, settingsSelector, proxySettings,
          (IMP)MTShareSheetHookedProxySettingsImage,
          (IMP *)&MTShareSheetOriginalProxySettingsImage,
          MTShareSheetImageTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { object_getClass(uiActivityClass), applicationIconSelector,
          activityApplicationIcon,
          (IMP)MTShareSheetHookedActivityApplicationIcon,
          (IMP *)&MTShareSheetOriginalActivityApplicationIcon,
          MTShareSheetApplicationIconTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { object_getClass(uiActivityClass),
          applicationSettingsIconSelector,
          activityApplicationSettingsIcon,
          (IMP)MTShareSheetHookedActivityApplicationSettingsIcon,
          (IMP *)&MTShareSheetOriginalActivityApplicationSettingsIcon,
          MTShareSheetApplicationIconTypeEncoding,
          MTShareSheetImplementationMatchesExpectedImage },
        { providerClass, providerHandleSelector, providerHandle,
          (IMP)MTShareSheetHookedProviderHandle,
          (IMP *)&MTShareSheetOriginalProviderHandle,
          MTShareSheetProviderHandleTypeEncoding,
          MTShareSheetProviderImplementationMatchesExpectedImage },
    };
    // The shared contract table drives one uniform reporting pass; each entry
    // records its encoding and implementation provenance before validation.
    for (NSUInteger index = 0;
         index < sizeof(contracts) / sizeof(contracts[0]); index++) {
        MTShareSheetHookContract *contract = &contracts[index];
        MTRuntimeABIReportProbeMethodType(
            MTAdapterID,
            [NSString stringWithFormat:@"encoding:%s.%s",
                class_getName(contract->targetClass),
                sel_getName(contract->selector)],
            contract->method, contract->typeEncoding);
        MTRuntimeABIReportProbeImplementation(
            MTAdapterID,
            [NSString stringWithFormat:@"impl:%s.%s",
                class_getName(contract->targetClass),
                sel_getName(contract->selector)],
            contract->method == NULL ? NULL :
                method_getImplementation(contract->method));
    }
    for (NSUInteger index = 0;
         index < sizeof(contracts) / sizeof(contracts[0]); index++) {
        MTShareSheetActivityImageAdapterState rejectedState =
            MTShareSheetActivityImageAdapterStateInstalled;
        if (!MTShareSheetValidateHook(&contracts[index], &rejectedState)) {
            MTShareSheetSetState(rejectedState);
            return;
        }
    }
    if (!MTShareSheetPrepareReplacementIfNeeded()) return;

    MTShareSheetProxyClass = proxyClass;
    MTShareSheetApplicationExtensionActivityClass =
        applicationExtensionActivityClass;
    MTShareSheetInstallContracts(
        contracts, sizeof(contracts) / sizeof(contracts[0]));
    MTShareSheetFrameworkProducersInstalled = YES;
}

static void MTShareSheetAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTShareSheetScheduleInstallPass();
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityImageAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    MTShareSheetInstallUIKitProducerIfAvailable();
    if (atomic_load_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation.state,
            memory_order_acquire) !=
            MTShareSheetActivityImageAdapterStateScheduled) {
        return;
    }
    MTShareSheetInstallFrameworkProducersIfAvailable();
    if (MTShareSheetUIKitProducerInstalled &&
        MTShareSheetFrameworkProducersInstalled) {
        MTShareSheetSetState(
            MTShareSheetActivityImageAdapterStateInstalled);
    }
}

BOOL MTShareSheetActivityImageAdapterSchedule(
    MTRuntimeReplacementResolver activityResolver,
    MTRuntimeReplacementResolver applicationIconResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    (void)error;
    if (activityResolver == NULL || applicationIconResolver == NULL ||
        preparation == NULL) {
        return NO;
    }
    uint32_t expected = MTShareSheetActivityImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeShareSheetActivityImageAdapterObservation.state,
            &expected,
            MTShareSheetActivityImageAdapterStateScheduled,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected == MTShareSheetActivityImageAdapterStateScheduled ||
            expected == MTShareSheetActivityImageAdapterStateInstalled;
    }
    MTShareSheetActivityResolver = activityResolver;
    MTShareSheetApplicationIconResolver = applicationIconResolver;
    MTShareSheetReplacementPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTShareSheetActivityImageAdapterStateScheduled,
        @"Scheduled");
    _dyld_register_func_for_add_image(MTShareSheetRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTShareSheetAttemptInstallation();
        }
    } else {
        MTShareSheetScheduleInstallPass();
    }
    return YES;
}
