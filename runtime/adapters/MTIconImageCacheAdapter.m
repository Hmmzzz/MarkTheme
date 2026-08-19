#import "MTIconImageCacheAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

#import "MTRuntimeTargetedRefresh.h"
#import "MTSpringBoardHomeABI.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

NSString *const MTIconImageCacheAdapterExpectedImageUUID =
    @"AB2D43B6-42D4-3D34-B98A-83C6D3FA06A3";
static const char *const MTTargetClassName = "SBHIconImageCache";
// Keep the outer lookup for weak refresh tracking and an immediate fallback.
static const char *const MTTargetSelectorName = "realImageForIcon:options:";
static const char *const MTTargetTypeEncoding = "@32@0:8@16Q24";
static const char *const MTCacheRequestSelectorName =
    "cacheImageForIcon:options:completionHandler:";
static const char *const MTCacheRequestTypeEncoding = "v40@0:8@16Q24@?32";
// The variant cache stores producer results. Ordinary app icons now stay on
// its complete native path; this final boundary remains only for specialized
// icons whose own producer overrides bypass SBApplicationIcon.
static const char *const MTCacheFillClassName = "SBHIconImageVariantCache";
static const char *const MTCacheFillSelectorName = "_variantImageForIcon:";
static const char *const MTCacheFillTypeEncoding = "@24@0:8@16";
static const char *const MTRefreshSelectorName =
    "purgeCachedImagesForIcons:";
static const char *const MTRefreshTypeEncoding = "v24@0:8@16";
static const char *const MTRefreshNotificationSelectorName =
    "notifyObserversOfUpdateForIcon:";
static const char *const MTRefreshNotificationTypeEncoding = "v24@0:8@16";
static const char *const MTIdentityClassName = "SBIcon";
static const char *const MTIdentitySelectorName = "applicationBundleID";
static const char *const MTIdentityTypeEncoding = "@16@0:8";
// Ordinary app icons get their own producer override so SpringBoard's native
// variant cache can still pool, map, and retain the themed result. Calendar,
// Clock, and other specialized SBIcon subclasses keep the shared fallback.
static const char *const MTApplicationIconClassName = "SBApplicationIcon";
static const char *const MTTransitionSelectorName = "iconImageWithInfo:";
static const char *const MTUnmaskedTransitionSelectorName =
    "unmaskedIconImageWithInfo:";
static const char *const MTTransitionTypeEncoding =
    "@48@0:8{SBIconImageInfo={CGSize=dd}dd}16";
// 21D61 SBIcon's class renderer is the same boundary used by
// -generateIconImageWithInfo: after it obtains unmasked pixels. Calling its
// verified IMP from an actual icon producer preserves IconServices shape=1;
// method discovery below is metadata-only and never asks UIKit for a screen.
static const char *const MTSystemMaskSelectorName =
    "iconImageFromUnmaskedImage:info:";
static const char *const MTSystemMaskTypeEncoding =
    "@56@0:8@16{SBIconImageInfo={CGSize=dd}dd}24";
typedef id (*MTRealImageForIconOptionsFunction)(id, SEL, id, NSUInteger);
typedef void (*MTCacheImageForIconFunction)(id, SEL, id, NSUInteger, id);
typedef id (*MTVariantImageForIconFunction)(id, SEL, id);
typedef id (*MTApplicationBundleIdentifierFunction)(id, SEL);
typedef struct MTIconImageSize {
    double width;
    double height;
} MTIconImageSize;
typedef struct MTIconImageInfo {
    MTIconImageSize size;
    double scale;
    double continuousCornerRadius;
} MTIconImageInfo;
typedef id (*MTIconImageWithInfoFunction)(id, SEL, MTIconImageInfo);
typedef id (*MTSystemMaskImageFunction)(id, SEL, id, MTIconImageInfo);

