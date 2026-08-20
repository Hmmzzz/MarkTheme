#import "MTIconShadowViewAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeWeakObjectMapSnapshot.h"
#import "MTSpringBoardHomeABI.h"
#import "MTIconImageCacheAdapter.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.icon-shadow";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTIconViewClassName = "SBIconView";
static const char *const MTIconImageViewClassName = "SBIconImageView";
static const char *const MTConfigureSelectorName =
    "_configureIconImageView:";
static const char *const MTConfigureTypeEncoding = "v24@0:8@16";
static const char *const MTImageInfoSelectorName = "setIconImageInfo:";
static const char *const MTImageInfoTypeEncoding =
    "v48@0:8{SBIconImageInfo={CGSize=dd}dd}16";
static const char *const MTDestroySelectorName = "_destroyIconImageView";
static const char *const MTDestroyTypeEncoding = "v16@0:8";
static const char *const MTIsFolderSelectorName = "isFolderIcon";
static const char *const MTIsFolderTypeEncoding = "B16@0:8";
static const char *const MTIconSelectorName = "icon";
static const char *const MTIconImageCacheSelectorName = "iconImageCache";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";

typedef struct MTShadowIconImageSize {
    double width;
    double height;
} MTShadowIconImageSize;
typedef struct MTShadowIconImageInfo {
    MTShadowIconImageSize size;
    double value1;
    double value2;
} MTShadowIconImageInfo;

typedef void (*MTConfigureFunction)(id, SEL, id);
typedef void (*MTSetIconImageInfoFunction)(id, SEL, MTShadowIconImageInfo);
typedef void (*MTDestroyFunction)(id, SEL);
typedef BOOL (*MTIsFolderFunction)(id, SEL);
typedef id (*MTObjectGetterFunction)(id, SEL);

MTIconShadowViewAdapterObservation
    MTRuntimeIconShadowViewAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTIconShadowViewAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .configureCalls = ATOMIC_VAR_INIT(0),
        .imageInfoCalls = ATOMIC_VAR_INIT(0),
        .destroyCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .appliedResults = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshExecutions = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTIconShadowViewAdapterObservation) == 80,
    "The Icon Shadow ProcessAdapter observation layout must remain fixed.");

static MTConfigureFunction MTOriginalConfigure;
static MTSetIconImageInfoFunction MTOriginalSetIconImageInfo;
static MTDestroyFunction MTOriginalDestroy;
static MTIsFolderFunction MTOriginalIsFolder;
static MTIconShadowViewResolver MTShadowResolver;
static MTIconShadowViewForgetter MTShadowForgetter;
static NSMapTable *MTTrackedImageViews;
static Class MTIconViewClass = Nil;
static Class MTIconImageViewClass = Nil;
static SEL MTIsFolderSelector;
static SEL MTIconSelector;
static SEL MTIconImageCacheSelector;

static BOOL MTIconShadowObjectMatchesClass(id object, Class expectedClass) {
    return object != nil && MTRuntimeClassIsSubclassOfClass(
        object_getClass(object), expectedClass);
}

static void MTIconShadowForget(id iconView, id iconImageView) {
    if (MTShadowForgetter != nil) {
        MTShadowForgetter(iconView, iconImageView);
    }
    [MTTrackedImageViews removeObjectForKey:iconView];
}

static void MTIconShadowTrackCacheRecipient(id iconView) {
    if (MTIconSelector == NULL || MTIconImageCacheSelector == NULL) return;
    id icon = ((MTObjectGetterFunction)objc_msgSend)(
        iconView, MTIconSelector);
    id cache = ((MTObjectGetterFunction)objc_msgSend)(
        iconView, MTIconImageCacheSelector);
    MTIconImageCacheAdapterTrackVisibleIcon(cache, icon);
}

static void MTIconShadowApply(id iconView, id iconImageView) {
    if (MTShadowResolver == nil || MTOriginalIsFolder == NULL ||
        !MTIconShadowObjectMatchesClass(iconView, MTIconViewClass) ||
        !MTIconShadowObjectMatchesClass(iconImageView,
                                        MTIconImageViewClass)) {
        return;
    }
    if (MTOriginalIsFolder(iconView, MTIsFolderSelector)) {
        MTIconShadowForget(iconView, iconImageView);
        return;
    }
    [MTTrackedImageViews setObject:iconImageView forKey:iconView];
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    if (MTShadowResolver(iconView, iconImageView)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.appliedResults,
            1, memory_order_relaxed);
    }
}

