#import "MTIconImageCacheAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"
#import "MTRuntimeTargetedRefresh.h"
#import "MTSpringBoardHomeABI.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

static const char *const MTTargetClassName = "SBHIconImageCache";
// Keep the outer lookup for weak refresh tracking and an immediate fallback.
static const char *const MTTargetSelectorName = "realImageForIcon:options:";
static const char *const MTTargetTypeEncoding = "@32@0:8@16Q24";
static const char *const MTCacheRequestSelectorName =
    "cacheImageForIcon:options:completionHandler:";
static const char *const MTCacheRequestTypeEncoding = "v40@0:8@16Q24@?32";
// iOS 17's variant cache stores producer results through the single-argument
// boundary. Ordinary app icons stay on its complete native producer path;
// this fallback remains for specialized icons that bypass SBApplicationIcon.
static const char *const MTCacheFillClassName = "SBHIconImageVariantCache";
static const char *const MTCacheFillSelectorName = "_variantImageForIcon:";
static const char *const MTCacheFillTypeEncoding = "@24@0:8@16";
// iOS 18 moved cache generation to an appearance-aware boundary below the
// iOS 17 producers.
// Replacing this method's result still lets SpringBoard perform its native
// pooling, generation bookkeeping, and observer delivery.
static const char *const MTAppearanceCacheFillSelectorName =
    "_variantImageForIcon:imageAppearance:options:";
static const char *const MTAppearanceCacheFillTypeEncoding =
    "@40@0:8@16@24Q32";
static const char *const MTRefreshSelectorName =
    "purgeCachedImagesForIcons:";
static const char *const MTRefreshTypeEncoding = "v24@0:8@16";
static const char *const MTRefreshNotificationSelectorName =
    "notifyObserversOfUpdateForIcon:";
static const char *const MTRefreshNotificationTypeEncoding = "v24@0:8@16";
// iOS 18 replaced the single-argument observer notification with an
// appearance/context ABI. Its public-in-framework recache boundary performs
// the complete variant-cache regeneration and observer delivery internally,
// so MarkTheme never fabricates that private context structure.
static const char *const MTNativeRecacheSelectorName =
    "recacheImagesForIcon:completionHandler:";
static const char *const MTNativeRecacheTypeEncoding = "v32@0:8@16@?24";
static const char *const MTIdentityClassName = "SBIcon";
static const char *const MTIdentitySelectorName = "applicationBundleID";
static const char *const MTIdentityTypeEncoding = "@16@0:8";
// Ordinary app icons get their own producer override so SpringBoard's native
// variant cache can still pool, map, and retain the themed result. Calendar,
// Clock, and other specialized SBIcon subclasses keep the shared fallback.
static const char *const MTApplicationIconClassName = "SBApplicationIcon";
static const char *const MTTransitionSelectorName = "iconImageWithInfo:";
static const char *const MTGeneratedTransitionSelectorName =
    "generateIconImageWithInfo:";
static const char *const MTUnmaskedTransitionSelectorName =
    "unmaskedIconImageWithInfo:";
static const char *const MTTransitionTypeEncoding =
    "@48@0:8{SBIconImageInfo={CGSize=dd}dd}16";
// iOS 18 can feed a newly created animation image view from three sources:
// its direct icon producer, an existing variant-cache result, or an async
// cache placeholder. They converge at this one native layer-content commit.
// Replacing the incoming Apple image here preserves the same carrier-first
// contract as iOS 17 without an overlay or per-frame animation work.
static const char *const MTImageViewClassName = "SBIconImageView";
static const char *const MTImageViewIconSelectorName = "icon";
static const char *const MTImageViewDisplaySelectorName =
    "updateImageContentsWithImage:imageAppearance:"
    "isRealContentsImage:animated:";
static const char *const MTImageViewDisplayTypeEncoding =
    "v40@0:8@16@24B32B36";
// The probed SBIcon class renderer is the same boundary used by
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
typedef id (*MTAppearanceVariantImageForIconFunction)(
    id, SEL, id, id, NSUInteger);
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
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef void (*MTImageViewDisplayFunction)(
    id, SEL, id, id, BOOL, BOOL);
typedef id (*MTSystemMaskImageFunction)(id, SEL, id, MTIconImageInfo);

MTIconImageCacheAdapterObservation MTRuntimeIconImageCacheAdapterObservation = {
    .schemaVersion = 8,
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
    .viewRecipientRecords = ATOMIC_VAR_INIT(0),
    .refreshNativeRecaches = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconImageCacheAdapterObservation) == 160,
    "The M3-E ProcessAdapter observation layout must remain fixed.");

static MTRealImageForIconOptionsFunction MTOriginalRealImageForIconOptions;
static MTCacheImageForIconFunction MTOriginalCacheImageForIcon;
static MTVariantImageForIconFunction MTOriginalVariantImageForIcon;
static MTAppearanceVariantImageForIconFunction
    MTOriginalAppearanceVariantImageForIcon;
static MTIconImageWithInfoFunction MTOriginalIconImageWithInfo;
static MTIconImageWithInfoFunction MTOriginalApplicationIconImageWithInfo;
static MTIconImageWithInfoFunction
    MTOriginalApplicationGeneratedIconImageWithInfo;
static MTIconImageWithInfoFunction
    MTOriginalApplicationUnmaskedIconImageWithInfo;
static MTImageViewDisplayFunction MTOriginalImageViewDisplay;
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
static SEL MTNativeRecacheSelector;
static Class MTIdentityClass = Nil;
static Class MTApplicationIconClass = Nil;
static SEL MTIdentitySelector;
static SEL MTImageViewIconSelector;
static SEL MTSystemMaskSelector;
static _Atomic(bool) MTInstallPassScheduled = false;
static _Atomic(uint64_t) MTRefreshSequence = 0;
static _Atomic(uint64_t) MTImageViewDisplayCalls = 0;
static char MTLateRecacheSequenceAssociationKey;

static void MTAttemptInstallation(void);

