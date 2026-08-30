#import "MTBadgeNativeSourceAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTBadgeNativeSourceAdapterID =
    @"springboard-home.badge-source";

static const char *const MTBadgeClassName = "SBIconBadgeView";
static const char *const MTImageViewClassName = "UIImageView";
static const char *const MTInitSelectorName = "init";
static const char *const MTInitTypeEncoding = "@16@0:8";
static const char *const MTConfigureSelectorName =
    "configureForIcon:infoProvider:";
static const char *const MTConfigureTypeEncoding = "v32@0:8@16@24";
static const char *const MTAnimatedConfigureSelectorName =
    "configureAnimatedForIcon:infoProvider:animator:";
static const char *const MTAnimatedConfigureTypeEncoding =
    "v40@0:8@16@24@32";
static const char *const MTPrepareForReuseSelectorName = "prepareForReuse";
static const char *const MTPrepareForReuseTypeEncoding = "v16@0:8";
static const char *const MTLayoutSelectorName = "layoutSubviews";
static const char *const MTLayoutTypeEncoding = "v16@0:8";
static const char *const MTBackgroundIvarName = "_backgroundView";
static const char *const MTBackgroundIvarTypeEncoding =
    "@\"SBDarkeningImageView\"";
static const ptrdiff_t MTBackgroundIvarOffsetIOS16 = 416;
static const ptrdiff_t MTBackgroundIvarOffsetIOS16Arm64e = 464;
static const ptrdiff_t MTBackgroundIvarOffsetIOS17 = 432;

typedef id (*MTBadgeInitFunction)(id, SEL);

MTBadgeNativeSourceAdapterObservation
    MTRuntimeBadgeNativeSourceAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTBadgeNativeSourceAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .sourceCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .nativeBackgroundCalls = ATOMIC_VAR_INIT(0),
        .themedBackgrounds = ATOMIC_VAR_INIT(0),
        .nativeFallbacks = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTBadgeNativeSourceAdapterObservation) == 64,
    "Badge native-source observation ABI changed");

static MTBadgeInitFunction MTOriginalBadgeInit;
static MTBadgeNativeBackgroundResolver MTBadgeBackgroundResolver;
static BOOL (*MTBadgeSourcePreparation)(void);
static Class MTBadgeClass = Nil;
static Class MTImageViewClass = Nil;
static Ivar MTBackgroundIvar;
static _Atomic(bool) MTBadgeInstallPassScheduled = false;

static BOOL MTBadgeBackgroundIvarOffsetIsSupported(ptrdiff_t offset) {
    return offset == MTBackgroundIvarOffsetIOS16 ||
        offset == MTBackgroundIvarOffsetIOS16Arm64e ||
        offset == MTBackgroundIvarOffsetIOS17;
}

static BOOL MTBadgeMethodMatches(Method method,
                                 const char *typeEncoding) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static BOOL MTBadgeObjectMatchesClass(id object, Class expectedClass) {
    return object != nil && expectedClass != Nil &&
        MTRuntimeClassIsSubclassOfClass(
            object_getClass(object), expectedClass);
}

static id MTHookedBadgeNativeSource(id self, SEL selector) {
    id badgeView = MTOriginalBadgeInit(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation.sourceCalls,
        1, memory_order_relaxed);
    if (badgeView == nil) return nil;

    if (![NSThread isMainThread] ||
        !MTBadgeObjectMatchesClass(badgeView, MTBadgeClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return badgeView;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);

    id nativeBackground = MTBackgroundIvar == NULL ? nil :
        object_getIvar(badgeView, MTBackgroundIvar);
    if (!MTBadgeObjectMatchesClass(nativeBackground, MTImageViewClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return badgeView;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation
            .nativeBackgroundCalls,
        1, memory_order_relaxed);
    if (MTBadgeBackgroundResolver(badgeView, nativeBackground)) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation
                .themedBackgrounds,
            1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.nativeFallbacks,
            1, memory_order_relaxed);
    }
    return badgeView;
}

static void MTAttemptBadgeSourceInstallation(void);

static void MTScheduleBadgeInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTBadgeNativeSourceAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTBadgeInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTBadgeInstallPassScheduled, false, memory_order_release);
        MTAttemptBadgeSourceInstallation();
    });
}

static void MTBadgeRuntimeImageAdded(const struct mach_header *header,
                                     intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleBadgeInstallPass();
}

static void MTRejectBadgeSourceInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation.state,
        MTBadgeNativeSourceAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTBadgeNativeSourceAdapterID,
        MTBadgeNativeSourceAdapterStateRejected, @"Rejected");
}

