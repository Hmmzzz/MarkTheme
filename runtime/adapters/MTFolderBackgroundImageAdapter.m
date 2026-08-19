#import "MTFolderBackgroundImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.folder-image";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTFolderClassName = "SBFolderIconImageView";
static const char *const MTFolderUpdateSelectorName = "updateImageAnimated:";
static const char *const MTFolderUpdateTypeEncoding = "v20@0:8B16";
static const char *const MTFolderBackgroundGetterName = "backgroundView";
static const char *const MTFolderBackgroundGetterTypeEncoding = "@16@0:8";
static const char *const MTFolderBackgroundSetterName = "setBackgroundView:";
static const char *const MTFolderBackgroundSetterTypeEncoding = "v24@0:8@16";
static const uint32_t MTMaximumInstallAttempts = 80;
static const int64_t MTInstallRetryNanoseconds = 250 * NSEC_PER_MSEC;

typedef void (*MTFolderUpdateFunction)(id, SEL, BOOL);
typedef id (*MTFolderBackgroundGetterFunction)(id, SEL);
typedef void (*MTFolderBackgroundSetterFunction)(id, SEL, id);

MTFolderBackgroundImageAdapterObservation
    MTRuntimeFolderBackgroundImageAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(
            MTFolderBackgroundImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .updateCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshExecutions = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTFolderBackgroundImageAdapterObservation) == 64,
    "The Folder ProcessAdapter observation layout must remain fixed.");

static MTFolderUpdateFunction MTOriginalFolderUpdate;
static MTFolderBackgroundGetterFunction MTOriginalBackgroundGetter;
static MTFolderBackgroundSetterFunction MTOriginalBackgroundSetter;
static MTFolderBackgroundViewResolver MTBackgroundResolver;
static NSHashTable *MTFolderViews;
static Class MTFolderClass = Nil;
static SEL MTFolderUpdateSelector;
static SEL MTFolderBackgroundGetter;
static SEL MTFolderBackgroundSetter;

static void MTFolderApplyBackground(id folderView) {
    if (MTBackgroundResolver == nil || MTOriginalBackgroundGetter == NULL ||
        MTOriginalBackgroundSetter == NULL) {
        return;
    }
    id originalBackground = MTOriginalBackgroundGetter(
        folderView, MTFolderBackgroundGetter);
    atomic_fetch_add_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id replacement = MTBackgroundResolver(
        folderView, originalBackground, &didReplace);
    if (!didReplace || replacement == originalBackground) return;
    MTOriginalBackgroundSetter(
        folderView, MTFolderBackgroundSetter, replacement);
    atomic_fetch_add_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.replacementResults,
        1, memory_order_relaxed);
}

static void MTHookedFolderUpdate(id self, SEL selector, BOOL animated) {
    MTOriginalFolderUpdate(self, selector, animated);
    atomic_fetch_add_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.updateCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    [MTFolderViews addObject:self];
    MTFolderApplyBackground(self);
}