MTIconImageCacheAdapterObservation MTRuntimeIconImageCacheAdapterObservation = {
    .schemaVersion = 7,
    .state = ATOMIC_VAR_INIT(MTIconImageCacheAdapterStateDormant),
    .installAttempts = ATOMIC_VAR_INIT(0),
    .reserved = 0,
    .totalCalls = ATOMIC_VAR_INIT(0),
    .mainThreadCalls = ATOMIC_VAR_INIT(0),
    .nilOriginalResults = ATOMIC_VAR_INIT(0),
    .identityClassMatches = ATOMIC_VAR_INIT(0),
    .identityStringResults = ATOMIC_VAR_INIT(0),
    .resolverCalls = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
    .transitionCalls = ATOMIC_VAR_INIT(0),
    .transitionReplacements = ATOMIC_VAR_INIT(0),
    .refreshRequests = ATOMIC_VAR_INIT(0),
    .refreshExecutions = ATOMIC_VAR_INIT(0),
    .refreshCachePurges = ATOMIC_VAR_INIT(0),
    .refreshIconPurges = ATOMIC_VAR_INIT(0),
    .refreshObserverNotifications = ATOMIC_VAR_INIT(0),
    .cacheRequestCalls = ATOMIC_VAR_INIT(0),
    .cacheRequestRecipients = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconImageCacheAdapterObservation) == 144,
    "The M3-E ProcessAdapter observation layout must remain fixed.");

static MTRealImageForIconOptionsFunction MTOriginalRealImageForIconOptions;
static MTCacheImageForIconFunction MTOriginalCacheImageForIcon;
static MTVariantImageForIconFunction MTOriginalVariantImageForIcon;
static MTIconImageWithInfoFunction MTOriginalIconImageWithInfo;
static MTIconImageWithInfoFunction MTOriginalApplicationIconImageWithInfo;
static MTIconImageWithInfoFunction
    MTOriginalApplicationUnmaskedIconImageWithInfo;
static MTSystemMaskImageFunction MTSystemMaskImage;
static MTRuntimeReplacementResolver MTAppearanceReplacementResolver;
static MTRuntimeReplacementResolver MTSourceReplacementResolver;
static MTIconReadyReplacementResolver MTReadyReplacementResolver;
static MTIconNativeSystemMaskRequirement MTNativeSystemMaskRequirement;
static MTRuntimeReplacementPreparation MTReplacementPreparation;
static MTIconImageCacheAdapterMode MTInstallationMode;
static MTRuntimeTargetedRefreshTracker *MTRefreshTracker;
static Class MTTargetClass = Nil;
static SEL MTRefreshSelector;
static SEL MTRefreshNotificationSelector;
static Class MTIdentityClass = Nil;
static Class MTApplicationIconClass = Nil;
static SEL MTIdentitySelector;
static SEL MTSystemMaskSelector;
static _Atomic(bool) MTInstallPassScheduled = false;

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            memory_order_acquire) != MTIconImageCacheAdapterStateScheduled) {
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
        if (atomic_load_explicit(
                &MTRuntimeIconImageCacheAdapterObservation.state,
                memory_order_acquire) ==
                MTIconImageCacheAdapterStateScheduled) {
            MTAttemptInstallation();
        }
    });
}

static void MTRuntimeImageAdded(const struct mach_header *header,
                                intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleInstallPass();
}

static void MTSetState(MTIconImageCacheAdapterState state) {
    atomic_store_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.state,
        (uint32_t)state, memory_order_release);
}

static id MTIdentityValueForIcon(id icon) {
    // Installation already validates SBIcon's exact ABI. Normal Objective-C
    // dispatch preserves a compatible subclass override without repeating
    // Method/type-encoding reflection on every animation frame.
    return ((MTApplicationBundleIdentifierFunction)objc_msgSend)(
        icon, MTIdentitySelector);
}

static NSString *MTBundleIdentifierForTrackedIcon(id icon) {
    Class iconClass = icon == nil ? Nil : object_getClass(icon);
    if (!MTRuntimeClassIsSubclassOfClass(iconClass, MTIdentityClass)) {
        return nil;
    }
    id identifier = MTIdentityValueForIcon(icon);
    return [identifier isKindOfClass:NSString.class]
        ? (NSString *)identifier : nil;
}

static BOOL MTUsesNativeSystemMask(void) {
    return MTNativeSystemMaskRequirement != NULL &&
        MTNativeSystemMaskRequirement();
}

static id MTImageByApplyingResolver(
    NSString *bundleIdentifier,
    id originalResult,
    MTRuntimeReplacementResolver resolver,
    BOOL *didReplace) {
    return MTRuntimeResultByApplyingReplacementResolver(
        bundleIdentifier, originalResult, resolver, didReplace);
}