static NSString *const MTAdapterID = @"springboard.icon-image-cache";

static NSString *MTDiagnosticClassName(id object) {
    if (object == nil) return @"<nil>";
    NSString *name = NSStringFromClass(object_getClass(object));
    return name.length > 0 ? name : @"<unknown>";
}

static void MTRecordProducerDiagnosticSample(
    id icon,
    SEL selector,
    id bundleIdentifier,
    MTIconImageInfo info,
    BOOL nativeSystemMask,
    uint64_t transitionCall,
    NSString *outcome,
    id originalResult) {
    if (transitionCall != 1 && transitionCall != 16 &&
        transitionCall != 64) return;
    NSString *identifier = [bundleIdentifier isKindOfClass:NSString.class]
        ? (NSString *)bundleIdentifier : @"<non-string>";
    MTRuntimeABIReportRecordSample(MTAdapterID, @{
        @"call" : @(transitionCall),
        @"selector" : NSStringFromSelector(selector) ?: @"<unknown>",
        @"iconClass" : MTDiagnosticClassName(icon),
        @"bundleIdentifier" : identifier,
        @"pointWidth" : @(info.size.width),
        @"scale" : @(info.scale),
        @"nativeSystemMask" : @(nativeSystemMask),
        @"outcome" : outcome.length > 0 ? outcome : @"unknown",
        @"originalResultClass" : MTDiagnosticClassName(originalResult),
    });
}

static NSString *MTEncodingString(const char *encoding) {
    return encoding == NULL ? nil : @(encoding);
}

// Reports one method-type contract and returns whether it matched. Recording
// the encoding the running system actually published is what lets an
// unsupported build be diagnosed from a user report.
static BOOL MTReportMethodType(NSString *contractID,
                               Method method,
                               const char *expectedEncoding) {
    const char *actual =
        method == NULL ? NULL : method_getTypeEncoding(method);
    BOOL satisfied = actual != NULL &&
        strcmp(actual, expectedEncoding) == 0;
    MTRuntimeABIReportRecordContract(
        MTAdapterID, contractID, satisfied,
        MTEncodingString(expectedEncoding), MTEncodingString(actual));
    return satisfied;
}

static void MTReportPresence(NSString *contractID, BOOL present) {
    MTRuntimeABIReportRecordContract(
        MTAdapterID, contractID, present, nil, present ? @"present" : nil);
}

// Reports one implementation-provenance contract and returns whether the
// implementation is hookable. Coexistence accepts Apple's original, another
// Apple image, and other tweaks' chained Hooks alike; a non-system image is
// annotated as third-party so the composition stays visible in a user report.
static BOOL MTReportImplementationProvenance(NSString *contractID,
                                             IMP implementation) {
    BOOL hookable =
        MTSpringBoardHomeImplementationMatchesExpectedImage(implementation);
    NSString *actual = MTEncodingString(
        MTRuntimeImplementationImageName(implementation));
    if (hookable && actual != nil &&
        !MTRuntimeImplementationMatchesSystemImagePath(implementation)) {
        actual = [actual stringByAppendingString:@" (third-party)"];
    }
    MTRuntimeABIReportRecordContract(
        MTAdapterID, contractID, hookable,
        @"Apple system or third-party image (chained for coexistence)",
        actual);
    return hookable;
}