static void MTRecordBadgeMethodContract(NSString *contract,
                                        Method method,
                                        const char *encoding) {
    MTRuntimeABIReportProbeMethodType(
        MTBadgeNativeSourceAdapterID,
        [@"encoding:" stringByAppendingString:contract],
        method, encoding);
    MTRuntimeABIReportProbeImplementation(
        MTBadgeNativeSourceAdapterID,
        [@"implementation:" stringByAppendingString:contract],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTAttemptBadgeSourceInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleBadgeInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTBadgeNativeSourceAdapterStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class badgeClass = objc_getClass(MTBadgeClassName);
    Class imageViewClass = objc_getClass(MTImageViewClassName);
    if (badgeClass == Nil || imageViewClass == Nil) return;

    SEL initSelector = sel_registerName(MTInitSelectorName);
    SEL configureSelector = sel_registerName(MTConfigureSelectorName);
    SEL animatedSelector = sel_registerName(
        MTAnimatedConfigureSelectorName);
    SEL reuseSelector = sel_registerName(MTPrepareForReuseSelectorName);
    SEL layoutSelector = sel_registerName(MTLayoutSelectorName);
    Method initMethod = class_getInstanceMethod(badgeClass, initSelector);
    Method configureMethod = class_getInstanceMethod(
        badgeClass, configureSelector);
    Method animatedMethod = class_getInstanceMethod(
        badgeClass, animatedSelector);
    Method reuseMethod = class_getInstanceMethod(badgeClass, reuseSelector);
    Method layoutMethod = class_getInstanceMethod(
        badgeClass, layoutSelector);
    Ivar backgroundIvar = class_getInstanceVariable(
        badgeClass, MTBackgroundIvarName);

    MTRuntimeABIReportProbePresence(
        MTBadgeNativeSourceAdapterID, @"class:SBIconBadgeView", YES);
    MTRuntimeABIReportRecordContract(
        MTBadgeNativeSourceAdapterID, @"image:SBIconBadgeView",
        MTSpringBoardHomeClassMatchesExpectedImage(badgeClass),
        @"SpringBoardHome",
        class_getImageName(badgeClass) == NULL
            ? nil : @(class_getImageName(badgeClass)));
    MTRuntimeABIReportProbePresence(
        MTBadgeNativeSourceAdapterID,
        @"ivar:SBIconBadgeView._backgroundView",
        backgroundIvar != NULL);
    const char *ivarType = backgroundIvar == NULL ? NULL :
        ivar_getTypeEncoding(backgroundIvar);
    MTRuntimeABIReportRecordContract(
        MTBadgeNativeSourceAdapterID,
        @"ivarType:SBIconBadgeView._backgroundView",
        ivarType != NULL &&
            strcmp(ivarType, MTBackgroundIvarTypeEncoding) == 0,
        @(MTBackgroundIvarTypeEncoding),
        ivarType == NULL ? nil : @(ivarType));
    ptrdiff_t ivarOffset = backgroundIvar == NULL ? -1 :
        ivar_getOffset(backgroundIvar);
    MTRuntimeABIReportRecordContract(
        MTBadgeNativeSourceAdapterID,
        @"ivarOffset:SBIconBadgeView._backgroundView",
        MTBadgeBackgroundIvarOffsetIsSupported(ivarOffset),
        [NSString stringWithFormat:@"offset %td, %td, or %td",
            MTBackgroundIvarOffsetIOS16,
            MTBackgroundIvarOffsetIOS16Arm64e,
            MTBackgroundIvarOffsetIOS17],
        [NSString stringWithFormat:@"offset %td", ivarOffset]);
    MTRecordBadgeMethodContract(
        @"SBIconBadgeView.init", initMethod, MTInitTypeEncoding);
    MTRecordBadgeMethodContract(
        @"SBIconBadgeView.configureForIcon:infoProvider:",
        configureMethod, MTConfigureTypeEncoding);
    MTRecordBadgeMethodContract(
        @"SBIconBadgeView.configureAnimatedForIcon:infoProvider:animator:",
        animatedMethod, MTAnimatedConfigureTypeEncoding);
    MTRecordBadgeMethodContract(
        @"SBIconBadgeView.prepareForReuse",
        reuseMethod, MTPrepareForReuseTypeEncoding);
    MTRecordBadgeMethodContract(
        @"SBIconBadgeView.layoutSubviews",
        layoutMethod, MTLayoutTypeEncoding);

    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(badgeClass) &&
        MTBadgeMethodMatches(initMethod, MTInitTypeEncoding) &&
        MTBadgeMethodMatches(configureMethod, MTConfigureTypeEncoding) &&
        MTBadgeMethodMatches(
            animatedMethod, MTAnimatedConfigureTypeEncoding) &&
        MTBadgeMethodMatches(
            reuseMethod, MTPrepareForReuseTypeEncoding) &&
        MTBadgeMethodMatches(layoutMethod, MTLayoutTypeEncoding) &&
        ivarType != NULL &&
        strcmp(ivarType, MTBackgroundIvarTypeEncoding) == 0 &&
        MTBadgeBackgroundIvarOffsetIsSupported(ivarOffset) &&
        MTBadgeSourcePreparation();
    if (!valid) {
        MTRejectBadgeSourceInstallation();
        return;
    }

    MTBadgeClass = badgeClass;
    MTImageViewClass = imageViewClass;
    MTBackgroundIvar = backgroundIvar;
    MTOriginalBadgeInit = (MTBadgeInitFunction)
        method_getImplementation(initMethod);
    MSHookMessageEx(
        badgeClass, initSelector, (IMP)MTHookedBadgeNativeSource,
        (IMP *)&MTOriginalBadgeInit);
    if (MTOriginalBadgeInit == NULL) {
        MTRejectBadgeSourceInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeBadgeNativeSourceAdapterObservation.state,
        MTBadgeNativeSourceAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTBadgeNativeSourceAdapterID,
        MTBadgeNativeSourceAdapterStateInstalled, @"Installed");
}

BOOL MTBadgeNativeSourceAdapterSchedule(
    MTBadgeNativeBackgroundResolver resolver,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTBadgeNativeSourceAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeBadgeNativeSourceAdapterObservation.state,
            &expected, MTBadgeNativeSourceAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTBadgeNativeSourceAdapterStateScheduled ||
            expected == MTBadgeNativeSourceAdapterStateInstalled;
    }
    MTBadgeBackgroundResolver = resolver;
    MTBadgeSourcePreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTBadgeNativeSourceAdapterID,
        MTBadgeNativeSourceAdapterStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTBadgeRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptBadgeSourceInstallation();
    } else {
        MTScheduleBadgeInstallPass();
    }
    return YES;
}