static id MTNativeSystemMaskedImage(id sourceImage,
                                    MTIconImageInfo info) {
    if (sourceImage == nil || MTSystemMaskImage == NULL ||
        MTIdentityClass == Nil || MTSystemMaskSelector == NULL) {
        return nil;
    }
    // This runs only inside a proven SBIcon image producer call. UIKit and
    // IconServices have therefore crossed their own startup boundary; no
    // constructor/bootstrap path can reach this invocation.
    return MTSystemMaskImage(
        MTIdentityClass, MTSystemMaskSelector, sourceImage, info);
}

static void MTRecordTransitionReplacement(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionReplacements,
        1, memory_order_relaxed);
}

static id MTHookedRealImageForIconOptions(id self,
                                          SEL selector,
                                          id icon,
                                          NSUInteger options) {
    id originalResult =
        MTOriginalRealImageForIconOptions(self, selector, icon, options);

    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.totalCalls,
        1, memory_order_relaxed);
    if (pthread_main_np() != 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.mainThreadCalls,
            1, memory_order_relaxed);
    }
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.nilOriginalResults,
            1, memory_order_relaxed);
    }

    Class iconClass = icon == nil ? Nil : object_getClass(icon);
    if (!MTRuntimeClassIsSubclassOfClass(iconClass, MTIdentityClass)) {
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.identityClassMatches,
        1, memory_order_relaxed);
    id bundleIdentifier = MTIdentityValueForIcon(icon);
    if (![bundleIdentifier isKindOfClass:NSString.class]) {
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.identityStringResults,
        1, memory_order_relaxed);
    [MTRefreshTracker recordRecipient:self
                              subject:icon
                           identifier:(NSString *)bundleIdentifier];
    // SBApplicationIcon producer Hooks already supplied the themed image
    // before this native cache lookup. Preserve the pooled/memory-mapped
    // object returned by SpringBoard instead of replacing it with our source
    // UIImage again at the outer boundary.
    if (MTRuntimeClassIsSubclassOfClass(
            iconClass, MTApplicationIconClass)) {
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        (NSString *)bundleIdentifier, originalResult,
        MTAppearanceReplacementResolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.replacementResults,
            1, memory_order_relaxed);
    }
    return result;
}

static void MTHookedCacheImageForIcon(id self,
                                      SEL selector,
                                      id icon,
                                      NSUInteger options,
                                      id completionHandler) {
    MTOriginalCacheImageForIcon(
        self, selector, icon, options, completionHandler);
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.cacheRequestCalls,
        1, memory_order_relaxed);
    NSString *bundleIdentifier = MTBundleIdentifierForTrackedIcon(icon);
    if (bundleIdentifier.length == 0) return;
    [MTRefreshTracker recordRecipient:self
                              subject:icon
                           identifier:bundleIdentifier];
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.cacheRequestRecipients,
        1, memory_order_relaxed);
}

static id MTThemedIconImageWithInfo(
    id self,
    SEL selector,
    MTIconImageInfo info,
    MTIconImageWithInfoFunction originalFunction,
    BOOL maskedProducer) {
    id bundleIdentifier = MTIdentityValueForIcon(self);
    if (![bundleIdentifier isKindOfClass:NSString.class]) {
        return originalFunction(self, selector, info);
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed);
    CGSize pointSize = CGSizeMake(
        (CGFloat)info.size.width, (CGFloat)info.size.height);
    BOOL nativeSystemMask = MTUsesNativeSystemMask();
    id readyResult = MTReadyReplacementResolver(
        (NSString *)bundleIdentifier, pointSize, (CGFloat)info.scale);
    if (readyResult != nil && nativeSystemMask == MTUsesNativeSystemMask()) {
        id readyAppearance = maskedProducer && nativeSystemMask
            ? MTNativeSystemMaskedImage(readyResult, info)
            : readyResult;
        if (readyAppearance != nil) {
            MTRecordTransitionReplacement();
            return readyAppearance;
        }
    }

    id originalResult = originalFunction(self, selector, info);
    nativeSystemMask = MTUsesNativeSystemMask();
    BOOL didReplace = NO;
    id result = nil;
    if (nativeSystemMask) {
        id source = MTImageByApplyingResolver(
            (NSString *)bundleIdentifier, originalResult,
            MTSourceReplacementResolver, &didReplace);
        if (didReplace) {
            result = maskedProducer
                ? MTNativeSystemMaskedImage(source, info)
                : source;
            if (result == nil) didReplace = NO;
        }
        if (!didReplace) result = originalResult;
    } else {
        result = MTImageByApplyingResolver(
            (NSString *)bundleIdentifier, originalResult,
            MTAppearanceReplacementResolver, &didReplace);
    }
    if (didReplace) {
        MTRecordTransitionReplacement();
    }
    return result;
}