static NSString *MTStateName(MTIconImageCacheAdapterState state) {
    switch (state) {
        case MTIconImageCacheAdapterStateDormant: return @"Dormant";
        case MTIconImageCacheAdapterStateScheduled: return @"Scheduled";
        case MTIconImageCacheAdapterStateInstalled: return @"Installed";
        case MTIconImageCacheAdapterStateClassUnavailable:
            return @"ClassUnavailable";
        case MTIconImageCacheAdapterStateTargetClassImageMismatch:
            return @"TargetClassImageMismatch";
        case MTIconImageCacheAdapterStateTargetMethodTypeMismatch:
            return @"TargetMethodTypeMismatch";
        case MTIconImageCacheAdapterStateTargetImplementationImageMismatch:
            return @"TargetImplementationImageMismatch";
        case MTIconImageCacheAdapterStateIdentityClassImageMismatch:
            return @"IdentityClassImageMismatch";
        case MTIconImageCacheAdapterStateIdentityMethodTypeMismatch:
            return @"IdentityMethodTypeMismatch";
        case MTIconImageCacheAdapterStateIdentityImplementationImageMismatch:
            return @"IdentityImplementationImageMismatch";
        case MTIconImageCacheAdapterStateOriginalUnavailable:
            return @"OriginalUnavailable";
        case MTIconImageCacheAdapterStateResolverPreparationFailed:
            return @"ResolverPreparationFailed";
        case MTIconImageCacheAdapterStateRefreshMethodUnavailable:
            return @"RefreshMethodUnavailable";
        case MTIconImageCacheAdapterStateRefreshMethodTypeMismatch:
            return @"RefreshMethodTypeMismatch";
        case MTIconImageCacheAdapterStateRefreshImplementationImageMismatch:
            return @"RefreshImplementationImageMismatch";
        case MTIconImageCacheAdapterStateRefreshNotificationMethodUnavailable:
            return @"RefreshNotificationMethodUnavailable";
        case MTIconImageCacheAdapterStateRefreshNotificationMethodTypeMismatch:
            return @"RefreshNotificationMethodTypeMismatch";
        case MTIconImageCacheAdapterStateRefreshNotificationImplementationImageMismatch:
            return @"RefreshNotificationImplementationImageMismatch";
        case MTIconImageCacheAdapterStateTransitionMethodTypeMismatch:
            return @"TransitionMethodTypeMismatch";
        case MTIconImageCacheAdapterStateTransitionImplementationImageMismatch:
            return @"TransitionImplementationImageMismatch";
        case MTIconImageCacheAdapterStateCacheFillClassImageMismatch:
            return @"CacheFillClassImageMismatch";
        case MTIconImageCacheAdapterStateCacheFillMethodTypeMismatch:
            return @"CacheFillMethodTypeMismatch";
        case MTIconImageCacheAdapterStateCacheFillImplementationImageMismatch:
            return @"CacheFillImplementationImageMismatch";
        case MTIconImageCacheAdapterStateSystemMaskMethodUnavailable:
            return @"SystemMaskMethodUnavailable";
        case MTIconImageCacheAdapterStateSystemMaskMethodTypeMismatch:
            return @"SystemMaskMethodTypeMismatch";
        case MTIconImageCacheAdapterStateSystemMaskImplementationImageMismatch:
            return @"SystemMaskImplementationImageMismatch";
        case MTIconImageCacheAdapterStateCacheRequestMethodUnavailable:
            return @"CacheRequestMethodUnavailable";
        case MTIconImageCacheAdapterStateCacheRequestMethodTypeMismatch:
            return @"CacheRequestMethodTypeMismatch";
        case MTIconImageCacheAdapterStateCacheRequestImplementationImageMismatch:
            return @"CacheRequestImplementationImageMismatch";
    }
    return @"Unknown";
}

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
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, (uint32_t)state, MTStateName(state));
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
    uint64_t transitionCall = atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed) + 1;
    id bundleIdentifier = MTIdentityValueForIcon(self);
    if (![bundleIdentifier isKindOfClass:NSString.class]) {
        id originalResult = originalFunction(self, selector, info);
        MTRecordProducerDiagnosticSample(
            self, selector, bundleIdentifier, info,
            MTUsesNativeSystemMask(), transitionCall,
            @"identity-not-string", originalResult);
        return originalResult;
    }
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
            MTRecordProducerDiagnosticSample(
                self, selector, bundleIdentifier, info,
                nativeSystemMask, transitionCall,
                @"ready-replacement", nil);
            return readyAppearance;
        }
    }

    id originalResult = originalFunction(self, selector, info);
    nativeSystemMask = MTUsesNativeSystemMask();
    BOOL didReplace = NO;
    id result = nil;
    NSString *outcome = nil;
    if (nativeSystemMask) {
        id source = MTImageByApplyingResolver(
            (NSString *)bundleIdentifier, originalResult,
            MTSourceReplacementResolver, &didReplace);
        if (didReplace) {
            result = maskedProducer
                ? MTNativeSystemMaskedImage(source, info)
                : source;
            if (result == nil) {
                didReplace = NO;
                outcome = @"native-mask-failed";
            }
        }
        if (!didReplace) {
            result = originalResult;
            if (outcome == nil) outcome = @"source-miss";
        } else {
            outcome = @"source-replacement";
        }
    } else {
        result = MTImageByApplyingResolver(
            (NSString *)bundleIdentifier, originalResult,
            MTAppearanceReplacementResolver, &didReplace);
        outcome = didReplace
            ? @"appearance-replacement" : @"appearance-miss";
    }
    if (didReplace) {
        MTRecordTransitionReplacement();
    }
    MTRecordProducerDiagnosticSample(
        self, selector, bundleIdentifier, info,
        nativeSystemMask, transitionCall, outcome, originalResult);
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

static id MTHookedApplicationGeneratedIconImageWithInfo(
    id self, SEL selector, MTIconImageInfo info) {
    return MTThemedIconImageWithInfo(
        self, selector, info,
        MTOriginalApplicationGeneratedIconImageWithInfo, YES);
}

static id MTHookedApplicationUnmaskedIconImageWithInfo(
    id self, SEL selector, MTIconImageInfo info) {
    return MTThemedIconImageWithInfo(
        self, selector, info,
        MTOriginalApplicationUnmaskedIconImageWithInfo, NO);
}

static void MTHookedImageViewDisplay(
    id self,
    SEL selector,
    id image,
    id imageAppearance,
    BOOL isRealContentsImage,
    BOOL animated) {
    // The incoming image is already Apple's exact producer/cache/placeholder
    // carrier. Substitute the resolved pixels before SpringBoard records its
    // displayedImage and starts its native contents animation, then invoke the
    // original consumer exactly once.
    id icon = ((MTObjectGetterFunction)objc_msgSend)(
        self, MTImageViewIconSelector);
    NSString *bundleIdentifier = MTBundleIdentifierForTrackedIcon(icon);
    BOOL didReplace = NO;
    id result = image;
    if (bundleIdentifier.length > 0) {
        result = MTImageByApplyingResolver(
            bundleIdentifier, image,
            MTAppearanceReplacementResolver, &didReplace);
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed);
    uint64_t displayCall = atomic_fetch_add_explicit(
        &MTImageViewDisplayCalls, 1, memory_order_relaxed) + 1;
    if (didReplace) MTRecordTransitionReplacement();
    if (displayCall == 1 || displayCall == 16 || displayCall == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-cache.animation-display", @{
                @"call" : @(displayCall),
                @"selector" : NSStringFromSelector(selector) ?: @"<unknown>",
                @"iconClass" : MTDiagnosticClassName(icon),
                @"bundleIdentifier" :
                    bundleIdentifier ?: @"<unavailable>",
                @"imageAppearanceClass" :
                    MTDiagnosticClassName(imageAppearance),
                @"realContents" : @(isRealContentsImage),
                @"animated" : @(animated),
                @"outcome" : didReplace
                    ? (isRealContentsImage ? @"display-real-replacement" :
                                             @"display-placeholder-replacement")
                    : (bundleIdentifier.length > 0 ? @"resolver-miss" :
                                                     @"identity-miss"),
                @"incomingImageClass" : MTDiagnosticClassName(image),
                @"resultClass" : MTDiagnosticClassName(result),
            });
    }
    MTOriginalImageViewDisplay(
        self, selector, result, imageAppearance,
        isRealContentsImage, animated);
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

