#import "MTBadgeBackgroundImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.badge-background";
static const char *const MTBadgeClassName = "SBIconBadgeView";
static const char *const MTConfigureSelectorName =
    "configureForIcon:infoProvider:";
static const char *const MTConfigureTypeEncoding = "v32@0:8@16@24";
static const char *const MTAnimatedConfigureSelectorName =
    "configureAnimatedForIcon:infoProvider:animator:";
static const char *const MTAnimatedConfigureTypeEncoding =
    "v40@0:8@16@24@32";
static const char *const MTPrepareForReuseSelectorName = "prepareForReuse";
static const char *const MTPrepareForReuseTypeEncoding = "v16@0:8";
static const char *const MTBackgroundIvarName = "_backgroundView";
static const char *const MTBackgroundIvarTypeEncoding =
    "@\"SBDarkeningImageView\"";
static const ptrdiff_t MTBackgroundIvarOffsetIOS16 = 416;
static const ptrdiff_t MTBackgroundIvarOffsetIOS17 = 432;
static const char *const MTImageViewClassName = "UIImageView";
static const char *const MTImageGetterName = "image";
static const char *const MTImageGetterTypeEncoding = "@16@0:8";
static const char *const MTImageSetterName = "setImage:";
static const char *const MTImageSetterTypeEncoding = "v24@0:8@16";

typedef void (*MTConfigureFunction)(id, SEL, id, id);
typedef void (*MTAnimatedConfigureFunction)(id, SEL, id, id, id);
typedef void (*MTPrepareForReuseFunction)(id, SEL);
typedef id (*MTImageGetterFunction)(id, SEL);
typedef void (*MTImageSetterFunction)(id, SEL, id);

MTBadgeBackgroundImageAdapterObservation
    MTRuntimeBadgeBackgroundImageAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(
            MTBadgeBackgroundImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .configureCalls = ATOMIC_VAR_INIT(0),
        .animatedConfigureCalls = ATOMIC_VAR_INIT(0),
        .reuseCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshExecutions = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTBadgeBackgroundImageAdapterObservation) == 80,
    "The Badge ProcessAdapter observation layout must remain fixed.");

static MTConfigureFunction MTOriginalConfigure;
static MTAnimatedConfigureFunction MTOriginalAnimatedConfigure;
static MTPrepareForReuseFunction MTOriginalPrepareForReuse;
static MTBadgeBackgroundImageResolver MTImageResolver;
static MTBadgeViewForgetter MTViewForgetter;
static NSHashTable *MTBadgeViews;
static Class MTBadgeClass = Nil;
static Class MTImageViewClass = Nil;
static Ivar MTBackgroundIvar;
static SEL MTImageGetterSelector;
static SEL MTImageSetterSelector;
static MTImageGetterFunction MTImageGetter;
static MTImageSetterFunction MTImageSetter;

static BOOL MTBackgroundIvarOffsetIsSupported(ptrdiff_t offset) {
    return offset == MTBackgroundIvarOffsetIOS16 ||
        offset == MTBackgroundIvarOffsetIOS17;
}

static id MTBadgeBackgroundView(id badgeView) {
    id background = MTBackgroundIvar == NULL ? nil :
        object_getIvar(badgeView, MTBackgroundIvar);
    return background != nil && MTRuntimeClassIsSubclassOfClass(
        object_getClass(background), MTImageViewClass) ? background : nil;
}

static void MTBadgeApplyBackground(id badgeView) {
    if (MTImageResolver == nil || MTImageGetter == NULL ||
        MTImageSetter == NULL) return;
    id backgroundView = MTBadgeBackgroundView(badgeView);
    if (backgroundView == nil) return;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id originalImage = MTImageGetter(
        backgroundView, MTImageGetterSelector);
    id replacement = MTImageResolver(
        badgeView, backgroundView, originalImage, &didReplace);
    if (!didReplace || replacement == originalImage) return;
    MTImageSetter(backgroundView, MTImageSetterSelector, replacement);
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation
             .replacementResults,
        1, memory_order_relaxed);
}

static void MTHookedConfigure(id self, SEL selector,
                              id icon, id infoProvider) {
    MTOriginalConfigure(self, selector, icon, infoProvider);
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.configureCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    [MTBadgeViews addObject:self];
    MTBadgeApplyBackground(self);
}