static id MTHookedIconImageWithInfo(id self,
                                    SEL selector,
                                    MTIconImageInfo info) {
    Class iconClass = object_getClass(self);
    if (!MTRuntimeClassIsSubclassOfClass(iconClass, MTIdentityClass) ||
        MTRuntimeClassIsSubclassOfClass(
            iconClass, MTApplicationIconClass)) {
        return MTOriginalIconImageWithInfo(self, selector, info);
    }
    return MTThemedIconImageWithInfo(
        self, selector, info, MTOriginalIconImageWithInfo, YES);
}

static id MTHookedApplicationIconImageWithInfo(
    id self, SEL selector, MTIconImageInfo info) {
    return MTThemedIconImageWithInfo(
        self, selector, info, MTOriginalApplicationIconImageWithInfo, YES);
}

static id MTHookedApplicationUnmaskedIconImageWithInfo(
    id self, SEL selector, MTIconImageInfo info) {
    return MTThemedIconImageWithInfo(
        self, selector, info,
        MTOriginalApplicationUnmaskedIconImageWithInfo, NO);
}

static id MTHookedVariantImageForIcon(id self, SEL selector, id icon) {
    // Keep SpringBoard's complete cache-fill pipeline. For ordinary app icons
    // the producer Hooks above already return themed pixels, after which the
    // original implementation performs its native pooling/memory mapping.
    id originalResult =
        MTOriginalVariantImageForIcon(self, selector, icon);
    Class iconClass = icon == nil ? Nil : object_getClass(icon);
    if (!MTRuntimeClassIsSubclassOfClass(iconClass, MTIdentityClass)) {
        return originalResult;
    }
    if (MTRuntimeClassIsSubclassOfClass(
            iconClass, MTApplicationIconClass)) {
        return originalResult;
    }
    id bundleIdentifier = MTIdentityValueForIcon(icon);
    if (![bundleIdentifier isKindOfClass:NSString.class]) {
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        (NSString *)bundleIdentifier, originalResult,
        MTAppearanceReplacementResolver, &didReplace);
    if (didReplace) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.transitionReplacements,
            1, memory_order_relaxed);
    }
    return result;
}

