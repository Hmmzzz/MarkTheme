#import "MTIconShadowCarrierAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTIconShadowCarrierAdapterID =
    @"springboard-home.icon-shadow-carrier";

static const char *const MTIconImageViewClassName = "SBIconImageView";
static const char *const MTFolderIconImageViewClassName =
    "SBFolderIconImageView";
static const char *const MTLayoutSelectorName = "layoutSubviews";
static const char *const MTReuseSelectorName = "prepareForReuse";
static const char *const MTSetIconSelectorName =
    "setIcon:location:animated:";
static const char *const MTVoidMethodTypeEncoding = "v16@0:8";
static const char *const MTSetIconMethodTypeEncoding =
    "v36@0:8@16@24B32";

typedef void (*MTIconShadowCarrierVoidFunction)(id, SEL);
typedef void (*MTIconShadowCarrierSetIconFunction)(
    id, SEL, id, id, BOOL);

MTIconShadowCarrierAdapterObservation
    MTRuntimeIconShadowCarrierAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(MTIconShadowCarrierAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .layoutCalls = ATOMIC_VAR_INIT(0),
        .reuseCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .folderExclusions = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .appliedResults = ATOMIC_VAR_INIT(0),
        .cleanupCalls = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTIconShadowCarrierAdapterObservation) == 80,
    "Icon Shadow carrier observation ABI changed");

static MTIconShadowCarrierVoidFunction MTOriginalCarrierLayout;
static MTIconShadowCarrierVoidFunction MTOriginalCarrierReuse;
static MTIconShadowCarrierSetIconFunction MTOriginalCarrierSetIcon;
static MTIconShadowCarrierResolver MTShadowResolver;
static MTIconShadowCarrierCleaner MTShadowCleaner;
static BOOL (*MTShadowPreparation)(void);
static Class MTIconImageViewClass = Nil;
static Class MTFolderIconImageViewClass = Nil;
static _Atomic(bool) MTInstallPassScheduled = false;

static BOOL MTIconShadowCarrierMatchesClass(id object, Class expectedClass) {
    return object != nil && expectedClass != Nil &&
        MTRuntimeClassIsSubclassOfClass(
            object_getClass(object), expectedClass);
}

static void MTIconShadowCleanCarrier(id carrier) {
    if (MTShadowCleaner == NULL) return;
    MTShadowCleaner(carrier);
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.cleanupCalls,
        1, memory_order_relaxed);
}

static void MTIconShadowResolveCarrier(id carrier) {
    if (![NSThread isMainThread] ||
        !MTIconShadowCarrierMatchesClass(carrier, MTIconImageViewClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    if (MTIconShadowCarrierMatchesClass(
            carrier, MTFolderIconImageViewClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.folderExclusions,
            1, memory_order_relaxed);
        MTIconShadowCleanCarrier(carrier);
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    if (MTShadowResolver != NULL && MTShadowResolver(carrier)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.appliedResults,
            1, memory_order_relaxed);
    }
}

static void MTHookedIconShadowCarrierLayout(id self, SEL selector) {
    MTOriginalCarrierLayout(self, selector);
    uint64_t call = atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.layoutCalls,
        1, memory_order_relaxed) + 1;
    if (call == 1 || call == 64 || call == 256) {
        MTRuntimeABIReportRecordSample(
            @"springboard-home.icon-shadow-carrier.layout",
            @{ @"call" : @(call) });
    }
    MTIconShadowResolveCarrier(self);
}

static void MTHookedIconShadowCarrierReuse(id self, SEL selector) {
    MTOriginalCarrierReuse(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.reuseCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTIconShadowCarrierMatchesClass(self, MTIconImageViewClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTIconShadowCleanCarrier(self);
}

static void MTHookedIconShadowCarrierSetIcon(
    id self,
    SEL selector,
    id icon,
    id location,
    BOOL animated) {
    MTOriginalCarrierSetIcon(
        self, selector, icon, location, animated);
    // Same-size carriers can be reused without another layout pass. The
    // native icon-identity assignment is therefore the reliable complement
    // to prepareForReuse cleanup. If hierarchy insertion is still pending,
    // layout remains the authoritative later retry.
    if (icon == nil) {
        MTIconShadowCleanCarrier(self);
    } else {
        MTIconShadowResolveCarrier(self);
    }
}

static BOOL MTIconShadowMethodMatches(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL &&
        strcmp(encoding, MTVoidMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static NSString *MTIconShadowImageName(Class runtimeClass) {
    const char *imageName = runtimeClass == Nil ? NULL :
        class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static void MTRejectIconShadowCarrierInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.state,
        MTIconShadowCarrierAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTIconShadowCarrierAdapterID,
        MTIconShadowCarrierAdapterStateRejected, @"Rejected");
}

static void MTRecordIconShadowMethod(NSString *contract,
                                     Method method) {
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        [@"encoding:" stringByAppendingString:contract],
        method, MTVoidMethodTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTIconShadowCarrierAdapterID,
        [@"implementation:" stringByAppendingString:contract],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTAttemptIconShadowCarrierInstallation(void);

static void MTScheduleIconShadowCarrierInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.state,
            memory_order_acquire) !=
        MTIconShadowCarrierAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTInstallPassScheduled, false, memory_order_release);
        MTAttemptIconShadowCarrierInstallation();
    });
}

static void MTIconShadowRuntimeImageAdded(const struct mach_header *header,
                                          intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleIconShadowCarrierInstallPass();
}

static void MTAttemptIconShadowCarrierInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleIconShadowCarrierInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.state,
            memory_order_acquire) !=
        MTIconShadowCarrierAdapterStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class imageViewClass = objc_getClass(MTIconImageViewClassName);
    Class folderClass = objc_getClass(MTFolderIconImageViewClassName);
    if (imageViewClass == Nil || folderClass == Nil) return;

    SEL layoutSelector = sel_registerName(MTLayoutSelectorName);
    SEL reuseSelector = sel_registerName(MTReuseSelectorName);
    SEL setIconSelector = sel_registerName(MTSetIconSelectorName);
    Method layoutMethod = class_getInstanceMethod(
        imageViewClass, layoutSelector);
    Method reuseMethod = class_getInstanceMethod(
        imageViewClass, reuseSelector);
    Method setIconMethod = class_getInstanceMethod(
        imageViewClass, setIconSelector);

    MTRuntimeABIReportProbePresence(
        MTIconShadowCarrierAdapterID,
        @"class:SBIconImageView", imageViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTIconShadowCarrierAdapterID,
        @"class:SBFolderIconImageView", folderClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTIconShadowCarrierAdapterID, @"image:SBIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(imageViewClass),
        @"SpringBoardHome", MTIconShadowImageName(imageViewClass));
    MTRuntimeABIReportRecordContract(
        MTIconShadowCarrierAdapterID, @"image:SBFolderIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(folderClass),
        @"SpringBoardHome", MTIconShadowImageName(folderClass));
    MTRuntimeABIReportRecordContract(
        MTIconShadowCarrierAdapterID,
        @"hierarchy:SBFolderIconImageView<SBIconImageView",
        MTRuntimeClassIsSubclassOfClass(folderClass, imageViewClass),
        @"SBFolderIconImageView subclass of SBIconImageView",
        MTRuntimeClassIsSubclassOfClass(folderClass, imageViewClass)
            ? @"matched" : @"mismatched");
    MTRecordIconShadowMethod(
        @"SBIconImageView.layoutSubviews", layoutMethod);
    MTRecordIconShadowMethod(
        @"SBIconImageView.prepareForReuse", reuseMethod);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconImageView.setIcon:location:animated:",
        setIconMethod, MTSetIconMethodTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTIconShadowCarrierAdapterID,
        @"implementation:SBIconImageView.setIcon:location:animated:",
        setIconMethod == NULL ? NULL :
            method_getImplementation(setIconMethod));

    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(imageViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(folderClass) &&
        MTRuntimeClassIsSubclassOfClass(folderClass, imageViewClass) &&
        MTIconShadowMethodMatches(layoutMethod) &&
        MTIconShadowMethodMatches(reuseMethod) &&
        setIconMethod != NULL &&
        strcmp(method_getTypeEncoding(setIconMethod),
               MTSetIconMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(setIconMethod)) &&
        MTShadowPreparation != NULL && MTShadowPreparation();
    if (!valid) {
        MTRejectIconShadowCarrierInstallation();
        return;
    }

    MTIconImageViewClass = imageViewClass;
    MTFolderIconImageViewClass = folderClass;
    MTOriginalCarrierLayout = (MTIconShadowCarrierVoidFunction)
        method_getImplementation(layoutMethod);
    MTOriginalCarrierReuse = (MTIconShadowCarrierVoidFunction)
        method_getImplementation(reuseMethod);
    MTOriginalCarrierSetIcon = (MTIconShadowCarrierSetIconFunction)
        method_getImplementation(setIconMethod);
    MSHookMessageEx(
        imageViewClass, layoutSelector,
        (IMP)MTHookedIconShadowCarrierLayout,
        (IMP *)&MTOriginalCarrierLayout);
    MSHookMessageEx(
        imageViewClass, reuseSelector,
        (IMP)MTHookedIconShadowCarrierReuse,
        (IMP *)&MTOriginalCarrierReuse);
    MSHookMessageEx(
        imageViewClass, setIconSelector,
        (IMP)MTHookedIconShadowCarrierSetIcon,
        (IMP *)&MTOriginalCarrierSetIcon);
    if (MTOriginalCarrierLayout == NULL ||
        MTOriginalCarrierReuse == NULL ||
        MTOriginalCarrierSetIcon == NULL) {
        MTRejectIconShadowCarrierInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeIconShadowCarrierAdapterObservation.state,
        MTIconShadowCarrierAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTIconShadowCarrierAdapterID,
        MTIconShadowCarrierAdapterStateInstalled, @"Installed");
}

BOOL MTIconShadowCarrierAdapterSchedule(
    MTIconShadowCarrierResolver resolver,
    MTIconShadowCarrierCleaner cleaner,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || cleaner == NULL || preparation == NULL) return NO;
    uint32_t expected = MTIconShadowCarrierAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeIconShadowCarrierAdapterObservation.state,
            &expected, MTIconShadowCarrierAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTIconShadowCarrierAdapterStateScheduled ||
            expected == MTIconShadowCarrierAdapterStateInstalled;
    }
    MTShadowResolver = resolver;
    MTShadowCleaner = cleaner;
    MTShadowPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTIconShadowCarrierAdapterID,
        MTIconShadowCarrierAdapterStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTIconShadowRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptIconShadowCarrierInstallation();
    } else {
        MTScheduleIconShadowCarrierInstallPass();
    }
    return YES;
}
