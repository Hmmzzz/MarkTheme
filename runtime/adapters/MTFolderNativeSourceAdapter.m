#import "MTFolderNativeSourceAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTFolderNativeSourceAdapterID =
    @"springboard-home.folder-icon-source";

static const char *const MTIconViewClassName = "SBIconView";
static const char *const MTIconImageViewClassName = "SBIconImageView";
static const char *const MTFolderImageViewClassName =
    "SBFolderIconImageView";
static const char *const MTIconViewConfigureSelectorName =
    "_configureIconImageView:";
static const char *const MTIconViewConfigureTypeEncoding = "v24@0:8@16";
static const char *const MTBackgroundFactorySelectorName =
    "newComponentBackgroundViewOfType:";
static const char *const MTBackgroundFactoryTypeEncoding = "@24@0:8q16";
static const char *const MTBackgroundFallbackFactorySelectorName =
    "componentBackgroundViewOfType:compatibleWithTraitCollection:"
    "initialWeighting:";
static const char *const MTBackgroundFallbackFactoryTypeEncoding =
    "@40@0:8q16@24d32";
static const char *const MTBackgroundGetterSelectorName = "backgroundView";
static const char *const MTBackgroundGetterTypeEncoding = "@16@0:8";
static const char *const MTBackgroundSetterSelectorName =
    "setBackgroundView:";
static const char *const MTBackgroundSetterTypeEncoding = "v24@0:8@16";

typedef id (*MTFolderBackgroundGetterFunction)(id, SEL);
typedef void (*MTFolderBackgroundSetterFunction)(id, SEL, id);

MTFolderNativeSourceAdapterObservation
    MTRuntimeFolderNativeSourceAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTFolderNativeSourceAdapterStateDormant),
        .sourceCalls = ATOMIC_VAR_INIT(0),
        .nativeBackgroundCalls = ATOMIC_VAR_INIT(0),
        .nilBackgroundCalls = ATOMIC_VAR_INIT(0),
        .themedBackgrounds = ATOMIC_VAR_INIT(0),
        .overlayActivations = ATOMIC_VAR_INIT(0),
        .nativeFallbacks = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTFolderNativeSourceAdapterObservation) == 64,
    "Folder native-source observation ABI changed");

static MTFolderBackgroundGetterFunction MTOriginalFolderBackgroundGetter;
static MTFolderBackgroundSetterFunction MTOriginalFolderBackgroundSetter;
static MTFolderNativeBackgroundResolver MTFolderBackgroundResolver;
static MTFolderNativeOverlayResolver MTFolderOverlayResolver;
static BOOL (*MTFolderSourcePreparation)(void);
static Class MTUIViewClass = Nil;
static SEL MTFolderBackgroundGetterSelector;
static _Atomic(bool) MTFolderInstallPassScheduled = false;

static BOOL MTFolderMethodMatches(Method method,
                                  const char *typeEncoding) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static BOOL MTFolderObjectIsView(id object) {
    return object != nil && MTUIViewClass != Nil &&
        MTRuntimeClassIsSubclassOfClass(
            object_getClass(object), MTUIViewClass);
}

static void MTHookedFolderBackgroundSource(id self,
                                           SEL selector,
                                           id nativeBackground) {
    atomic_fetch_add_explicit(
        &MTRuntimeFolderNativeSourceAdapterObservation.sourceCalls,
        1, memory_order_relaxed);

    if (![NSThread isMainThread]) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        MTOriginalFolderBackgroundSetter(self, selector, nativeBackground);
        return;
    }

    id resolvedBackground = nativeBackground;
    if (nativeBackground == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation
                .nilBackgroundCalls,
            1, memory_order_relaxed);
    } else if (!MTFolderObjectIsView(nativeBackground)) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation
                .nativeBackgroundCalls,
            1, memory_order_relaxed);
        id replacement = MTFolderBackgroundResolver(
            self, nativeBackground);
        if (replacement != nil && replacement != nativeBackground &&
            MTFolderObjectIsView(replacement)) {
            resolvedBackground = replacement;
            atomic_fetch_add_explicit(
                &MTRuntimeFolderNativeSourceAdapterObservation
                    .themedBackgrounds,
                1, memory_order_relaxed);
        } else {
            if (replacement != nil && replacement != nativeBackground) {
                atomic_fetch_add_explicit(
                    &MTRuntimeFolderNativeSourceAdapterObservation
                        .contractRejects,
                    1, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(
                    &MTRuntimeFolderNativeSourceAdapterObservation
                        .nativeFallbacks,
                    1, memory_order_relaxed);
            }
        }
    }

    // Apple remains the sole owner of removal, retention, corner semantics,
    // subview insertion, and future style/animation updates.
    MTOriginalFolderBackgroundSetter(
        self, selector, resolvedBackground);
    id installedBackground = MTOriginalFolderBackgroundGetter(
        self, MTFolderBackgroundGetterSelector);
    if (MTFolderOverlayResolver(self, installedBackground)) {
        atomic_fetch_add_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation
                .overlayActivations,
            1, memory_order_relaxed);
    }
}