static void MTAttemptInstallation(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class targetClass = objc_getClass(MTTargetClassName);
    Class cacheFillClass = objc_getClass(MTCacheFillClassName);
    Class identityClass = objc_getClass(MTIdentityClassName);
    BOOL requiresApplicationProducers =
        MTInstallationMode == MTIconImageCacheAdapterModeSpringBoard;
    Class applicationIconClass = requiresApplicationProducers
        ? objc_getClass(MTApplicationIconClassName) : Nil;
    SEL targetSelector = sel_registerName(MTTargetSelectorName);
    SEL cacheRequestSelector =
        sel_registerName(MTCacheRequestSelectorName);
    SEL cacheFillSelector = sel_registerName(MTCacheFillSelectorName);
    SEL refreshSelector = sel_registerName(MTRefreshSelectorName);
    SEL refreshNotificationSelector =
        sel_registerName(MTRefreshNotificationSelectorName);
    SEL identitySelector = sel_registerName(MTIdentitySelectorName);
    SEL transitionSelector = sel_registerName(MTTransitionSelectorName);
    SEL unmaskedTransitionSelector =
        sel_registerName(MTUnmaskedTransitionSelectorName);
    SEL systemMaskSelector = sel_registerName(MTSystemMaskSelectorName);
    Method targetMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, targetSelector);
    Method cacheRequestMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, cacheRequestSelector);
    Method cacheFillMethod = cacheFillClass == Nil ? NULL :
        class_getInstanceMethod(cacheFillClass, cacheFillSelector);
    Method refreshMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, refreshSelector);
    Method refreshNotificationMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, refreshNotificationSelector);
    Method identityMethod = identityClass == Nil ? NULL :
        class_getInstanceMethod(identityClass, identitySelector);
    Method transitionMethod = identityClass == Nil ? NULL :
        class_getInstanceMethod(identityClass, transitionSelector);
    Method applicationTransitionMethod = applicationIconClass == Nil ? NULL :
        class_getInstanceMethod(applicationIconClass, transitionSelector);
    Method applicationUnmaskedTransitionMethod =
        applicationIconClass == Nil ? NULL :
        class_getInstanceMethod(
            applicationIconClass, unmaskedTransitionSelector);
    Method systemMaskMethod = identityClass == Nil ? NULL :
        class_getClassMethod(identityClass, systemMaskSelector);
    if (targetClass == Nil || cacheFillClass == Nil ||
        identityClass == Nil ||
        (requiresApplicationProducers && applicationIconClass == Nil)) {
        return;
    }
    if (targetMethod == NULL || cacheFillMethod == NULL ||
        identityMethod == NULL ||
        transitionMethod == NULL ||
        (requiresApplicationProducers &&
         (applicationTransitionMethod == NULL ||
          applicationUnmaskedTransitionMethod == NULL))) {
        MTSetState(MTIconImageCacheAdapterStateClassUnavailable);
        return;
    }
    if (cacheRequestMethod == NULL) {
        MTSetState(
            MTIconImageCacheAdapterStateCacheRequestMethodUnavailable);
        return;
    }
    if (systemMaskMethod == NULL) {
        MTSetState(MTIconImageCacheAdapterStateSystemMaskMethodUnavailable);
        return;
    }
    if (refreshMethod == NULL) {
        MTSetState(MTIconImageCacheAdapterStateRefreshMethodUnavailable);
        return;
    }
    if (refreshNotificationMethod == NULL) {
        MTSetState(
            MTIconImageCacheAdapterStateRefreshNotificationMethodUnavailable);
        return;
    }

    if (!MTSpringBoardHomeClassMatchesExpectedImage(targetClass)) {
        MTSetState(MTIconImageCacheAdapterStateTargetClassImageMismatch);
        return;
    }
    if (!MTSpringBoardHomeClassMatchesExpectedImage(cacheFillClass)) {
        MTSetState(MTIconImageCacheAdapterStateCacheFillClassImageMismatch);
        return;
    }
    const char *targetTypeEncoding = method_getTypeEncoding(targetMethod);
    if (targetTypeEncoding == NULL ||
        strcmp(targetTypeEncoding, MTTargetTypeEncoding) != 0) {
        MTSetState(MTIconImageCacheAdapterStateTargetMethodTypeMismatch);
        return;
    }
    IMP targetImplementation = method_getImplementation(targetMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(targetImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateTargetImplementationImageMismatch);
        return;
    }
    const char *cacheRequestTypeEncoding =
        method_getTypeEncoding(cacheRequestMethod);
    if (cacheRequestTypeEncoding == NULL ||
        strcmp(cacheRequestTypeEncoding,
               MTCacheRequestTypeEncoding) != 0) {
        MTSetState(
            MTIconImageCacheAdapterStateCacheRequestMethodTypeMismatch);
        return;
    }
    IMP cacheRequestImplementation =
        method_getImplementation(cacheRequestMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
            cacheRequestImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateCacheRequestImplementationImageMismatch);
        return;
    }
    const char *cacheFillTypeEncoding =
        method_getTypeEncoding(cacheFillMethod);
    if (cacheFillTypeEncoding == NULL ||
        strcmp(cacheFillTypeEncoding, MTCacheFillTypeEncoding) != 0) {
        MTSetState(MTIconImageCacheAdapterStateCacheFillMethodTypeMismatch);
        return;
    }
    IMP cacheFillImplementation = method_getImplementation(cacheFillMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
            cacheFillImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateCacheFillImplementationImageMismatch);
        return;
    }
    const char *refreshTypeEncoding = method_getTypeEncoding(refreshMethod);
    if (refreshTypeEncoding == NULL ||
        strcmp(refreshTypeEncoding, MTRefreshTypeEncoding) != 0) {
        MTSetState(MTIconImageCacheAdapterStateRefreshMethodTypeMismatch);
        return;
    }
    IMP refreshImplementation = method_getImplementation(refreshMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(refreshImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateRefreshImplementationImageMismatch);
        return;
    }
    const char *refreshNotificationTypeEncoding =
        method_getTypeEncoding(refreshNotificationMethod);
    if (refreshNotificationTypeEncoding == NULL ||
        strcmp(refreshNotificationTypeEncoding,
               MTRefreshNotificationTypeEncoding) != 0) {
        MTSetState(
            MTIconImageCacheAdapterStateRefreshNotificationMethodTypeMismatch);
        return;
    }
    IMP refreshNotificationImplementation =
        method_getImplementation(refreshNotificationMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
            refreshNotificationImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateRefreshNotificationImplementationImageMismatch);
        return;
    }

    if (!MTSpringBoardHomeClassMatchesExpectedImage(identityClass)) {
        MTSetState(MTIconImageCacheAdapterStateIdentityClassImageMismatch);
        return;
    }
    if (requiresApplicationProducers &&
        !MTRuntimeClassIsSubclassOfClass(
            applicationIconClass, identityClass)) {
        MTSetState(MTIconImageCacheAdapterStateIdentityClassImageMismatch);
        return;
    }
    const char *identityTypeEncoding = method_getTypeEncoding(identityMethod);
    if (identityTypeEncoding == NULL ||
        strcmp(identityTypeEncoding, MTIdentityTypeEncoding) != 0) {
        MTSetState(MTIconImageCacheAdapterStateIdentityMethodTypeMismatch);
        return;
    }
    IMP identityImplementation = method_getImplementation(identityMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(identityImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateIdentityImplementationImageMismatch);
        return;
    }
    const char *transitionTypeEncoding =
        method_getTypeEncoding(transitionMethod);
    if (transitionTypeEncoding == NULL ||
        strcmp(transitionTypeEncoding, MTTransitionTypeEncoding) != 0) {
        MTSetState(
            MTIconImageCacheAdapterStateTransitionMethodTypeMismatch);
        return;
    }
    IMP transitionImplementation =
        method_getImplementation(transitionMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
            transitionImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateTransitionImplementationImageMismatch);
        return;
    }
    IMP applicationTransitionImplementation = NULL;
    IMP applicationUnmaskedTransitionImplementation = NULL;
    if (requiresApplicationProducers) {
        const char *applicationTransitionTypeEncoding =
            method_getTypeEncoding(applicationTransitionMethod);
        const char *applicationUnmaskedTransitionTypeEncoding =
            method_getTypeEncoding(applicationUnmaskedTransitionMethod);
        if (applicationTransitionTypeEncoding == NULL ||
            strcmp(applicationTransitionTypeEncoding,
                   MTTransitionTypeEncoding) != 0 ||
            applicationUnmaskedTransitionTypeEncoding == NULL ||
            strcmp(applicationUnmaskedTransitionTypeEncoding,
                   MTTransitionTypeEncoding) != 0) {
            MTSetState(
                MTIconImageCacheAdapterStateTransitionMethodTypeMismatch);
            return;
        }
        applicationTransitionImplementation =
            method_getImplementation(applicationTransitionMethod);
        applicationUnmaskedTransitionImplementation =
            method_getImplementation(applicationUnmaskedTransitionMethod);
        if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
                applicationTransitionImplementation) ||
            !MTSpringBoardHomeImplementationMatchesExpectedImage(
                applicationUnmaskedTransitionImplementation)) {
            MTSetState(
                MTIconImageCacheAdapterStateTransitionImplementationImageMismatch);
            return;
        }
    }
    const char *systemMaskTypeEncoding =
        method_getTypeEncoding(systemMaskMethod);
    if (systemMaskTypeEncoding == NULL ||
        strcmp(systemMaskTypeEncoding, MTSystemMaskTypeEncoding) != 0) {
        MTSetState(
            MTIconImageCacheAdapterStateSystemMaskMethodTypeMismatch);
        return;
    }
    IMP systemMaskImplementation =
        method_getImplementation(systemMaskMethod);
    if (!MTSpringBoardHomeImplementationMatchesExpectedImage(
            systemMaskImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateSystemMaskImplementationImageMismatch);
        return;
    }

    if (!MTReplacementPreparation()) {
        MTSetState(
            MTIconImageCacheAdapterStateResolverPreparationFailed);
        return;
    }

    MTTargetClass = targetClass;
    MTRefreshSelector = refreshSelector;
    MTRefreshNotificationSelector = refreshNotificationSelector;
    MTIdentityClass = identityClass;
    MTApplicationIconClass = requiresApplicationProducers
        ? applicationIconClass : Nil;
    MTIdentitySelector = identitySelector;
    MTSystemMaskSelector = systemMaskSelector;
    MTSystemMaskImage =
        (MTSystemMaskImageFunction)systemMaskImplementation;
    if (requiresApplicationProducers) {
        // Install the ordinary-application producer overrides before the
        // shared SBIcon fallback. Their original IMPs must remain Apple's
        // implementation, not the later base-class Hook.
        MTOriginalApplicationIconImageWithInfo =
            (MTIconImageWithInfoFunction)applicationTransitionImplementation;
        MSHookMessageEx(applicationIconClass, transitionSelector,
                        (IMP)MTHookedApplicationIconImageWithInfo,
                        (IMP *)&MTOriginalApplicationIconImageWithInfo);
        MTOriginalApplicationUnmaskedIconImageWithInfo =
            (MTIconImageWithInfoFunction)
                applicationUnmaskedTransitionImplementation;
        MSHookMessageEx(applicationIconClass, unmaskedTransitionSelector,
                        (IMP)MTHookedApplicationUnmaskedIconImageWithInfo,
                        (IMP *)&MTOriginalApplicationUnmaskedIconImageWithInfo);
    }
    MTOriginalRealImageForIconOptions =
        (MTRealImageForIconOptionsFunction)targetImplementation;
    MSHookMessageEx(targetClass, targetSelector,
                    (IMP)MTHookedRealImageForIconOptions,
                    (IMP *)&MTOriginalRealImageForIconOptions);
    MTOriginalCacheImageForIcon =
        (MTCacheImageForIconFunction)cacheRequestImplementation;
    MSHookMessageEx(targetClass, cacheRequestSelector,
                    (IMP)MTHookedCacheImageForIcon,
                    (IMP *)&MTOriginalCacheImageForIcon);
    MTOriginalVariantImageForIcon =
        (MTVariantImageForIconFunction)cacheFillImplementation;
    MSHookMessageEx(cacheFillClass, cacheFillSelector,
                    (IMP)MTHookedVariantImageForIcon,
                    (IMP *)&MTOriginalVariantImageForIcon);
    MTOriginalIconImageWithInfo =
        (MTIconImageWithInfoFunction)transitionImplementation;
    MSHookMessageEx(identityClass, transitionSelector,
                    (IMP)MTHookedIconImageWithInfo,
                    (IMP *)&MTOriginalIconImageWithInfo);
    if (MTOriginalRealImageForIconOptions == NULL ||
        MTOriginalCacheImageForIcon == NULL ||
        MTOriginalVariantImageForIcon == NULL ||
        MTOriginalIconImageWithInfo == NULL ||
        (requiresApplicationProducers &&
         (MTOriginalApplicationIconImageWithInfo == NULL ||
          MTOriginalApplicationUnmaskedIconImageWithInfo == NULL)) ||
        MTSystemMaskImage == NULL) {
        MTOriginalRealImageForIconOptions =
            (MTRealImageForIconOptionsFunction)targetImplementation;
        MTSetState(MTIconImageCacheAdapterStateOriginalUnavailable);
        return;
    }
    MTSetState(MTIconImageCacheAdapterStateInstalled);
}