static id MTHookedAppearanceVariantImageForIcon(
    id self,
    SEL selector,
    id icon,
    id imageAppearance,
    NSUInteger options) {
    id originalResult = MTOriginalAppearanceVariantImageForIcon(
        self, selector, icon, imageAppearance, options);
    uint64_t transitionCall = atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.transitionCalls,
        1, memory_order_relaxed) + 1;
    NSString *bundleIdentifier = MTBundleIdentifierForTrackedIcon(icon);
    BOOL didReplace = NO;
    id result = originalResult;
    if (bundleIdentifier.length > 0) {
        result = MTRuntimeResultByApplyingReplacementResolver(
            bundleIdentifier, originalResult,
            MTAppearanceReplacementResolver, &didReplace);
    }
    if (didReplace) {
        MTRecordTransitionReplacement();
    }
    if (transitionCall == 1 || transitionCall == 16 ||
        transitionCall == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-cache.appearance-variant", @{
                @"call" : @(transitionCall),
                @"selector" : NSStringFromSelector(selector) ?: @"<unknown>",
                @"iconClass" : MTDiagnosticClassName(icon),
                @"bundleIdentifier" : bundleIdentifier ?: @"<unavailable>",
                @"imageAppearanceClass" :
                    MTDiagnosticClassName(imageAppearance),
                @"options" : @(options),
                @"outcome" : didReplace ? @"replacement" :
                    (bundleIdentifier.length > 0 ? @"resolver-miss" :
                                                   @"identity-miss"),
                @"originalResultClass" :
                    MTDiagnosticClassName(originalResult),
                @"resultClass" : MTDiagnosticClassName(result),
            });
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
    Class imageViewClass = requiresApplicationProducers
        ? objc_getClass(MTImageViewClassName) : Nil;
    SEL targetSelector = sel_registerName(MTTargetSelectorName);
    SEL cacheRequestSelector =
        sel_registerName(MTCacheRequestSelectorName);
    SEL cacheFillSelector = sel_registerName(MTCacheFillSelectorName);
    SEL appearanceCacheFillSelector =
        sel_registerName(MTAppearanceCacheFillSelectorName);
    SEL refreshSelector = sel_registerName(MTRefreshSelectorName);
    SEL refreshNotificationSelector =
        sel_registerName(MTRefreshNotificationSelectorName);
    SEL nativeRecacheSelector =
        sel_registerName(MTNativeRecacheSelectorName);
    SEL identitySelector = sel_registerName(MTIdentitySelectorName);
    SEL transitionSelector = sel_registerName(MTTransitionSelectorName);
    SEL generatedTransitionSelector =
        sel_registerName(MTGeneratedTransitionSelectorName);
    SEL unmaskedTransitionSelector =
        sel_registerName(MTUnmaskedTransitionSelectorName);
    SEL imageViewIconSelector =
        sel_registerName(MTImageViewIconSelectorName);
    SEL imageViewDisplaySelector =
        sel_registerName(MTImageViewDisplaySelectorName);
    SEL systemMaskSelector = sel_registerName(MTSystemMaskSelectorName);
    Method targetMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, targetSelector);
    Method cacheRequestMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, cacheRequestSelector);
    Method cacheFillMethod = cacheFillClass == Nil ? NULL :
        class_getInstanceMethod(cacheFillClass, cacheFillSelector);
    Method appearanceCacheFillMethod = cacheFillClass == Nil ? NULL :
        class_getInstanceMethod(cacheFillClass, appearanceCacheFillSelector);
    Method refreshMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, refreshSelector);
    Method refreshNotificationMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, refreshNotificationSelector);
    Method nativeRecacheMethod = targetClass == Nil ? NULL :
        class_getInstanceMethod(targetClass, nativeRecacheSelector);
    Method identityMethod = identityClass == Nil ? NULL :
        class_getInstanceMethod(identityClass, identitySelector);
    Method transitionMethod = identityClass == Nil ? NULL :
        class_getInstanceMethod(identityClass, transitionSelector);
    Method applicationTransitionMethod = applicationIconClass == Nil ? NULL :
        class_getInstanceMethod(applicationIconClass, transitionSelector);
    Method generatedTransitionMethod = applicationIconClass == Nil ? NULL :
        class_getInstanceMethod(
            applicationIconClass, generatedTransitionSelector);
    Method applicationUnmaskedTransitionMethod =
        applicationIconClass == Nil ? NULL :
        class_getInstanceMethod(
            applicationIconClass, unmaskedTransitionSelector);
    Method imageViewIconMethod = imageViewClass == Nil ? NULL :
        class_getInstanceMethod(imageViewClass, imageViewIconSelector);
    Method imageViewDisplayMethod = imageViewClass == Nil ? NULL :
        class_getInstanceMethod(imageViewClass, imageViewDisplaySelector);
    Method systemMaskMethod = identityClass == Nil ? NULL :
        class_getClassMethod(identityClass, systemMaskSelector);
    IMP generatedTransitionImplementation = NULL;
    BOOL generatedTransitionHookable = NO;
    IMP imageViewDisplayImplementation = NULL;
    BOOL imageViewDisplayHookable = NO;
    MTReportPresence(@"class:SBHIconImageCache", targetClass != Nil);
    MTReportPresence(@"class:SBHIconImageVariantCache", cacheFillClass != Nil);
    MTReportPresence(@"class:SBIcon", identityClass != Nil);
    if (requiresApplicationProducers) {
        MTReportPresence(@"class:SBApplicationIcon",
                         applicationIconClass != Nil);
        MTReportPresence(@"class:SBIconImageView", imageViewClass != Nil);
    }
    MTReportPresence(
        @"method:SBHIconImageCache.realImageForIcon:options:",
        targetMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageCache.cacheImageForIcon:options:completionHandler:",
        cacheRequestMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageVariantCache._variantImageForIcon:",
        cacheFillMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageVariantCache."
         "_variantImageForIcon:imageAppearance:options:",
        appearanceCacheFillMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageCache.purgeCachedImagesForIcons:",
        refreshMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageCache.notifyObserversOfUpdateForIcon:",
        refreshNotificationMethod != NULL);
    MTReportPresence(
        @"method:SBHIconImageCache.recacheImagesForIcon:completionHandler:",
        nativeRecacheMethod != NULL);
    MTReportPresence(@"method:SBIcon.applicationBundleID",
                     identityMethod != NULL);
    MTReportPresence(@"method:SBIcon.iconImageWithInfo:",
                     transitionMethod != NULL);
    if (requiresApplicationProducers) {
        MTReportPresence(
            @"method:SBIconImageView.icon", imageViewIconMethod != NULL);
        MTReportPresence(
            @"method:SBIconImageView."
             "updateImageContentsWithImage:imageAppearance:"
             "isRealContentsImage:animated:",
            imageViewDisplayMethod != NULL);
        MTReportPresence(@"method:SBApplicationIcon.iconImageWithInfo:",
                         applicationTransitionMethod != NULL);
        MTReportPresence(
            @"method:SBApplicationIcon.generateIconImageWithInfo:",
            generatedTransitionMethod != NULL);
        if (generatedTransitionMethod != NULL) {
            generatedTransitionHookable = MTReportMethodType(
                @"encoding:SBApplicationIcon."
                 "generateIconImageWithInfo:",
                generatedTransitionMethod, MTTransitionTypeEncoding);
            if (generatedTransitionHookable) {
                generatedTransitionImplementation =
                    method_getImplementation(generatedTransitionMethod);
                generatedTransitionHookable =
                    MTReportImplementationProvenance(
                        @"impl:SBApplicationIcon."
                         "generateIconImageWithInfo:",
                        generatedTransitionImplementation);
            }
        }
        MTReportPresence(
            @"capability:generated-application-producer",
            generatedTransitionHookable);
        BOOL imageViewClassImageMatches = imageViewClass != Nil &&
            MTSpringBoardHomeClassMatchesExpectedImage(imageViewClass);
        if (imageViewClass != Nil) {
            MTRuntimeABIReportRecordContract(
                MTAdapterID, @"image:SBIconImageView",
                imageViewClassImageMatches, @"SpringBoardHome",
                MTEncodingString(class_getImageName(imageViewClass)));
        }
        BOOL imageViewIconHookable = imageViewClassImageMatches &&
            imageViewIconMethod != NULL && MTReportMethodType(
                @"encoding:SBIconImageView.icon",
                imageViewIconMethod, MTIdentityTypeEncoding);
        if (imageViewIconHookable) {
            imageViewIconHookable = MTReportImplementationProvenance(
                @"impl:SBIconImageView.icon",
                method_getImplementation(imageViewIconMethod));
        }
        imageViewDisplayHookable = imageViewIconHookable &&
            imageViewDisplayMethod != NULL && MTReportMethodType(
                @"encoding:SBIconImageView."
                 "updateImageContentsWithImage:imageAppearance:"
                 "isRealContentsImage:animated:",
                imageViewDisplayMethod,
                MTImageViewDisplayTypeEncoding);
        if (imageViewDisplayHookable) {
            imageViewDisplayImplementation =
                method_getImplementation(imageViewDisplayMethod);
            imageViewDisplayHookable = MTReportImplementationProvenance(
                @"impl:SBIconImageView."
                 "updateImageContentsWithImage:imageAppearance:"
                 "isRealContentsImage:animated:",
                imageViewDisplayImplementation);
        }
        MTReportPresence(
            @"capability:animation-image-display-boundary",
            imageViewDisplayHookable);
        MTReportPresence(
            @"method:SBApplicationIcon.unmaskedIconImageWithInfo:",
            applicationUnmaskedTransitionMethod != NULL);
    }
    MTReportPresence(@"method:SBIcon+iconImageFromUnmaskedImage:info:",
                     systemMaskMethod != NULL);
    if (identityClass == Nil ||
        (requiresApplicationProducers && applicationIconClass == Nil)) {
        return;
    }
    if (identityMethod == NULL || transitionMethod == NULL ||
        (requiresApplicationProducers &&
         (applicationTransitionMethod == NULL ||
          applicationUnmaskedTransitionMethod == NULL))) {
        MTSetState(MTIconImageCacheAdapterStateClassUnavailable);
        return;
    }
    if (systemMaskMethod == NULL) {
        MTSetState(MTIconImageCacheAdapterStateSystemMaskMethodUnavailable);
        return;
    }

    // iOS 18 can remove or rename individual SpringBoardHome cache methods
    // while leaving the stable SBIcon producers intact. Probe each cache and
    // refresh boundary independently; a missing optional capability must not
    // suppress the core producer Hooks.
    BOOL targetClassImageMatches = targetClass != Nil &&
        MTSpringBoardHomeClassMatchesExpectedImage(targetClass);
    if (targetClass != Nil) {
        MTRuntimeABIReportRecordContract(
            MTAdapterID, @"image:SBHIconImageCache",
            targetClassImageMatches, @"SpringBoardHome",
            MTEncodingString(class_getImageName(targetClass)));
    }
    IMP targetImplementation = NULL;
    BOOL outerCacheHookable = targetClassImageMatches &&
        targetMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageCache.realImageForIcon:options:",
            targetMethod, MTTargetTypeEncoding);
    if (outerCacheHookable) {
        targetImplementation = method_getImplementation(targetMethod);
        outerCacheHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageCache.realImageForIcon:options:",
            targetImplementation);
    }

    IMP cacheRequestImplementation = NULL;
    BOOL cacheRequestHookable = targetClassImageMatches &&
        cacheRequestMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageCache.cacheImageForIcon:options:"
             "completionHandler:",
            cacheRequestMethod, MTCacheRequestTypeEncoding);
    if (cacheRequestHookable) {
        cacheRequestImplementation =
            method_getImplementation(cacheRequestMethod);
        cacheRequestHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageCache.cacheImageForIcon:options:"
             "completionHandler:",
            cacheRequestImplementation);
    }

    BOOL cacheFillClassImageMatches = cacheFillClass != Nil &&
        MTSpringBoardHomeClassMatchesExpectedImage(cacheFillClass);
    if (cacheFillClass != Nil) {
        MTRuntimeABIReportRecordContract(
            MTAdapterID, @"image:SBHIconImageVariantCache",
            cacheFillClassImageMatches, @"SpringBoardHome",
            MTEncodingString(class_getImageName(cacheFillClass)));
    }
    IMP cacheFillImplementation = NULL;
    BOOL cacheFillHookable = cacheFillClassImageMatches &&
        cacheFillMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageVariantCache._variantImageForIcon:",
            cacheFillMethod, MTCacheFillTypeEncoding);
    if (cacheFillHookable) {
        cacheFillImplementation = method_getImplementation(cacheFillMethod);
        cacheFillHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageVariantCache._variantImageForIcon:",
            cacheFillImplementation);
    }
    IMP appearanceCacheFillImplementation = NULL;
    BOOL appearanceCacheFillHookable = cacheFillClassImageMatches &&
        appearanceCacheFillMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageVariantCache."
             "_variantImageForIcon:imageAppearance:options:",
            appearanceCacheFillMethod,
            MTAppearanceCacheFillTypeEncoding);
    if (appearanceCacheFillHookable) {
        appearanceCacheFillImplementation =
            method_getImplementation(appearanceCacheFillMethod);
        appearanceCacheFillHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageVariantCache."
             "_variantImageForIcon:imageAppearance:options:",
            appearanceCacheFillImplementation);
    }

    IMP refreshImplementation = NULL;
    IMP refreshNotificationImplementation = NULL;
    BOOL refreshPurgeHookable = targetClassImageMatches &&
        refreshMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageCache.purgeCachedImagesForIcons:",
            refreshMethod, MTRefreshTypeEncoding);
    if (refreshPurgeHookable) {
        refreshImplementation = method_getImplementation(refreshMethod);
        refreshPurgeHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageCache.purgeCachedImagesForIcons:",
            refreshImplementation);
    }
    BOOL refreshNotificationHookable = targetClassImageMatches &&
        refreshNotificationMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageCache.notifyObserversOfUpdateForIcon:",
            refreshNotificationMethod,
            MTRefreshNotificationTypeEncoding);
    if (refreshNotificationHookable) {
        refreshNotificationImplementation =
            method_getImplementation(refreshNotificationMethod);
        refreshNotificationHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageCache.notifyObserversOfUpdateForIcon:",
            refreshNotificationImplementation);
    }
    BOOL refreshHookable =
        refreshPurgeHookable && refreshNotificationHookable;
    IMP nativeRecacheImplementation = NULL;
    BOOL nativeRecacheHookable = targetClassImageMatches &&
        nativeRecacheMethod != NULL && MTReportMethodType(
            @"encoding:SBHIconImageCache."
             "recacheImagesForIcon:completionHandler:",
            nativeRecacheMethod, MTNativeRecacheTypeEncoding);
    if (nativeRecacheHookable) {
        nativeRecacheImplementation =
            method_getImplementation(nativeRecacheMethod);
        nativeRecacheHookable = MTReportImplementationProvenance(
            @"impl:SBHIconImageCache."
             "recacheImagesForIcon:completionHandler:",
            nativeRecacheImplementation);
    }
    MTReportPresence(@"capability:outer-icon-cache", outerCacheHookable);
    MTReportPresence(@"capability:cache-recipient-tracking",
                     cacheRequestHookable);
    MTReportPresence(@"capability:variant-cache-fill", cacheFillHookable);
    MTReportPresence(@"capability:appearance-variant-cache-fill",
                     appearanceCacheFillHookable);
    MTReportPresence(@"capability:cache-purge", refreshPurgeHookable);
    MTReportPresence(@"capability:cache-observer-notification",
                     refreshNotificationHookable);
    MTReportPresence(@"capability:native-icon-recache",
                     nativeRecacheHookable);
    MTReportPresence(@"capability:targeted-cache-refresh",
                     refreshHookable || nativeRecacheHookable);

    BOOL identityClassImageMatches =
        MTSpringBoardHomeClassMatchesExpectedImage(identityClass);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBIcon", identityClassImageMatches,
        @"SpringBoardHome",
        MTEncodingString(class_getImageName(identityClass)));
    if (!identityClassImageMatches) {
        MTSetState(MTIconImageCacheAdapterStateIdentityClassImageMismatch);
        return;
    }
    if (requiresApplicationProducers &&
        !MTRuntimeClassIsSubclassOfClass(
            applicationIconClass, identityClass)) {
        MTSetState(MTIconImageCacheAdapterStateIdentityClassImageMismatch);
        return;
    }
    if (!MTReportMethodType(@"encoding:SBIcon.applicationBundleID",
                            identityMethod, MTIdentityTypeEncoding)) {
        MTSetState(MTIconImageCacheAdapterStateIdentityMethodTypeMismatch);
        return;
    }
    IMP identityImplementation = method_getImplementation(identityMethod);
    if (!MTReportImplementationProvenance(
            @"impl:SBIcon.applicationBundleID", identityImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateIdentityImplementationImageMismatch);
        return;
    }
    if (!MTReportMethodType(@"encoding:SBIcon.iconImageWithInfo:",
                            transitionMethod, MTTransitionTypeEncoding)) {
        MTSetState(
            MTIconImageCacheAdapterStateTransitionMethodTypeMismatch);
        return;
    }
    IMP transitionImplementation =
        method_getImplementation(transitionMethod);
    if (!MTReportImplementationProvenance(
            @"impl:SBIcon.iconImageWithInfo:", transitionImplementation)) {
        MTSetState(
            MTIconImageCacheAdapterStateTransitionImplementationImageMismatch);
        return;
    }
    IMP applicationTransitionImplementation = NULL;
    IMP applicationUnmaskedTransitionImplementation = NULL;
    if (requiresApplicationProducers) {
        BOOL maskedSatisfied = MTReportMethodType(
            @"encoding:SBApplicationIcon.iconImageWithInfo:",
            applicationTransitionMethod, MTTransitionTypeEncoding);
        BOOL unmaskedSatisfied = MTReportMethodType(
            @"encoding:SBApplicationIcon.unmaskedIconImageWithInfo:",
            applicationUnmaskedTransitionMethod, MTTransitionTypeEncoding);
        if (!maskedSatisfied || !unmaskedSatisfied) {
            MTSetState(
                MTIconImageCacheAdapterStateTransitionMethodTypeMismatch);
            return;
        }
        applicationTransitionImplementation =
            method_getImplementation(applicationTransitionMethod);
        applicationUnmaskedTransitionImplementation =
            method_getImplementation(applicationUnmaskedTransitionMethod);
        if (!MTReportImplementationProvenance(
                @"impl:SBApplicationIcon.iconImageWithInfo:",
                applicationTransitionImplementation) ||
            !MTReportImplementationProvenance(
                @"impl:SBApplicationIcon.unmaskedIconImageWithInfo:",
                applicationUnmaskedTransitionImplementation)) {
            MTSetState(
                MTIconImageCacheAdapterStateTransitionImplementationImageMismatch);
            return;
        }
    }
    if (!MTReportMethodType(
            @"encoding:SBIcon+iconImageFromUnmaskedImage:info:",
            systemMaskMethod, MTSystemMaskTypeEncoding)) {
        MTSetState(
            MTIconImageCacheAdapterStateSystemMaskMethodTypeMismatch);
        return;
    }
    IMP systemMaskImplementation =
        method_getImplementation(systemMaskMethod);
    if (!MTReportImplementationProvenance(
            @"impl:SBIcon+iconImageFromUnmaskedImage:info:",
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

    MTTargetClass = (refreshHookable || nativeRecacheHookable)
        ? targetClass : Nil;
    MTRefreshSelector = refreshHookable ? refreshSelector : NULL;
    MTRefreshNotificationSelector = refreshHookable
        ? refreshNotificationSelector : NULL;
    MTNativeRecacheSelector = nativeRecacheHookable
        ? nativeRecacheSelector : NULL;
    MTIdentityClass = identityClass;
    MTApplicationIconClass = requiresApplicationProducers
        ? applicationIconClass : Nil;
    MTIdentitySelector = identitySelector;
    MTImageViewIconSelector = requiresApplicationProducers
        ? imageViewIconSelector : NULL;
    MTSystemMaskSelector = systemMaskSelector;
    MTSystemMaskImage =
        (MTSystemMaskImageFunction)systemMaskImplementation;
    if (requiresApplicationProducers) {
        // Install the ordinary-application producer overrides before the
        // shared SBIcon fallback. Their original IMPs must remain Apple's
        // implementation, not the later base-class Hooks.
        if (generatedTransitionHookable) {
            MTOriginalApplicationGeneratedIconImageWithInfo =
                (MTIconImageWithInfoFunction)
                    generatedTransitionImplementation;
            MSHookMessageEx(
                applicationIconClass, generatedTransitionSelector,
                (IMP)MTHookedApplicationGeneratedIconImageWithInfo,
                (IMP *)&MTOriginalApplicationGeneratedIconImageWithInfo);
        }
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
        if (imageViewDisplayHookable) {
            MTOriginalImageViewDisplay =
                (MTImageViewDisplayFunction)
                    imageViewDisplayImplementation;
            MSHookMessageEx(
                imageViewClass, imageViewDisplaySelector,
                (IMP)MTHookedImageViewDisplay,
                (IMP *)&MTOriginalImageViewDisplay);
        }
    }
    if (outerCacheHookable) {
        MTOriginalRealImageForIconOptions =
            (MTRealImageForIconOptionsFunction)targetImplementation;
        MSHookMessageEx(targetClass, targetSelector,
                        (IMP)MTHookedRealImageForIconOptions,
                        (IMP *)&MTOriginalRealImageForIconOptions);
    }
    if (cacheRequestHookable) {
        MTOriginalCacheImageForIcon =
            (MTCacheImageForIconFunction)cacheRequestImplementation;
        MSHookMessageEx(targetClass, cacheRequestSelector,
                        (IMP)MTHookedCacheImageForIcon,
                        (IMP *)&MTOriginalCacheImageForIcon);
    }
    if (cacheFillHookable) {
        MTOriginalVariantImageForIcon =
            (MTVariantImageForIconFunction)cacheFillImplementation;
        MSHookMessageEx(cacheFillClass, cacheFillSelector,
                        (IMP)MTHookedVariantImageForIcon,
                        (IMP *)&MTOriginalVariantImageForIcon);
    }
    if (appearanceCacheFillHookable) {
        MTOriginalAppearanceVariantImageForIcon =
            (MTAppearanceVariantImageForIconFunction)
                appearanceCacheFillImplementation;
        MSHookMessageEx(
            cacheFillClass, appearanceCacheFillSelector,
            (IMP)MTHookedAppearanceVariantImageForIcon,
            (IMP *)&MTOriginalAppearanceVariantImageForIcon);
    }
    MTOriginalIconImageWithInfo =
        (MTIconImageWithInfoFunction)transitionImplementation;
    MSHookMessageEx(identityClass, transitionSelector,
                    (IMP)MTHookedIconImageWithInfo,
                    (IMP *)&MTOriginalIconImageWithInfo);
    if (MTOriginalIconImageWithInfo == NULL ||
        (cacheFillHookable && MTOriginalVariantImageForIcon == NULL) ||
        (appearanceCacheFillHookable &&
         MTOriginalAppearanceVariantImageForIcon == NULL) ||
        (requiresApplicationProducers &&
         (MTOriginalApplicationIconImageWithInfo == NULL ||
          (generatedTransitionHookable &&
           MTOriginalApplicationGeneratedIconImageWithInfo == NULL) ||
          MTOriginalApplicationUnmaskedIconImageWithInfo == NULL ||
          (imageViewDisplayHookable &&
           MTOriginalImageViewDisplay == NULL))) ||
        MTSystemMaskImage == NULL) {
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

static BOOL MTPerformNativeRecache(id recipient,
                                   id subject,
                                   NSString *source,
                                   uint64_t sequence) {
    if (![NSThread isMainThread] || recipient == nil || subject == nil ||
        MTTargetClass == Nil || MTIdentityClass == Nil ||
        MTNativeRecacheSelector == NULL) {
        return NO;
    }
    Class recipientClass = object_getClass(recipient);
    Class subjectClass = object_getClass(subject);
    if (!MTRuntimeClassIsSubclassOfClass(recipientClass, MTTargetClass) ||
        !MTRuntimeClassIsSubclassOfClass(subjectClass, MTIdentityClass)) {
        return NO;
    }
    Method method = class_getInstanceMethod(
        recipientClass, MTNativeRecacheSelector);
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    IMP implementation = method == NULL ? NULL :
        method_getImplementation(method);
    if (encoding == NULL ||
        strcmp(encoding, MTNativeRecacheTypeEncoding) != 0 ||
        !MTSpringBoardHomeImplementationMatchesExpectedImage(
            implementation)) {
        return NO;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        recipient, MTNativeRecacheSelector, subject, nil);
    uint64_t recache = atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.refreshNativeRecaches,
        1, memory_order_relaxed) + 1;
    if (recache == 1 || recache == 16 || recache == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-cache.native-recache", @{
                @"call" : @(recache),
                @"source" : source.length > 0 ? source : @"unknown",
                @"sequence" : @(sequence),
                @"cacheClass" : MTDiagnosticClassName(recipient),
                @"iconClass" : MTDiagnosticClassName(subject),
            });
    }
    return YES;
}