static void MTFolderBackgroundAttemptInstallation(uint32_t attempt) {
    atomic_store_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.installAttempts,
        attempt, memory_order_relaxed);
    Class folderClass = objc_getClass(MTFolderClassName);
    SEL updateSelector = sel_registerName(MTFolderUpdateSelectorName);
    SEL getterSelector = sel_registerName(MTFolderBackgroundGetterName);
    SEL setterSelector = sel_registerName(MTFolderBackgroundSetterName);
    Method updateMethod = folderClass == Nil ? NULL :
        class_getInstanceMethod(folderClass, updateSelector);
    Method getterMethod = folderClass == Nil ? NULL :
        class_getInstanceMethod(folderClass, getterSelector);
    Method setterMethod = folderClass == Nil ? NULL :
        class_getInstanceMethod(folderClass, setterSelector);
    if (updateMethod == NULL || getterMethod == NULL || setterMethod == NULL) {
        if (attempt < MTMaximumInstallAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                MTInstallRetryNanoseconds), dispatch_get_main_queue(), ^{
                MTFolderBackgroundAttemptInstallation(attempt + 1);
            });
            return;
        }
        atomic_store_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation.state,
            MTFolderBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTFolderBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }

    const char *updateType = method_getTypeEncoding(updateMethod);
    const char *getterType = method_getTypeEncoding(getterMethod);
    const char *setterType = method_getTypeEncoding(setterMethod);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBFolderIconImageView", folderClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBFolderIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(folderClass),
        @"SpringBoardHome", MTReportImageName(folderClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBFolderIconImageView.updateImageAnimated:",
        updateMethod, MTFolderUpdateTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBFolderIconImageView.backgroundView",
        getterMethod, MTFolderBackgroundGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBFolderIconImageView.setBackgroundView:",
        setterMethod, MTFolderBackgroundSetterTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBFolderIconImageView.updateImageAnimated:",
        method_getImplementation(updateMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBFolderIconImageView.backgroundView",
        method_getImplementation(getterMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBFolderIconImageView.setBackgroundView:",
        method_getImplementation(setterMethod));
    BOOL valid = MTSpringBoardHomeClassMatchesExpectedImage(folderClass) &&
        updateType != NULL &&
        strcmp(updateType, MTFolderUpdateTypeEncoding) == 0 &&
        getterType != NULL &&
        strcmp(getterType, MTFolderBackgroundGetterTypeEncoding) == 0 &&
        setterType != NULL &&
        strcmp(setterType, MTFolderBackgroundSetterTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(updateMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(getterMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(setterMethod));
    if (!valid) {
        atomic_store_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation.state,
            MTFolderBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTFolderBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }

    MTFolderClass = folderClass;
    MTFolderUpdateSelector = updateSelector;
    MTFolderBackgroundGetter = getterSelector;
    MTFolderBackgroundSetter = setterSelector;
    MTFolderViews = [NSHashTable weakObjectsHashTable];
    MTOriginalFolderUpdate = (MTFolderUpdateFunction)
        method_getImplementation(updateMethod);
    MTOriginalBackgroundGetter = (MTFolderBackgroundGetterFunction)
        method_getImplementation(getterMethod);
    MTOriginalBackgroundSetter = (MTFolderBackgroundSetterFunction)
        method_getImplementation(setterMethod);
    MSHookMessageEx(folderClass, updateSelector,
        (IMP)MTHookedFolderUpdate, (IMP *)&MTOriginalFolderUpdate);
    if (MTOriginalFolderUpdate == NULL ||
        MTOriginalBackgroundGetter == NULL ||
        MTOriginalBackgroundSetter == NULL) {
        atomic_store_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation.state,
            MTFolderBackgroundImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTFolderBackgroundImageAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.state,
        MTFolderBackgroundImageAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTFolderBackgroundImageAdapterStateInstalled,
        @"Installed");
}

BOOL MTFolderBackgroundImageAdapterSchedule(
    MTFolderBackgroundViewResolver resolver,
    NSError **error) {
    (void)error;
    if (resolver == nil) return NO;
    uint32_t expected = MTFolderBackgroundImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation.state,
            &expected, MTFolderBackgroundImageAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTFolderBackgroundImageAdapterStateScheduled ||
            expected == MTFolderBackgroundImageAdapterStateInstalled;
    }
    MTBackgroundResolver = resolver;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTFolderBackgroundImageAdapterStateScheduled,
        @"Scheduled");
    if ([NSThread isMainThread]) {
        MTFolderBackgroundAttemptInstallation(1);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            MTFolderBackgroundAttemptInstallation(1);
        });
    }
    return YES;
}

void MTFolderBackgroundImageAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeFolderBackgroundImageAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation.state,
            memory_order_acquire) !=
            MTFolderBackgroundImageAdapterStateInstalled) {
        return;
    }
    for (id view in MTFolderViews.allObjects) {
        if (!MTRuntimeClassIsSubclassOfClass(
                object_getClass(view), MTFolderClass)) continue;
        MTOriginalFolderUpdate(view, MTFolderUpdateSelector, NO);
        MTFolderApplyBackground(view);
        atomic_fetch_add_explicit(
            &MTRuntimeFolderBackgroundImageAdapterObservation
                 .refreshExecutions,
            1, memory_order_relaxed);
    }
}
