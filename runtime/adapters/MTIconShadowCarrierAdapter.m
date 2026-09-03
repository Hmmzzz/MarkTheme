#import "MTIconShadowCarrierAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTIconShadowCarrierAdapterID =
    @"springboard-home.icon-shadow-carrier";

static const char *const MTIconImageViewClassName = "SBIconImageView";
static const char *const MTIconViewClassName = "SBIconView";
static const char *const MTFolderIconImageViewClassName =
    "SBFolderIconImageView";
static const char *const MTLayoutSelectorName = "layoutSubviews";
static const char *const MTReuseSelectorName = "prepareForReuse";
static const char *const MTSetIconSelectorName =
    "setIcon:location:animated:";
static const char *const MTIconViewImageSelectorName = "_iconImageView";
static const char *const MTDragPreviewSelectorName =
    "dragPreviewForItem:session:";
static const char *const MTSetDraggingSelectorName =
    "setDragging:updateImmediately:";
static const char *const MTSetDraggingSimpleSelectorName = "setDragging:";
static const char *const MTElementsHiddenSelectorName =
    "setAllIconElementsButLabelToHidden:";
static const char *const MTApplyImageAlphaSelectorName =
    "_applyIconImageAlpha:";
static const char *const MTVoidMethodTypeEncoding = "v16@0:8";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTSetIconMethodTypeEncoding =
    "v36@0:8@16@24B32";
static const char *const MTDragPreviewMethodTypeEncoding =
    "@32@0:8@16@24";
static const char *const MTSetDraggingMethodTypeEncoding =
    "v24@0:8B16B20";
static const char *const MTSetDraggingSimpleMethodTypeEncoding =
    "v20@0:8B16";
static const char *const MTDoubleSetterMethodTypeEncoding =
    "v24@0:8d16";

typedef void (*MTIconShadowCarrierVoidFunction)(id, SEL);
typedef void (*MTIconShadowCarrierSetIconFunction)(
    id, SEL, id, id, BOOL);
typedef id (*MTIconShadowObjectGetterFunction)(id, SEL);
typedef id (*MTIconShadowDragPreviewFunction)(id, SEL, id, id);
typedef void (*MTIconShadowSetDraggingFunction)(id, SEL, BOOL, BOOL);
typedef void (*MTIconShadowSetDraggingSimpleFunction)(id, SEL, BOOL);
typedef void (*MTIconShadowDoubleSetterFunction)(id, SEL, double);

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
static MTIconShadowDragPreviewFunction MTOriginalDragPreview;
static MTIconShadowSetDraggingFunction MTOriginalSetDragging;
static MTIconShadowSetDraggingSimpleFunction MTOriginalSetDraggingSimple;
static MTIconShadowSetDraggingSimpleFunction MTOriginalElementsHidden;
static MTIconShadowDoubleSetterFunction MTOriginalApplyImageAlpha;
static MTIconShadowCarrierResolver MTShadowResolver;
static MTIconShadowCarrierCleaner MTShadowCleaner;
static MTIconShadowCarrierCleaner MTShadowSuspender;
static MTIconShadowCarrierCleaner MTShadowResumer;
static BOOL (*MTShadowPreparation)(void);
static Class MTIconImageViewClass = Nil;
static Class MTFolderIconImageViewClass = Nil;
static Class MTIconViewClass = Nil;
static SEL MTIconViewImageSelector;
static _Atomic(bool) MTInstallPassScheduled = false;
static char MTDraggingCarrierAssociationKey;
static char MTElementsHiddenCarrierAssociationKey;

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

static id MTIconImageViewForIconView(id iconView) {
    if (!MTIconShadowCarrierMatchesClass(iconView, MTIconViewClass) ||
        MTIconViewImageSelector == NULL) {
        return nil;
    }
    id carrier = ((MTIconShadowObjectGetterFunction)objc_msgSend)(
        iconView, MTIconViewImageSelector);
    return MTIconShadowCarrierMatchesClass(carrier, MTIconImageViewClass) &&
        !MTIconShadowCarrierMatchesClass(
            carrier, MTFolderIconImageViewClass) ? carrier : nil;
}