static void MTHookedConfigure(id self, SEL selector, id iconImageView) {
    MTOriginalConfigure(self, selector, iconImageView);
    uint64_t call = atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.configureCalls,
        1, memory_order_relaxed) + 1;
    if (call == 1 || call == 16 || call == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-shadow.configure", @{ @"call" : @(call) });
    }
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTIconShadowTrackCacheRecipient(self);
    MTIconShadowApply(self, iconImageView);
}

static void MTHookedSetIconImageInfo(id self,
                                     SEL selector,
                                     MTShadowIconImageInfo info) {
    MTOriginalSetIconImageInfo(self, selector, info);
    uint64_t call = atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.imageInfoCalls,
        1, memory_order_relaxed) + 1;
    if (call == 1 || call == 16 || call == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-shadow.image-info", @{ @"call" : @(call) });
    }
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    id iconImageView = [MTTrackedImageViews objectForKey:self];
    if (iconImageView != nil) MTIconShadowApply(self, iconImageView);
}

static void MTHookedDestroy(id self, SEL selector) {
    id iconImageView = [NSThread isMainThread]
        ? [MTTrackedImageViews objectForKey:self] : nil;
    MTOriginalDestroy(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.destroyCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTIconShadowForget(self, iconImageView);
}

static void MTIconShadowAttemptInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class iconViewClass = objc_getClass(MTIconViewClassName);
    Class iconImageViewClass = objc_getClass(MTIconImageViewClassName);
    SEL configureSelector = sel_registerName(MTConfigureSelectorName);
    SEL imageInfoSelector = sel_registerName(MTImageInfoSelectorName);
    SEL destroySelector = sel_registerName(MTDestroySelectorName);
    SEL isFolderSelector = sel_registerName(MTIsFolderSelectorName);
    SEL iconSelector = sel_registerName(MTIconSelectorName);
    SEL iconImageCacheSelector =
        sel_registerName(MTIconImageCacheSelectorName);
    Method configureMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, configureSelector);
    Method imageInfoMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, imageInfoSelector);
    Method destroyMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, destroySelector);
    Method isFolderMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, isFolderSelector);
    Method iconMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, iconSelector);
    Method iconImageCacheMethod = iconViewClass == Nil ? NULL :
        class_getInstanceMethod(iconViewClass, iconImageCacheSelector);
    if (configureMethod == NULL || imageInfoMethod == NULL ||
        destroyMethod == NULL || isFolderMethod == NULL ||
        iconImageViewClass == Nil) {
        atomic_store_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.state,
            MTIconShadowViewAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTIconShadowViewAdapterStateRejected,
            @"Rejected");
        return;
    }

    const char *configureType = method_getTypeEncoding(configureMethod);
    const char *imageInfoType = method_getTypeEncoding(imageInfoMethod);
    const char *destroyType = method_getTypeEncoding(destroyMethod);
    const char *isFolderType = method_getTypeEncoding(isFolderMethod);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBIconView", iconViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBIconImageView", iconImageViewClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBIconView",
        MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass),
        @"SpringBoardHome", MTReportImageName(iconViewClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(iconImageViewClass),
        @"SpringBoardHome", MTReportImageName(iconImageViewClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView._configureIconImageView:",
        configureMethod, MTConfigureTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView.setIconImageInfo:",
        imageInfoMethod, MTImageInfoTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView._destroyIconImageView",
        destroyMethod, MTDestroyTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView.isFolderIcon",
        isFolderMethod, MTIsFolderTypeEncoding);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"method:SBIconView.icon", iconMethod != NULL);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"method:SBIconView.iconImageCache",
        iconImageCacheMethod != NULL);
    BOOL iconGetterTypeValid = MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView.icon",
        iconMethod, MTObjectGetterTypeEncoding);
    BOOL cacheGetterTypeValid = MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconView.iconImageCache",
        iconImageCacheMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconView._configureIconImageView:",
        method_getImplementation(configureMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconView.setIconImageInfo:",
        method_getImplementation(imageInfoMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconView._destroyIconImageView",
        method_getImplementation(destroyMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBIconView.isFolderIcon",
        method_getImplementation(isFolderMethod));
    BOOL iconGetterImplementationValid =
        MTRuntimeABIReportProbeImplementation(
            MTAdapterID, @"impl:SBIconView.icon",
            iconMethod == NULL ? NULL :
                method_getImplementation(iconMethod));
    BOOL cacheGetterImplementationValid =
        MTRuntimeABIReportProbeImplementation(
            MTAdapterID, @"impl:SBIconView.iconImageCache",
            iconImageCacheMethod == NULL ? NULL :
                method_getImplementation(iconImageCacheMethod));
    BOOL visibleRecipientTrackingValid =
        iconGetterTypeValid && cacheGetterTypeValid &&
        iconGetterImplementationValid && cacheGetterImplementationValid;
    MTRuntimeABIReportProbePresence(
        MTAdapterID,
        @"capability:visible-icon-cache-recipient-tracking",
        visibleRecipientTrackingValid);
    BOOL valid = MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(iconImageViewClass) &&
        configureType != NULL &&
        strcmp(configureType, MTConfigureTypeEncoding) == 0 &&
        imageInfoType != NULL &&
        strcmp(imageInfoType, MTImageInfoTypeEncoding) == 0 &&
        destroyType != NULL &&
        strcmp(destroyType, MTDestroyTypeEncoding) == 0 &&
        isFolderType != NULL &&
        strcmp(isFolderType, MTIsFolderTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(configureMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(imageInfoMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(destroyMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(isFolderMethod));
    if (!valid) {
        atomic_store_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.state,
            MTIconShadowViewAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTIconShadowViewAdapterStateRejected,
            @"Rejected");
        return;
    }

    MTIconViewClass = iconViewClass;
    MTIconImageViewClass = iconImageViewClass;
    MTIsFolderSelector = isFolderSelector;
    MTIconSelector = visibleRecipientTrackingValid ? iconSelector : NULL;
    MTIconImageCacheSelector = visibleRecipientTrackingValid
        ? iconImageCacheSelector : NULL;
    MTTrackedImageViews = [NSMapTable weakToWeakObjectsMapTable];
    MTOriginalConfigure = (MTConfigureFunction)
        method_getImplementation(configureMethod);
    MTOriginalSetIconImageInfo = (MTSetIconImageInfoFunction)
        method_getImplementation(imageInfoMethod);
    MTOriginalDestroy = (MTDestroyFunction)
        method_getImplementation(destroyMethod);
    MTOriginalIsFolder = (MTIsFolderFunction)
        method_getImplementation(isFolderMethod);
    MSHookMessageEx(iconViewClass, configureSelector,
        (IMP)MTHookedConfigure, (IMP *)&MTOriginalConfigure);
    MSHookMessageEx(iconViewClass, imageInfoSelector,
        (IMP)MTHookedSetIconImageInfo,
        (IMP *)&MTOriginalSetIconImageInfo);
    MSHookMessageEx(iconViewClass, destroySelector,
        (IMP)MTHookedDestroy, (IMP *)&MTOriginalDestroy);
    if (MTOriginalConfigure == NULL ||
        MTOriginalSetIconImageInfo == NULL ||
        MTOriginalDestroy == NULL || MTOriginalIsFolder == NULL ||
        MTTrackedImageViews == nil) {
        atomic_store_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.state,
            MTIconShadowViewAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTIconShadowViewAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.state,
        MTIconShadowViewAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTIconShadowViewAdapterStateInstalled,
        @"Installed");
}

BOOL MTIconShadowViewAdapterSchedule(
    MTIconShadowViewResolver resolver,
    MTIconShadowViewForgetter forgetter,
    NSError **error) {
    (void)error;
    if (resolver == nil || forgetter == nil) return NO;
    uint32_t expected = MTIconShadowViewAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.state,
            &expected, MTIconShadowViewAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTIconShadowViewAdapterStateScheduled ||
            expected == MTIconShadowViewAdapterStateInstalled;
    }
    MTShadowResolver = resolver;
    MTShadowForgetter = forgetter;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTIconShadowViewAdapterStateScheduled,
        @"Scheduled");
    // The constructor returns immediately. UIKit-facing metadata and Hook
    // registration begin at one deterministic main-queue boundary, without
    // a delay, timer, retry loop, or synchronous queue hop.
    dispatch_async(dispatch_get_main_queue(), ^{
        MTIconShadowAttemptInstallation();
    });
    return YES;
}

void MTIconShadowViewAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowViewAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.state,
            memory_order_acquire) != MTIconShadowViewAdapterStateInstalled) {
        return;
    }
    // Resolver callbacks update MTTrackedImageViews. Keep those mutations away
    // from the weak table enumerator by retaining one bounded live-pair
    // snapshot before invoking any callback.
    NSArray<NSArray *> *trackedPairs =
        MTRuntimeWeakObjectMapSnapshot(MTTrackedImageViews);
    for (NSArray *pair in trackedPairs) {
        id iconView = pair[0];
        id iconImageView = pair[1];
        if (!MTIconShadowObjectMatchesClass(iconView, MTIconViewClass) ||
            !MTIconShadowObjectMatchesClass(iconImageView,
                                            MTIconImageViewClass)) {
            continue;
        }
        MTIconShadowApply(iconView, iconImageView);
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowViewAdapterObservation.refreshExecutions,
            1, memory_order_relaxed);
    }
}