BOOL MTIconImageCacheAdapterSchedule(
    MTIconImageCacheAdapterMode mode,
    MTRuntimeReplacementResolver appearanceResolver,
    MTRuntimeReplacementResolver sourceResolver,
    MTIconReadyReplacementResolver readyResolver,
    MTIconNativeSystemMaskRequirement nativeSystemMaskRequirement,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    (void)error;
    if ((mode != MTIconImageCacheAdapterModeSpringBoard &&
         mode != MTIconImageCacheAdapterModeEmbeddedCache) ||
        appearanceResolver == NULL || sourceResolver == NULL ||
        readyResolver == NULL || nativeSystemMaskRequirement == NULL ||
        preparation == NULL) {
        return NO;
    }
    if (MTRefreshTracker == nil) {
        MTRefreshTracker = [[MTRuntimeTargetedRefreshTracker alloc] init];
    }
    if (MTRefreshTracker == nil) return NO;
    uint32_t expected = MTIconImageCacheAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            &expected,
            MTIconImageCacheAdapterStateScheduled,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected == MTIconImageCacheAdapterStateScheduled ||
            expected == MTIconImageCacheAdapterStateInstalled;
    }
    MTAppearanceReplacementResolver = appearanceResolver;
    MTSourceReplacementResolver = sourceResolver;
    MTReadyReplacementResolver = readyResolver;
    MTNativeSystemMaskRequirement = nativeSystemMaskRequirement;
    MTReplacementPreparation = preparation;
    MTInstallationMode = mode;
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTAttemptInstallation();
        }
    } else {
        MTScheduleInstallPass();
    }
    return YES;
}