static id MTHookedIconShadowDragPreview(
    id self, SEL selector, id item, id session) {
    id carrier = MTIconImageViewForIconView(self);
    if (carrier != nil && MTShadowSuspender != NULL) {
        MTShadowSuspender(carrier);
    }
    id preview = MTOriginalDragPreview(self, selector, item, session);
    if (carrier != nil && MTShadowResumer != NULL) {
        MTShadowResumer(carrier);
    }
    return preview;
}

static void MTHookedIconShadowSetDragging(
    id self, SEL selector, BOOL dragging, BOOL immediately) {
    id suspendedCarrier = objc_getAssociatedObject(
        self, &MTDraggingCarrierAssociationKey);
    if (dragging && suspendedCarrier == nil) {
        suspendedCarrier = MTIconImageViewForIconView(self);
        if (suspendedCarrier != nil && MTShadowSuspender != NULL) {
            MTShadowSuspender(suspendedCarrier);
            objc_setAssociatedObject(
                self, &MTDraggingCarrierAssociationKey, suspendedCarrier,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    MTOriginalSetDragging(self, selector, dragging, immediately);
    if (!dragging && suspendedCarrier != nil) {
        objc_setAssociatedObject(
            self, &MTDraggingCarrierAssociationKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (MTShadowResumer != NULL) MTShadowResumer(suspendedCarrier);
    }
}

static void MTHookedIconShadowSetDraggingSimple(
    id self, SEL selector, BOOL dragging) {
    id suspendedCarrier = objc_getAssociatedObject(
        self, &MTDraggingCarrierAssociationKey);
    if (dragging && suspendedCarrier == nil) {
        suspendedCarrier = MTIconImageViewForIconView(self);
        if (suspendedCarrier != nil && MTShadowSuspender != NULL) {
            MTShadowSuspender(suspendedCarrier);
            objc_setAssociatedObject(
                self, &MTDraggingCarrierAssociationKey, suspendedCarrier,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    MTOriginalSetDraggingSimple(self, selector, dragging);
    if (!dragging && suspendedCarrier != nil) {
        objc_setAssociatedObject(
            self, &MTDraggingCarrierAssociationKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (MTShadowResumer != NULL) MTShadowResumer(suspendedCarrier);
    }
}

static void MTHookedIconShadowElementsHidden(
    id self, SEL selector, BOOL hidden) {
    id suspendedCarrier = objc_getAssociatedObject(
        self, &MTElementsHiddenCarrierAssociationKey);
    if (hidden && suspendedCarrier == nil) {
        suspendedCarrier = MTIconImageViewForIconView(self);
        if (suspendedCarrier != nil && MTShadowSuspender != NULL) {
            MTShadowSuspender(suspendedCarrier);
            objc_setAssociatedObject(
                self, &MTElementsHiddenCarrierAssociationKey,
                suspendedCarrier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    MTOriginalElementsHidden(self, selector, hidden);
    if (!hidden && suspendedCarrier != nil) {
        objc_setAssociatedObject(
            self, &MTElementsHiddenCarrierAssociationKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (MTShadowResumer != NULL) MTShadowResumer(suspendedCarrier);
    }
}

static void MTHookedIconShadowApplyImageAlpha(
    id self, SEL selector, double alpha) {
    MTOriginalApplyImageAlpha(self, selector, alpha);
    id carrier = MTIconImageViewForIconView(self);
    if (carrier != nil) MTIconShadowResolveCarrier(carrier);
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
    Class iconViewClass = objc_getClass(MTIconViewClassName);
    Class folderClass = objc_getClass(MTFolderIconImageViewClassName);
    if (imageViewClass == Nil || iconViewClass == Nil ||
        folderClass == Nil) return;

    SEL layoutSelector = sel_registerName(MTLayoutSelectorName);
    SEL reuseSelector = sel_registerName(MTReuseSelectorName);
    SEL setIconSelector = sel_registerName(MTSetIconSelectorName);
    SEL iconViewImageSelector = sel_registerName(
        MTIconViewImageSelectorName);
    SEL dragPreviewSelector = sel_registerName(MTDragPreviewSelectorName);
    SEL setDraggingSelector = sel_registerName(MTSetDraggingSelectorName);
    SEL setDraggingSimpleSelector = sel_registerName(
        MTSetDraggingSimpleSelectorName);
    SEL elementsHiddenSelector = sel_registerName(
        MTElementsHiddenSelectorName);
    SEL applyImageAlphaSelector = sel_registerName(
        MTApplyImageAlphaSelectorName);
    Method layoutMethod = class_getInstanceMethod(
        imageViewClass, layoutSelector);
    Method reuseMethod = class_getInstanceMethod(
        imageViewClass, reuseSelector);
    Method setIconMethod = class_getInstanceMethod(
        imageViewClass, setIconSelector);
    Method iconViewImageMethod = class_getInstanceMethod(
        iconViewClass, iconViewImageSelector);
    Method dragPreviewMethod = class_getInstanceMethod(
        iconViewClass, dragPreviewSelector);
    Method setDraggingMethod = class_getInstanceMethod(
        iconViewClass, setDraggingSelector);
    Method setDraggingSimpleMethod = class_getInstanceMethod(
        iconViewClass, setDraggingSimpleSelector);
    Method elementsHiddenMethod = class_getInstanceMethod(
        iconViewClass, elementsHiddenSelector);
    Method applyImageAlphaMethod = class_getInstanceMethod(
        iconViewClass, applyImageAlphaSelector);

    MTRuntimeABIReportProbePresence(
        MTIconShadowCarrierAdapterID,
        @"class:SBIconImageView", imageViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTIconShadowCarrierAdapterID,
        @"class:SBFolderIconImageView", folderClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTIconShadowCarrierAdapterID, @"class:SBIconView",
        iconViewClass != Nil);
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
    MTRuntimeABIReportRecordContract(
        MTIconShadowCarrierAdapterID, @"image:SBIconView",
        MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass),
        @"SpringBoardHome", MTIconShadowImageName(iconViewClass));
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
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView._iconImageView",
        iconViewImageMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView.dragPreviewForItem:session:",
        dragPreviewMethod, MTDragPreviewMethodTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView.setDragging:updateImmediately:",
        setDraggingMethod, MTSetDraggingMethodTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView.setDragging:",
        setDraggingSimpleMethod, MTSetDraggingSimpleMethodTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView.setAllIconElementsButLabelToHidden:",
        elementsHiddenMethod, MTSetDraggingSimpleMethodTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTIconShadowCarrierAdapterID,
        @"encoding:SBIconView._applyIconImageAlpha:",
        applyImageAlphaMethod, MTDoubleSetterMethodTypeEncoding);

    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(imageViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(iconViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(folderClass) &&
        MTRuntimeClassIsSubclassOfClass(folderClass, imageViewClass) &&
        MTIconShadowMethodMatches(layoutMethod) &&
        MTIconShadowMethodMatches(reuseMethod) &&
        setIconMethod != NULL &&
        strcmp(method_getTypeEncoding(setIconMethod),
               MTSetIconMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(setIconMethod)) &&
        iconViewImageMethod != NULL &&
        strcmp(method_getTypeEncoding(iconViewImageMethod),
               MTObjectGetterTypeEncoding) == 0 &&
        dragPreviewMethod != NULL &&
        strcmp(method_getTypeEncoding(dragPreviewMethod),
               MTDragPreviewMethodTypeEncoding) == 0 &&
        setDraggingMethod != NULL &&
        strcmp(method_getTypeEncoding(setDraggingMethod),
               MTSetDraggingMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(iconViewImageMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(dragPreviewMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(setDraggingMethod)) &&
        setDraggingSimpleMethod != NULL &&
        strcmp(method_getTypeEncoding(setDraggingSimpleMethod),
               MTSetDraggingSimpleMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(setDraggingSimpleMethod)) &&
        elementsHiddenMethod != NULL &&
        strcmp(method_getTypeEncoding(elementsHiddenMethod),
               MTSetDraggingSimpleMethodTypeEncoding) == 0 &&
        applyImageAlphaMethod != NULL &&
        strcmp(method_getTypeEncoding(applyImageAlphaMethod),
               MTDoubleSetterMethodTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(elementsHiddenMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(applyImageAlphaMethod)) &&
        MTShadowPreparation != NULL && MTShadowPreparation();
    if (!valid) {
        MTRejectIconShadowCarrierInstallation();
        return;
    }

    MTIconImageViewClass = imageViewClass;
    MTFolderIconImageViewClass = folderClass;
    MTIconViewClass = iconViewClass;
    MTIconViewImageSelector = iconViewImageSelector;
    MTOriginalCarrierLayout = (MTIconShadowCarrierVoidFunction)
        method_getImplementation(layoutMethod);
    MTOriginalCarrierReuse = (MTIconShadowCarrierVoidFunction)
        method_getImplementation(reuseMethod);
    MTOriginalCarrierSetIcon = (MTIconShadowCarrierSetIconFunction)
        method_getImplementation(setIconMethod);
    MTOriginalDragPreview = (MTIconShadowDragPreviewFunction)
        method_getImplementation(dragPreviewMethod);
    MTOriginalSetDragging = (MTIconShadowSetDraggingFunction)
        method_getImplementation(setDraggingMethod);
    MTOriginalSetDraggingSimple = (MTIconShadowSetDraggingSimpleFunction)
        method_getImplementation(setDraggingSimpleMethod);
    MTOriginalElementsHidden = (MTIconShadowSetDraggingSimpleFunction)
        method_getImplementation(elementsHiddenMethod);
    MTOriginalApplyImageAlpha = (MTIconShadowDoubleSetterFunction)
        method_getImplementation(applyImageAlphaMethod);
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
    MSHookMessageEx(
        iconViewClass, dragPreviewSelector,
        (IMP)MTHookedIconShadowDragPreview,
        (IMP *)&MTOriginalDragPreview);
    MSHookMessageEx(
        iconViewClass, setDraggingSelector,
        (IMP)MTHookedIconShadowSetDragging,
        (IMP *)&MTOriginalSetDragging);
    MSHookMessageEx(
        iconViewClass, setDraggingSimpleSelector,
        (IMP)MTHookedIconShadowSetDraggingSimple,
        (IMP *)&MTOriginalSetDraggingSimple);
    MSHookMessageEx(
        iconViewClass, elementsHiddenSelector,
        (IMP)MTHookedIconShadowElementsHidden,
        (IMP *)&MTOriginalElementsHidden);
    MSHookMessageEx(
        iconViewClass, applyImageAlphaSelector,
        (IMP)MTHookedIconShadowApplyImageAlpha,
        (IMP *)&MTOriginalApplyImageAlpha);
    if (MTOriginalCarrierLayout == NULL ||
        MTOriginalCarrierReuse == NULL ||
        MTOriginalCarrierSetIcon == NULL ||
        MTOriginalDragPreview == NULL ||
        MTOriginalSetDragging == NULL ||
        MTOriginalSetDraggingSimple == NULL ||
        MTOriginalElementsHidden == NULL ||
        MTOriginalApplyImageAlpha == NULL) {
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
    MTIconShadowCarrierCleaner suspender,
    MTIconShadowCarrierCleaner resumer,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || cleaner == NULL || suspender == NULL ||
        resumer == NULL || preparation == NULL) return NO;
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
    MTShadowSuspender = suspender;
    MTShadowResumer = resumer;
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
