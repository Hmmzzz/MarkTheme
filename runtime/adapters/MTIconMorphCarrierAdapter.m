#import "MTIconMorphCarrierAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"
#import "MTStaticIconConfiguration.h"

static NSString *const MTAdapterID = @"springboard.icon-morph-carrier";
static const char *const MTIconClassName = "SBIcon";
static const char *const MTIconImageViewClassName = "SBIconImageView";
static const char *const MTCrossfadeViewClassName =
    "SBIconImageCrossfadeView";
static const char *const MTApplicationBundleSelectorName =
    "applicationBundleID";
static const char *const MTIconSelectorName = "icon";
static const char *const MTSquareContentsSelectorName =
    "squareContentsImage";
static const char *const MTPrepareSelectorName = "prepareGeometry";
static const char *const MTFadeSelectorName = "setSourceFadeFraction:";
static const char *const MTCleanupSelectorName = "cleanup";
static const char *const MTCrossfadeIconViewSelectorName = "iconImageView";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTVoidTypeEncoding = "v16@0:8";
static const char *const MTDoubleSetterTypeEncoding = "v24@0:8d16";

typedef id (*MTObjectGetterFunction)(id, SEL);
typedef void (*MTVoidFunction)(id, SEL);
typedef void (*MTDoubleSetterFunction)(id, SEL, CGFloat);
typedef CGImageRef _Nullable (*MTCGImageGetterFunction)(id, SEL);

MTIconMorphCarrierAdapterObservation
    MTRuntimeIconMorphCarrierAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTIconMorphCarrierAdapterStateDormant),
        .squareContentsCalls = ATOMIC_VAR_INIT(0),
        .eligibleCarriers = ATOMIC_VAR_INIT(0),
        .prepareCalls = ATOMIC_VAR_INIT(0),
        .proxyActivations = ATOMIC_VAR_INIT(0),
        .fadeSynchronizations = ATOMIC_VAR_INIT(0),
        .cleanups = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTIconMorphCarrierAdapterObservation) == 56,
    "Icon morph-carrier observation ABI changed");

static MTObjectGetterFunction MTOriginalSquareContents;
static MTVoidFunction MTOriginalPrepare;
static MTDoubleSetterFunction MTOriginalFade;
static MTVoidFunction MTOriginalCleanup;
static Class MTIconClass = Nil;
static SEL MTApplicationBundleSelector;
static SEL MTIconSelector;
static SEL MTCrossfadeIconViewSelector;
static MTIconMorphCarrierScopeResolver MTScopeResolver;
static char MTSquareCarrierAssociationKey;
static char MTProxyLayerAssociationKey;
static char MTProxySourceLayerAssociationKey;
static char MTProxyOriginalOpacityAssociationKey;