static void MTHookedAnimatedConfigure(id self, SEL selector,
                                      id icon, id infoProvider, id animator) {
    MTOriginalAnimatedConfigure(self, selector, icon, infoProvider, animator);
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation
             .animatedConfigureCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    [MTBadgeViews addObject:self];
    MTBadgeApplyBackground(self);
}

static void MTHookedPrepareForReuse(id self, SEL selector) {
    MTOriginalPrepareForReuse(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.reuseCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    id backgroundView = MTBadgeBackgroundView(self);
    if (MTViewForgetter != nil) MTViewForgetter(self, backgroundView);
    [MTBadgeViews removeObject:self];
}

static void MTBadgeAttemptInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class badgeClass = objc_getClass(MTBadgeClassName);
    Class imageViewClass = objc_getClass(MTImageViewClassName);
    SEL configureSelector = sel_registerName(MTConfigureSelectorName);
    SEL animatedSelector = sel_registerName(
        MTAnimatedConfigureSelectorName);
    SEL reuseSelector = sel_registerName(MTPrepareForReuseSelectorName);
    Method configureMethod = badgeClass == Nil ? NULL :
        class_getInstanceMethod(badgeClass, configureSelector);
    Method animatedMethod = badgeClass == Nil ? NULL :
        class_getInstanceMethod(badgeClass, animatedSelector);
    Method reuseMethod = badgeClass == Nil ? NULL :
        class_getInstanceMethod(badgeClass, reuseSelector);
    Ivar backgroundIvar = badgeClass == Nil ? NULL :
        class_getInstanceVariable(badgeClass, MTBackgroundIvarName);
    SEL imageGetterSelector = sel_registerName(MTImageGetterName);
    SEL imageSetterSelector = sel_registerName(MTImageSetterName);
    Method imageGetterMethod = imageViewClass == Nil ? NULL :
        class_getInstanceMethod(imageViewClass, imageGetterSelector);
    Method imageSetterMethod = imageViewClass == Nil ? NULL :
        class_getInstanceMethod(imageViewClass, imageSetterSelector);
    if (configureMethod == NULL || animatedMethod == NULL ||
        reuseMethod == NULL || backgroundIvar == NULL ||
        imageGetterMethod == NULL || imageSetterMethod == NULL) {
        atomic_store_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
            MTBadgeBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTBadgeBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }

    const char *configureType = method_getTypeEncoding(configureMethod);
    const char *animatedType = method_getTypeEncoding(animatedMethod);
    const char *reuseType = method_getTypeEncoding(reuseMethod);
    const char *ivarType = ivar_getTypeEncoding(backgroundIvar);
    const char *imageGetterType = method_getTypeEncoding(imageGetterMethod);
    const char *imageSetterType = method_getTypeEncoding(imageSetterMethod);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBIconBadgeView", badgeClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIImageView", imageViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"ivar:SBIconBadgeView._backgroundView",
        backgroundIvar != NULL);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBIconBadgeView.configureForIcon:infoProvider:",
        configureMethod, MTConfigureTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBIconBadgeView."
         "configureAnimatedForIcon:infoProvider:animator:",
        animatedMethod, MTAnimatedConfigureTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconBadgeView.prepareForReuse",
        reuseMethod, MTPrepareForReuseTypeEncoding);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"ivarType:SBIconBadgeView._backgroundView",
        ivarType != NULL &&
            strcmp(ivarType, MTBackgroundIvarTypeEncoding) == 0,
        @(MTBackgroundIvarTypeEncoding),
        ivarType == NULL ? nil : @(ivarType));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"ivarOffset:SBIconBadgeView._backgroundView",
        MTBackgroundIvarOffsetIsSupported(ivar_getOffset(backgroundIvar)),
        [NSString stringWithFormat:@"offset %td or %td",
            MTBackgroundIvarOffsetIOS16, MTBackgroundIvarOffsetIOS17],
        [NSString stringWithFormat:@"offset %td",
            ivar_getOffset(backgroundIvar)]);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:UIImageView.image",
        imageGetterMethod, MTImageGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:UIImageView.setImage:",
        imageSetterMethod, MTImageSetterTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconBadgeView.configureForIcon:infoProvider:",
        method_getImplementation(configureMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID,
        @"impl:SBIconBadgeView."
         "configureAnimatedForIcon:infoProvider:animator:",
        method_getImplementation(animatedMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconBadgeView.prepareForReuse",
        method_getImplementation(reuseMethod));
    BOOL valid = MTSpringBoardHomeClassMatchesExpectedImage(badgeClass) &&
        configureType != NULL &&
        strcmp(configureType, MTConfigureTypeEncoding) == 0 &&
        animatedType != NULL &&
        strcmp(animatedType, MTAnimatedConfigureTypeEncoding) == 0 &&
        reuseType != NULL &&
        strcmp(reuseType, MTPrepareForReuseTypeEncoding) == 0 &&
        ivarType != NULL &&
        strcmp(ivarType, MTBackgroundIvarTypeEncoding) == 0 &&
        MTBackgroundIvarOffsetIsSupported(ivar_getOffset(backgroundIvar)) &&
        imageGetterType != NULL &&
        strcmp(imageGetterType, MTImageGetterTypeEncoding) == 0 &&
        imageSetterType != NULL &&
        strcmp(imageSetterType, MTImageSetterTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(configureMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(animatedMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(reuseMethod));
    if (!valid) {
        atomic_store_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
            MTBadgeBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTBadgeBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }

    MTBadgeClass = badgeClass;
    MTImageViewClass = imageViewClass;
    MTBackgroundIvar = backgroundIvar;
    MTImageGetterSelector = imageGetterSelector;
    MTImageSetterSelector = imageSetterSelector;
    MTImageGetter = (MTImageGetterFunction)
        method_getImplementation(imageGetterMethod);
    MTImageSetter = (MTImageSetterFunction)
        method_getImplementation(imageSetterMethod);
    MTBadgeViews = [NSHashTable weakObjectsHashTable];
    MTOriginalConfigure = (MTConfigureFunction)
        method_getImplementation(configureMethod);
    MTOriginalAnimatedConfigure = (MTAnimatedConfigureFunction)
        method_getImplementation(animatedMethod);
    MTOriginalPrepareForReuse = (MTPrepareForReuseFunction)
        method_getImplementation(reuseMethod);
    MSHookMessageEx(badgeClass, configureSelector,
        (IMP)MTHookedConfigure, (IMP *)&MTOriginalConfigure);
    MSHookMessageEx(badgeClass, animatedSelector,
        (IMP)MTHookedAnimatedConfigure,
        (IMP *)&MTOriginalAnimatedConfigure);
    MSHookMessageEx(badgeClass, reuseSelector,
        (IMP)MTHookedPrepareForReuse,
        (IMP *)&MTOriginalPrepareForReuse);
    if (MTOriginalConfigure == NULL ||
        MTOriginalAnimatedConfigure == NULL ||
        MTOriginalPrepareForReuse == NULL || MTImageGetter == NULL ||
        MTImageSetter == NULL) {
        atomic_store_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
            MTBadgeBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTBadgeBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
        MTBadgeBackgroundImageAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTBadgeBackgroundImageAdapterStateInstalled,
        @"Installed");
}

BOOL MTBadgeBackgroundImageAdapterSchedule(
    MTBadgeBackgroundImageResolver resolver,
    MTBadgeViewForgetter forgetter,
    NSError **error) {
    (void)error;
    if (resolver == nil || forgetter == nil) return NO;
    uint32_t expected = MTBadgeBackgroundImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
            &expected, MTBadgeBackgroundImageAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTBadgeBackgroundImageAdapterStateScheduled ||
            expected == MTBadgeBackgroundImageAdapterStateInstalled;
    }
    MTImageResolver = resolver;
    MTViewForgetter = forgetter;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTBadgeBackgroundImageAdapterStateScheduled,
        @"Scheduled");
    // Cross one deterministic main-queue boundary before reading private
    // class metadata or installing Hooks. This returns the dylib constructor
    // immediately and does not use a timer, fixed delay, or retry loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        MTBadgeAttemptInstallation();
    });
    return YES;
}

void MTBadgeBackgroundImageAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeBackgroundImageAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation.state,
            memory_order_acquire) !=
            MTBadgeBackgroundImageAdapterStateInstalled) {
        return;
    }
    for (id badgeView in MTBadgeViews.allObjects) {
        if (!MTRuntimeClassIsSubclassOfClass(
                object_getClass(badgeView), MTBadgeClass)) continue;
        MTBadgeApplyBackground(badgeView);
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeBackgroundImageAdapterObservation
                 .refreshExecutions,
            1, memory_order_relaxed);
    }
}