void MTIconImageCacheAdapterInstallIfAvailable(void) {
    if (atomic_load_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            memory_order_acquire) != MTIconImageCacheAdapterStateScheduled) {
        return;
    }
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            MTAttemptInstallation();
        }
    } else {
        MTScheduleInstallPass();
    }
}

id MTIconImageCacheAdapterResolveReplacement(NSString *identifier,
                                             id originalResult,
                                             BOOL *didReplace) {
    if (MTAppearanceReplacementResolver == NULL || identifier.length == 0) {
        if (didReplace != NULL) *didReplace = NO;
        return originalResult;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed);
    BOOL replaced = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        identifier, originalResult,
        MTAppearanceReplacementResolver, &replaced);
    if (replaced) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.transitionReplacements,
            1, memory_order_relaxed);
    }
    if (didReplace != NULL) *didReplace = replaced;
    return result;
}

MTRuntimeTargetedRefreshSnapshot *
    MTIconImageCacheAdapterCaptureRefreshSnapshot(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    MTRuntimeTargetedRefreshTracker *tracker = MTRefreshTracker;
    if (tracker == nil) {
        tracker = [[MTRuntimeTargetedRefreshTracker alloc] init];
    }
    return tracker.snapshot;
}

void MTIconImageCacheAdapterRefreshSnapshot(
    MTRuntimeTargetedRefreshSnapshot *snapshot,
    NSSet<NSString *> *identifiers) {
    if (![NSThread isMainThread] || snapshot == nil ||
        atomic_load_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            memory_order_acquire) != MTIconImageCacheAdapterStateInstalled ||
        MTTargetClass == Nil || MTRefreshSelector == NULL ||
        MTRefreshNotificationSelector == NULL) {
        return;
    }
    NSArray<MTRuntimeRefreshTarget *> *targets =
        [snapshot targetsForIdentifiers:identifiers];
    if (targets.count == 0) return;
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.refreshExecutions,
        1, memory_order_relaxed);
    for (MTRuntimeRefreshTarget *target in targets) {
        Class recipientClass = object_getClass(target.recipient);
        Method refreshMethod = recipientClass == Nil ? NULL :
            class_getInstanceMethod(recipientClass, MTRefreshSelector);
        Method refreshNotificationMethod = recipientClass == Nil ? NULL :
            class_getInstanceMethod(
                recipientClass, MTRefreshNotificationSelector);
        const char *refreshTypeEncoding = refreshMethod == NULL ? NULL :
            method_getTypeEncoding(refreshMethod);
        IMP refreshImplementation = refreshMethod == NULL ? NULL :
            method_getImplementation(refreshMethod);
        const char *refreshNotificationTypeEncoding =
            refreshNotificationMethod == NULL ? NULL :
            method_getTypeEncoding(refreshNotificationMethod);
        IMP refreshNotificationImplementation =
            refreshNotificationMethod == NULL ? NULL :
            method_getImplementation(refreshNotificationMethod);
        if (!MTRuntimeClassIsSubclassOfClass(recipientClass, MTTargetClass) ||
            refreshTypeEncoding == NULL ||
            strcmp(refreshTypeEncoding, MTRefreshTypeEncoding) != 0 ||
            !MTSpringBoardHomeImplementationMatchesExpectedImage(
                refreshImplementation) ||
            refreshNotificationTypeEncoding == NULL ||
            strcmp(refreshNotificationTypeEncoding,
                   MTRefreshNotificationTypeEncoding) != 0 ||
            !MTSpringBoardHomeImplementationMatchesExpectedImage(
                refreshNotificationImplementation) ||
            target.subjects.count == 0) {
            continue;
        }
        ((void (*)(id, SEL, id))objc_msgSend)(
            target.recipient, MTRefreshSelector, target.subjects);
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.refreshCachePurges,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.refreshIconPurges,
            target.subjects.count, memory_order_relaxed);
        for (id subject in target.subjects) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                target.recipient, MTRefreshNotificationSelector, subject);
            atomic_fetch_add_explicit(
                &MTRuntimeIconImageCacheAdapterObservation
                    .refreshObserverNotifications,
                1, memory_order_relaxed);
        }
    }
}