void MTIconImageCacheAdapterArmRefreshSequence(uint64_t sequence) {
    atomic_store_explicit(
        &MTRefreshSequence, sequence, memory_order_release);
}

void MTIconImageCacheAdapterTrackVisibleIcon(id cache, id icon) {
    if (![NSThread isMainThread] || cache == nil || icon == nil ||
        atomic_load_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            memory_order_acquire) != MTIconImageCacheAdapterStateInstalled ||
        MTTargetClass == Nil || MTRefreshTracker == nil) {
        return;
    }
    Class cacheClass = object_getClass(cache);
    if (!MTRuntimeClassIsSubclassOfClass(cacheClass, MTTargetClass)) return;
    NSString *identifier = MTBundleIdentifierForTrackedIcon(icon);
    if (identifier.length == 0) return;
    [MTRefreshTracker recordRecipient:cache
                              subject:icon
                           identifier:identifier];
    uint64_t refreshSequence = atomic_load_explicit(
        &MTRefreshSequence, memory_order_acquire);
    uint64_t record = atomic_fetch_add_explicit(
        &MTRuntimeIconImageCacheAdapterObservation.viewRecipientRecords,
        1, memory_order_relaxed) + 1;
    if (record == 1 || record == 16 || record == 64) {
        MTRuntimeABIReportRecordSample(
            @"springboard.icon-cache.view-recipient", @{
                @"record" : @(record),
                @"cacheClass" : MTDiagnosticClassName(cache),
                @"iconClass" : MTDiagnosticClassName(icon),
                @"bundleIdentifier" : identifier,
                @"refreshSequence" : @(refreshSequence),
            });
    }
    if (MTInstallationMode != MTIconImageCacheAdapterModeSpringBoard ||
        refreshSequence == 0 || MTNativeRecacheSelector == NULL) {
        return;
    }
    NSNumber *lastSequence = objc_getAssociatedObject(
        icon, &MTLateRecacheSequenceAssociationKey);
    if (lastSequence.unsignedLongLongValue == refreshSequence) return;
    objc_setAssociatedObject(
        icon, &MTLateRecacheSequenceAssociationKey, @(refreshSequence),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(
                &MTRefreshSequence, memory_order_acquire) !=
                refreshSequence) {
            return;
        }
        MTPerformNativeRecache(
            cache, icon, @"late-view", refreshSequence);
    });
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
    BOOL hasLegacyRefresh = MTRefreshSelector != NULL &&
        MTRefreshNotificationSelector != NULL;
    BOOL hasNativeRecache = MTNativeRecacheSelector != NULL;
    uint64_t refreshSequence = atomic_load_explicit(
        &MTRefreshSequence, memory_order_acquire);
    if (![NSThread isMainThread] || snapshot == nil ||
        atomic_load_explicit(
            &MTRuntimeIconImageCacheAdapterObservation.state,
            memory_order_acquire) != MTIconImageCacheAdapterStateInstalled ||
        MTTargetClass == Nil || (!hasLegacyRefresh && !hasNativeRecache)) {
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
        if (!MTRuntimeClassIsSubclassOfClass(recipientClass, MTTargetClass) ||
            target.subjects.count == 0) {
            continue;
        }
        if (hasNativeRecache) {
            BOOL performedNativeRecache = NO;
            for (id subject in target.subjects) {
                performedNativeRecache = MTPerformNativeRecache(
                    target.recipient, subject,
                    @"refresh-snapshot", refreshSequence) ||
                    performedNativeRecache;
            }
            if (performedNativeRecache) {
                continue;
            }
        }
        if (!hasLegacyRefresh) continue;
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
        if (refreshTypeEncoding == NULL ||
            strcmp(refreshTypeEncoding, MTRefreshTypeEncoding) != 0 ||
            !MTSpringBoardHomeImplementationMatchesExpectedImage(
                refreshImplementation) ||
            refreshNotificationTypeEncoding == NULL ||
            strcmp(refreshNotificationTypeEncoding,
                   MTRefreshNotificationTypeEncoding) != 0 ||
            !MTSpringBoardHomeImplementationMatchesExpectedImage(
                refreshNotificationImplementation)) {
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