static void MTAttemptFolderSourceInstallation(void);

static void MTScheduleFolderInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTFolderNativeSourceAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTFolderInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTFolderInstallPassScheduled, false, memory_order_release);
        MTAttemptFolderSourceInstallation();
    });
}

static void MTFolderRuntimeImageAdded(const struct mach_header *header,
                                      intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleFolderInstallPass();
}

static void MTRejectFolderSourceInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeFolderNativeSourceAdapterObservation.state,
        MTFolderNativeSourceAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTFolderNativeSourceAdapterID,
        MTFolderNativeSourceAdapterStateRejected, @"Rejected");
}

static void MTRecordFolderMethodContract(NSString *contract,
                                         Method method,
                                         const char *encoding) {
    MTRuntimeABIReportProbeMethodType(
        MTFolderNativeSourceAdapterID,
        [@"encoding:" stringByAppendingString:contract],
        method, encoding);
    MTRuntimeABIReportProbeImplementation(
        MTFolderNativeSourceAdapterID,
        [@"implementation:" stringByAppendingString:contract],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTAttemptFolderSourceInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleFolderInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTFolderNativeSourceAdapterStateScheduled) {
        return;
    }

    Class iconViewClass = objc_getClass(MTIconViewClassName);
    Class iconImageViewClass = objc_getClass(MTIconImageViewClassName);
    Class folderImageViewClass = objc_getClass(MTFolderImageViewClassName);
    Class uiViewClass = objc_getClass("UIView");
    if (iconViewClass == Nil || iconImageViewClass == Nil ||
        folderImageViewClass == Nil || uiViewClass == Nil) {
        return;
    }

    SEL configureSelector = sel_registerName(
        MTIconViewConfigureSelectorName);
    SEL factorySelector = sel_registerName(
        MTBackgroundFactorySelectorName);
    SEL fallbackFactorySelector = sel_registerName(
        MTBackgroundFallbackFactorySelectorName);
    SEL getterSelector = sel_registerName(
        MTBackgroundGetterSelectorName);
    SEL setterSelector = sel_registerName(
        MTBackgroundSetterSelectorName);
    Method configureMethod = class_getInstanceMethod(
        iconViewClass, configureSelector);
    Method factoryMethod = class_getInstanceMethod(
        iconViewClass, factorySelector);
    Method fallbackFactoryMethod = class_getClassMethod(
        iconViewClass, fallbackFactorySelector);
    Method getterMethod = class_getInstanceMethod(
        folderImageViewClass, getterSelector);
    Method setterMethod = class_getInstanceMethod(
        folderImageViewClass, setterSelector);

    MTRuntimeABIReportProbePresence(
        MTFolderNativeSourceAdapterID, @"class:SBIconView", YES);
    MTRuntimeABIReportProbePresence(
        MTFolderNativeSourceAdapterID,
        @"class:SBFolderIconImageView", YES);
    MTRuntimeABIReportRecordContract(
        MTFolderNativeSourceAdapterID, @"image:SBIconView",
        MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass),
        @"SpringBoardHome",
        class_getImageName(iconViewClass) == NULL
            ? nil : @(class_getImageName(iconViewClass)));
    MTRuntimeABIReportRecordContract(
        MTFolderNativeSourceAdapterID,
        @"image:SBFolderIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(folderImageViewClass),
        @"SpringBoardHome",
        class_getImageName(folderImageViewClass) == NULL
            ? nil : @(class_getImageName(folderImageViewClass)));
    BOOL expectedSuperclass = MTRuntimeClassIsSubclassOfClass(
        folderImageViewClass, iconImageViewClass);
    MTRuntimeABIReportRecordContract(
        MTFolderNativeSourceAdapterID,
        @"hierarchy:SBFolderIconImageView<SBIconImageView",
        expectedSuperclass, @"SBIconImageView",
        class_getSuperclass(folderImageViewClass) == Nil
            ? nil : @(class_getName(class_getSuperclass(
                folderImageViewClass))));
    MTRecordFolderMethodContract(
        @"SBIconView._configureIconImageView:",
        configureMethod, MTIconViewConfigureTypeEncoding);
    MTRecordFolderMethodContract(
        @"SBIconView.newComponentBackgroundViewOfType:",
        factoryMethod, MTBackgroundFactoryTypeEncoding);
    MTRecordFolderMethodContract(
        @"SBIconView.componentBackgroundViewOfType:"
         "compatibleWithTraitCollection:initialWeighting:",
        fallbackFactoryMethod,
        MTBackgroundFallbackFactoryTypeEncoding);
    MTRecordFolderMethodContract(
        @"SBFolderIconImageView.backgroundView",
        getterMethod, MTBackgroundGetterTypeEncoding);
    MTRecordFolderMethodContract(
        @"SBFolderIconImageView.setBackgroundView:",
        setterMethod, MTBackgroundSetterTypeEncoding);

    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(iconImageViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(folderImageViewClass) &&
        expectedSuperclass &&
        MTFolderMethodMatches(
            configureMethod, MTIconViewConfigureTypeEncoding) &&
        MTFolderMethodMatches(
            factoryMethod, MTBackgroundFactoryTypeEncoding) &&
        MTFolderMethodMatches(
            fallbackFactoryMethod,
            MTBackgroundFallbackFactoryTypeEncoding) &&
        MTFolderMethodMatches(
            getterMethod, MTBackgroundGetterTypeEncoding) &&
        MTFolderMethodMatches(
            setterMethod, MTBackgroundSetterTypeEncoding) &&
        MTFolderSourcePreparation();
    if (!valid) {
        MTRejectFolderSourceInstallation();
        return;
    }

    MTUIViewClass = uiViewClass;
    MTFolderBackgroundGetterSelector = getterSelector;
    MTOriginalFolderBackgroundGetter = (MTFolderBackgroundGetterFunction)
        method_getImplementation(getterMethod);
    MTOriginalFolderBackgroundSetter = (MTFolderBackgroundSetterFunction)
        method_getImplementation(setterMethod);
    MSHookMessageEx(
        folderImageViewClass, setterSelector,
        (IMP)MTHookedFolderBackgroundSource,
        (IMP *)&MTOriginalFolderBackgroundSetter);
    if (MTOriginalFolderBackgroundGetter == NULL ||
        MTOriginalFolderBackgroundSetter == NULL) {
        MTRejectFolderSourceInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeFolderNativeSourceAdapterObservation.state,
        MTFolderNativeSourceAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTFolderNativeSourceAdapterID,
        MTFolderNativeSourceAdapterStateInstalled, @"Installed");
}

BOOL MTFolderNativeSourceAdapterSchedule(
    MTFolderNativeBackgroundResolver backgroundResolver,
    MTFolderNativeOverlayResolver overlayResolver,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (backgroundResolver == NULL || overlayResolver == NULL ||
        preparation == NULL) {
        return NO;
    }
    uint32_t expected = MTFolderNativeSourceAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeFolderNativeSourceAdapterObservation.state,
            &expected, MTFolderNativeSourceAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTFolderNativeSourceAdapterStateScheduled ||
            expected == MTFolderNativeSourceAdapterStateInstalled;
    }
    MTFolderBackgroundResolver = backgroundResolver;
    MTFolderOverlayResolver = overlayResolver;
    MTFolderSourcePreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTFolderNativeSourceAdapterID,
        MTFolderNativeSourceAdapterStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTFolderRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptFolderSourceInstallation();
    } else {
        MTScheduleFolderInstallPass();
    }
    return YES;
}