static BOOL MTMethodIsValid(Class runtimeClass,
                            SEL selector,
                            const char *typeEncoding) {
    Method method = class_getInstanceMethod(runtimeClass, selector);
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static BOOL MTBundleIdentifierIsAffected(NSString *bundleIdentifier) {
    if (!MTStaticIconBundleIdentifierIsValid(bundleIdentifier)) return NO;
    MTIconMorphCarrierScopeResolver resolver = MTScopeResolver;
    return resolver != nil && resolver(bundleIdentifier);
}

static id MTRasterContentsForImage(id image) {
    if (image == nil || ![image respondsToSelector:@selector(CGImage)]) {
        return nil;
    }
    CGImageRef raster = ((MTCGImageGetterFunction)objc_msgSend)(
        image, @selector(CGImage));
    return raster == NULL ? nil : (__bridge id)raster;
}

static id MTHookedSquareContents(id self, SEL selector) {
    id originalResult = MTOriginalSquareContents(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeIconMorphCarrierAdapterObservation.squareContentsCalls,
        1, memory_order_relaxed);
    objc_setAssociatedObject(
        self, &MTSquareCarrierAssociationKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id icon = ((MTObjectGetterFunction)objc_msgSend)(self, MTIconSelector);
    if (!MTRuntimeClassIsSubclassOfClass(
            object_getClass(icon), MTIconClass)) {
        return originalResult;
    }
    id identifier = ((MTObjectGetterFunction)objc_msgSend)(
        icon, MTApplicationBundleSelector);
    if (!MTBundleIdentifierIsAffected(identifier) ||
        MTRasterContentsForImage(originalResult) == nil) {
        return originalResult;
    }
    // Retain exactly the object Apple returned. The IconServices service owns
    // its pixels and masking; this association proves only which square carrier
    // belongs to the upcoming crossfade.
    objc_setAssociatedObject(
        self, &MTSquareCarrierAssociationKey,
        originalResult, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_fetch_add_explicit(
        &MTRuntimeIconMorphCarrierAdapterObservation.eligibleCarriers,
        1, memory_order_relaxed);
    return originalResult;
}

static BOOL MTPrepareProxy(id crossfadeView) {
    id iconImageView = ((MTObjectGetterFunction)objc_msgSend)(
        crossfadeView, MTCrossfadeIconViewSelector);
    id squareCarrier = iconImageView == nil ? nil :
        objc_getAssociatedObject(
            iconImageView, &MTSquareCarrierAssociationKey);
    id squareContents = MTRasterContentsForImage(squareCarrier);
    if (squareContents == nil) return NO;

    CALayer *crossfadeLayer = ((MTObjectGetterFunction)objc_msgSend)(
        crossfadeView, @selector(layer));
    CALayer *sourceLayer = ((MTObjectGetterFunction)objc_msgSend)(
        iconImageView, @selector(layer));
    if (![crossfadeLayer isKindOfClass:CALayer.class] ||
        ![sourceLayer isKindOfClass:CALayer.class] ||
        sourceLayer.contents == nil) {
        return NO;
    }

    CALayer *storedSource = objc_getAssociatedObject(
        crossfadeView, &MTProxySourceLayerAssociationKey);
    CALayer *proxy = objc_getAssociatedObject(
        crossfadeView, &MTProxyLayerAssociationKey);
    if (storedSource != nil && storedSource != sourceLayer) {
        NSNumber *originalOpacity = objc_getAssociatedObject(
            crossfadeView, &MTProxyOriginalOpacityAssociationKey);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (originalOpacity != nil) {
            storedSource.opacity = originalOpacity.floatValue;
        }
        [proxy removeFromSuperlayer];
        [CATransaction commit];
        proxy = nil;
    }

    BOOL created = proxy == nil;
    if (created) {
        proxy = [CALayer layer];
        proxy.name = @"com.hmmzzz.marktheme.morph-square-proxy";
        objc_setAssociatedObject(
            crossfadeView, &MTProxyLayerAssociationKey,
            proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(
            crossfadeView, &MTProxySourceLayerAssociationKey,
            sourceLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(
            crossfadeView, &MTProxyOriginalOpacityAssociationKey,
            @(sourceLayer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    proxy.frame = crossfadeLayer.bounds;
    proxy.contents = squareContents;
    proxy.contentsScale = sourceLayer.contentsScale;
    proxy.contentsGravity = sourceLayer.contentsGravity;
    proxy.contentsRect = sourceLayer.contentsRect;
    proxy.contentsCenter = sourceLayer.contentsCenter;
    proxy.minificationFilter = sourceLayer.minificationFilter;
    proxy.magnificationFilter = sourceLayer.magnificationFilter;
    if (created) {
        proxy.opacity = sourceLayer.opacity;
        proxy.hidden = sourceLayer.hidden;
    }
    proxy.cornerRadius = sourceLayer.cornerRadius;
    proxy.masksToBounds = sourceLayer.masksToBounds;
    if (proxy.superlayer != crossfadeLayer) {
        [crossfadeLayer addSublayer:proxy];
    }
    sourceLayer.opacity = 0.0f;
    [CATransaction commit];
    return created;
}

static BOOL MTSynchronizeProxy(id crossfadeView) {
    CALayer *proxy = objc_getAssociatedObject(
        crossfadeView, &MTProxyLayerAssociationKey);
    CALayer *sourceLayer = objc_getAssociatedObject(
        crossfadeView, &MTProxySourceLayerAssociationKey);
    if (proxy == nil || sourceLayer == nil) return NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    proxy.opacity = sourceLayer.opacity;
    proxy.hidden = sourceLayer.hidden;
    sourceLayer.opacity = 0.0f;
    [CATransaction commit];
    return YES;
}

static BOOL MTRestoreProxy(id crossfadeView) {
    CALayer *proxy = objc_getAssociatedObject(
        crossfadeView, &MTProxyLayerAssociationKey);
    CALayer *sourceLayer = objc_getAssociatedObject(
        crossfadeView, &MTProxySourceLayerAssociationKey);
    NSNumber *originalOpacity = objc_getAssociatedObject(
        crossfadeView, &MTProxyOriginalOpacityAssociationKey);
    if (proxy == nil && sourceLayer == nil) return NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (sourceLayer != nil && originalOpacity != nil) {
        sourceLayer.opacity = originalOpacity.floatValue;
    }
    [proxy removeFromSuperlayer];
    [CATransaction commit];
    objc_setAssociatedObject(
        crossfadeView, &MTProxyLayerAssociationKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(
        crossfadeView, &MTProxySourceLayerAssociationKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(
        crossfadeView, &MTProxyOriginalOpacityAssociationKey,
        nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static void MTHookedPrepare(id self, SEL selector) {
    MTOriginalPrepare(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeIconMorphCarrierAdapterObservation.prepareCalls,
        1, memory_order_relaxed);
    if (MTPrepareProxy(self)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation.proxyActivations,
            1, memory_order_relaxed);
    }
}

static void MTHookedFade(id self, SEL selector, CGFloat fraction) {
    MTOriginalFade(self, selector, fraction);
    if (MTSynchronizeProxy(self)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation
                 .fadeSynchronizations,
            1, memory_order_relaxed);
    }
}

static void MTHookedCleanup(id self, SEL selector) {
    if (MTRestoreProxy(self)) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation.cleanups,
            1, memory_order_relaxed);
    }
    id iconImageView = ((MTObjectGetterFunction)objc_msgSend)(
        self, MTCrossfadeIconViewSelector);
    if (iconImageView != nil) {
        objc_setAssociatedObject(
            iconImageView, &MTSquareCarrierAssociationKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    MTOriginalCleanup(self, selector);
}

static void MTAttemptInstallation(void) {
    Class iconClass = objc_getClass(MTIconClassName);
    Class imageViewClass = objc_getClass(MTIconImageViewClassName);
    Class crossfadeClass = objc_getClass(MTCrossfadeViewClassName);
    SEL applicationBundleSelector =
        sel_registerName(MTApplicationBundleSelectorName);
    SEL iconSelector = sel_registerName(MTIconSelectorName);
    SEL squareSelector = sel_registerName(MTSquareContentsSelectorName);
    SEL prepareSelector = sel_registerName(MTPrepareSelectorName);
    SEL fadeSelector = sel_registerName(MTFadeSelectorName);
    SEL cleanupSelector = sel_registerName(MTCleanupSelectorName);
    SEL crossfadeIconViewSelector =
        sel_registerName(MTCrossfadeIconViewSelectorName);

    Method applicationBundleMethod = class_getInstanceMethod(
        iconClass, applicationBundleSelector);
    Method iconMethod = class_getInstanceMethod(imageViewClass, iconSelector);
    Method squareMethod = class_getInstanceMethod(
        imageViewClass, squareSelector);
    Method prepareMethod = class_getInstanceMethod(
        crossfadeClass, prepareSelector);
    Method fadeMethod = class_getInstanceMethod(crossfadeClass, fadeSelector);
    Method cleanupMethod = class_getInstanceMethod(
        crossfadeClass, cleanupSelector);
    Method crossfadeIconViewMethod = class_getInstanceMethod(
        crossfadeClass, crossfadeIconViewSelector);

    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(iconClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(imageViewClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(crossfadeClass) &&
        MTMethodIsValid(iconClass, applicationBundleSelector,
                        MTObjectGetterTypeEncoding) &&
        MTMethodIsValid(imageViewClass, iconSelector,
                        MTObjectGetterTypeEncoding) &&
        MTMethodIsValid(imageViewClass, squareSelector,
                        MTObjectGetterTypeEncoding) &&
        MTMethodIsValid(crossfadeClass, prepareSelector,
                        MTVoidTypeEncoding) &&
        MTMethodIsValid(crossfadeClass, fadeSelector,
                        MTDoubleSetterTypeEncoding) &&
        MTMethodIsValid(crossfadeClass, cleanupSelector,
                        MTVoidTypeEncoding) &&
        MTMethodIsValid(crossfadeClass, crossfadeIconViewSelector,
                        MTObjectGetterTypeEncoding);

    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBIconImageView", imageViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBIconImageCrossfadeView",
        crossfadeClass != Nil);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIcon.applicationBundleID",
        applicationBundleMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconImageView.icon",
        iconMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconImageView.squareContentsImage",
        squareMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBIconImageCrossfadeView.prepareGeometry",
        prepareMethod, MTVoidTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBIconImageCrossfadeView.setSourceFadeFraction:",
        fadeMethod, MTDoubleSetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconImageCrossfadeView.cleanup",
        cleanupMethod, MTVoidTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBIconImageCrossfadeView.iconImageView",
        crossfadeIconViewMethod, MTObjectGetterTypeEncoding);

    if (!valid) {
        atomic_store_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation.state,
            MTIconMorphCarrierAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTIconMorphCarrierAdapterStateRejected,
            @"Rejected");
        return;
    }

    MTIconClass = iconClass;
    MTApplicationBundleSelector = applicationBundleSelector;
    MTIconSelector = iconSelector;
    MTCrossfadeIconViewSelector = crossfadeIconViewSelector;
    MTOriginalSquareContents = (MTObjectGetterFunction)
        method_getImplementation(squareMethod);
    MTOriginalPrepare = (MTVoidFunction)
        method_getImplementation(prepareMethod);
    MTOriginalFade = (MTDoubleSetterFunction)
        method_getImplementation(fadeMethod);
    MTOriginalCleanup = (MTVoidFunction)
        method_getImplementation(cleanupMethod);
    MSHookMessageEx(imageViewClass, squareSelector,
        (IMP)MTHookedSquareContents, (IMP *)&MTOriginalSquareContents);
    MSHookMessageEx(crossfadeClass, prepareSelector,
        (IMP)MTHookedPrepare, (IMP *)&MTOriginalPrepare);
    MSHookMessageEx(crossfadeClass, fadeSelector,
        (IMP)MTHookedFade, (IMP *)&MTOriginalFade);
    MSHookMessageEx(crossfadeClass, cleanupSelector,
        (IMP)MTHookedCleanup, (IMP *)&MTOriginalCleanup);
    if (MTOriginalSquareContents == NULL || MTOriginalPrepare == NULL ||
        MTOriginalFade == NULL || MTOriginalCleanup == NULL) {
        atomic_store_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation.state,
            MTIconMorphCarrierAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTIconMorphCarrierAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(
        &MTRuntimeIconMorphCarrierAdapterObservation.state,
        MTIconMorphCarrierAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTIconMorphCarrierAdapterStateInstalled,
        @"Installed");
}

BOOL MTIconMorphCarrierAdapterSchedule(
    MTIconMorphCarrierScopeResolver scopeResolver,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (scopeResolver == nil) return NO;
    MTScopeResolver = [scopeResolver copy];
    uint32_t expected = MTIconMorphCarrierAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeIconMorphCarrierAdapterObservation.state,
            &expected, MTIconMorphCarrierAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTIconMorphCarrierAdapterStateScheduled ||
            expected == MTIconMorphCarrierAdapterStateInstalled;
    }
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTIconMorphCarrierAdapterStateScheduled,
        @"Scheduled");
    dispatch_async(dispatch_get_main_queue(), ^{
        MTAttemptInstallation();
    });
    return YES;
}
