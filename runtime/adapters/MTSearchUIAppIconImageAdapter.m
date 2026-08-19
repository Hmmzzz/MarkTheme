#import "MTSearchUIAppIconImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTRuntimeWeakObjectMapSnapshot.h"
#import "MTSearchUIABI.h"

#include <stdbool.h>
#include <string.h>

static const char *const MTAppIconClassName = "SearchUIAppIconImage";
static const char *const MTCalendarIconClassName =
    "SearchUICalendarIconImage";
static const char *const MTLoadSelectorName =
    "loadImageWithScale:isDarkStyle:";
static const char *const MTLoadTypeEncoding = "@28@0:8d16B24";
static const char *const MTBundleIdentifierSelectorName =
    "bundleIdentifier";
static const char *const MTBundleIdentifierTypeEncoding = "@16@0:8";
static const char *const MTSizeSelectorName = "size";
static const char *const MTSizeTypeEncoding = "{CGSize=dd}16@0:8";
static const char *const MTInvalidateSelectorName = "invalidateAppIcon";
static const char *const MTInvalidateTypeEncoding = "v16@0:8";
static const char *const MTHomeScreenIconViewClassName =
    "SearchUIHomeScreenAppIconView";
static const char *const MTHomeScreenUpdateSelectorName =
    "updateWithRowModel:";
static const char *const MTHomeScreenUpdateTypeEncoding = "v24@0:8@16";
static NSString *const MTCalendarBundleIdentifier = @"com.apple.mobilecal";

typedef id (*MTSearchUILoadFunction)(id, SEL, CGFloat, BOOL);
typedef id (*MTSearchUIBundleIdentifierFunction)(id, SEL);
typedef CGSize (*MTSearchUISizeFunction)(id, SEL);
typedef void (*MTSearchUIHomeScreenUpdateFunction)(id, SEL, id);

MTSearchUIAppIconImageAdapterObservation
    MTRuntimeSearchUIAppIconImageAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(
            MTSearchUIAppIconImageAdapterStateDormant),
        .genericCalls = ATOMIC_VAR_INIT(0),
        .calendarCalls = ATOMIC_VAR_INIT(0),
        .nilOriginalResults = ATOMIC_VAR_INIT(0),
        .identityResults = ATOMIC_VAR_INIT(0),
        .replacementResults = ATOMIC_VAR_INIT(0),
        .trackedImages = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshInvalidations = ATOMIC_VAR_INIT(0),
        .homeScreenUpdates = ATOMIC_VAR_INIT(0),
        .lateCacheInstallTriggers = ATOMIC_VAR_INIT(0),
        .homeScreenHookInstallations = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTSearchUIAppIconImageAdapterObservation) == 96,
    "The SearchUI ProcessAdapter observation layout must remain fixed.");

static MTSearchUILoadFunction MTOriginalAppIconLoad;
static MTSearchUILoadFunction MTOriginalCalendarIconLoad;
static MTSearchUIHomeScreenUpdateFunction MTOriginalHomeScreenUpdate;
static MTSearchUIBundleIdentifierFunction MTBundleIdentifier;
static MTSearchUISizeFunction MTImageSize;
static MTSystemIconSurfaceResolver MTReplacementResolver;
static NSLock *MTTrackedImagesLock;
static NSMapTable *MTTrackedImages;
static Class MTAppIconClass;
static Class MTCalendarIconClass;
static SEL MTBundleIdentifierSelector;
static SEL MTSizeSelector;
static SEL MTInvalidateSelector;
static MTLateIconCacheInstaller MTLateCacheInstaller;
static _Atomic(bool) MTHomeScreenHookInstalled = false;
static _Atomic(bool) MTHomeScreenHookRejected = false;
static _Atomic(bool) MTHomeScreenHookPassScheduled = false;

static void MTSearchUITryInstallHomeScreenHook(void);

static void MTSearchUIScheduleHomeScreenHookPass(void) {
    if (atomic_load_explicit(
            &MTHomeScreenHookInstalled, memory_order_acquire) ||
        atomic_load_explicit(
            &MTHomeScreenHookRejected, memory_order_acquire)) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTHomeScreenHookPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTHomeScreenHookPassScheduled, false, memory_order_release);
        MTSearchUITryInstallHomeScreenHook();
    });
}

static void MTSearchUIRuntimeImageAdded(const struct mach_header *header,
                                        intptr_t slide) {
    (void)header;
    (void)slide;
    MTSearchUIScheduleHomeScreenHookPass();
}

static void MTSetState(MTSearchUIAppIconImageAdapterState state) {
    atomic_store_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.state,
        (uint32_t)state, memory_order_release);
}

static void MTTrackImage(id image, NSString *bundleIdentifier) {
    if (image == nil || bundleIdentifier.length == 0) return;
    [MTTrackedImagesLock lock];
    [MTTrackedImages setObject:bundleIdentifier forKey:image];
    [MTTrackedImagesLock unlock];
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.trackedImages,
        1, memory_order_relaxed);
}

static id MTResolveSearchUIImage(id self,
                                 SEL selector,
                                 CGFloat scale,
                                 BOOL darkStyle,
                                 MTSearchUILoadFunction original,
                                 BOOL calendar) {
    id originalResult = original(self, selector, scale, darkStyle);
    atomic_fetch_add_explicit(
        calendar
            ? &MTRuntimeSearchUIAppIconImageAdapterObservation.calendarCalls
            : &MTRuntimeSearchUIAppIconImageAdapterObservation.genericCalls,
        1, memory_order_relaxed);
    if (originalResult == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeSearchUIAppIconImageAdapterObservation
                .nilOriginalResults,
            1, memory_order_relaxed);
    }
    id rawIdentifier = MTBundleIdentifier(
        self, MTBundleIdentifierSelector);
    NSString *bundleIdentifier =
        [rawIdentifier isKindOfClass:NSString.class]
            ? (NSString *)rawIdentifier : nil;
    if (bundleIdentifier.length == 0 && calendar) {
        bundleIdentifier = MTCalendarBundleIdentifier;
    }
    if (bundleIdentifier.length == 0) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.identityResults,
        1, memory_order_relaxed);
    MTTrackImage(self, bundleIdentifier);
    CGSize pointSize = MTImageSize(self, MTSizeSelector);
    id replacement = MTReplacementResolver(
        bundleIdentifier, pointSize, scale, originalResult);
    if (replacement == nil) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.replacementResults,
        1, memory_order_relaxed);
    return replacement;
}

static id MTHookedAppIconLoad(id self,
                              SEL selector,
                              CGFloat scale,
                              BOOL darkStyle) {
    return MTResolveSearchUIImage(
        self, selector, scale, darkStyle, MTOriginalAppIconLoad, NO);
}

static id MTHookedCalendarIconLoad(id self,
                                   SEL selector,
                                   CGFloat scale,
                                   BOOL darkStyle) {
    return MTResolveSearchUIImage(
        self, selector, scale, darkStyle, MTOriginalCalendarIconLoad, YES);
}

static void MTHookedHomeScreenUpdate(id self, SEL selector, id rowModel) {
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.homeScreenUpdates,
        1, memory_order_relaxed);
    MTLateIconCacheInstaller installer = MTLateCacheInstaller;
    if (installer != NULL) {
        atomic_fetch_add_explicit(
            &MTRuntimeSearchUIAppIconImageAdapterObservation
                .lateCacheInstallTriggers,
            1, memory_order_relaxed);
        // This exact SearchUI lifecycle boundary runs after its
        // SpringBoardHome superclass is usable. Install the cache producer
        // before Apple's update asks for the first Siri suggestion image.
        installer();
    }
    MTOriginalHomeScreenUpdate(self, selector, rowModel);
}

static BOOL MTMethodMatches(Method method,
                            const char *typeEncoding) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0;
}

static void MTSearchUITryInstallHomeScreenHook(void) {
    if (![NSThread isMainThread]) {
        MTSearchUIScheduleHomeScreenHookPass();
        return;
    }
    if (atomic_load_explicit(
            &MTHomeScreenHookInstalled, memory_order_acquire) ||
        atomic_load_explicit(
            &MTHomeScreenHookRejected, memory_order_acquire)) {
        return;
    }
    Class iconViewClass = objc_getClass(MTHomeScreenIconViewClassName);
    if (iconViewClass == Nil) return;
    SEL updateSelector = sel_registerName(MTHomeScreenUpdateSelectorName);
    Method updateMethod = class_getInstanceMethod(
        iconViewClass, updateSelector);
    if (updateMethod == NULL ||
        !MTSearchUIClassMatchesExpectedImage(iconViewClass) ||
        !MTMethodMatches(updateMethod, MTHomeScreenUpdateTypeEncoding) ||
        !MTSearchUIImplementationMatchesExpectedImage(
            method_getImplementation(updateMethod))) {
        atomic_store_explicit(
            &MTHomeScreenHookRejected, true, memory_order_release);
        return;
    }
    MTOriginalHomeScreenUpdate = (MTSearchUIHomeScreenUpdateFunction)
        method_getImplementation(updateMethod);
    MSHookMessageEx(iconViewClass, updateSelector,
                    (IMP)MTHookedHomeScreenUpdate,
                    (IMP *)&MTOriginalHomeScreenUpdate);
    if (MTOriginalHomeScreenUpdate == NULL) {
        atomic_store_explicit(
            &MTHomeScreenHookRejected, true, memory_order_release);
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation
            .homeScreenHookInstallations,
        1, memory_order_relaxed);
    atomic_store_explicit(
        &MTHomeScreenHookInstalled, true, memory_order_release);
}

BOOL MTSearchUIAppIconImageAdapterInstall(
    MTSystemIconSurfaceResolver resolver,
    BOOL (*preparation)(void),
    MTLateIconCacheInstaller lateIconCacheInstaller,
    NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL ||
        lateIconCacheInstaller == NULL) {
        return NO;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)MTSearchUIAppIconImageAdapterInstall(
                resolver, preparation, lateIconCacheInstaller, NULL);
        });
        return YES;
    }
    uint32_t expected = MTSearchUIAppIconImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeSearchUIAppIconImageAdapterObservation.state,
            &expected,
            MTSearchUIAppIconImageAdapterStateInstalling,
            memory_order_acq_rel,
            memory_order_acquire)) {
        return expected == MTSearchUIAppIconImageAdapterStateInstalling ||
            expected == MTSearchUIAppIconImageAdapterStateInstalled;
    }

    Class appIconClass = objc_getClass(MTAppIconClassName);
    Class calendarIconClass = objc_getClass(MTCalendarIconClassName);
    SEL loadSelector = sel_registerName(MTLoadSelectorName);
    SEL bundleIdentifierSelector =
        sel_registerName(MTBundleIdentifierSelectorName);
    SEL sizeSelector = sel_registerName(MTSizeSelectorName);
    SEL invalidateSelector = sel_registerName(MTInvalidateSelectorName);
    Method appLoad = appIconClass == Nil ? NULL :
        class_getInstanceMethod(appIconClass, loadSelector);
    Method calendarLoad = calendarIconClass == Nil ? NULL :
        class_getInstanceMethod(calendarIconClass, loadSelector);
    Method bundleIdentifierMethod = appIconClass == Nil ? NULL :
        class_getInstanceMethod(appIconClass, bundleIdentifierSelector);
    Method sizeMethod = appIconClass == Nil ? NULL :
        class_getInstanceMethod(appIconClass, sizeSelector);
    Method appInvalidate = appIconClass == Nil ? NULL :
        class_getInstanceMethod(appIconClass, invalidateSelector);
    Method calendarInvalidate = calendarIconClass == Nil ? NULL :
        class_getInstanceMethod(calendarIconClass, invalidateSelector);
    if (appLoad == NULL || calendarLoad == NULL ||
        bundleIdentifierMethod == NULL || sizeMethod == NULL ||
        appInvalidate == NULL || calendarInvalidate == NULL) {
        MTSetState(MTSearchUIAppIconImageAdapterStateClassUnavailable);
        return NO;
    }
    if (!MTSearchUIClassMatchesExpectedImage(appIconClass) ||
        !MTSearchUIClassMatchesExpectedImage(calendarIconClass)) {
        MTSetState(MTSearchUIAppIconImageAdapterStateClassImageMismatch);
        return NO;
    }
    if (!MTMethodMatches(appLoad, MTLoadTypeEncoding) ||
        !MTMethodMatches(calendarLoad, MTLoadTypeEncoding) ||
        !MTMethodMatches(bundleIdentifierMethod,
                         MTBundleIdentifierTypeEncoding) ||
        !MTMethodMatches(sizeMethod, MTSizeTypeEncoding) ||
        !MTMethodMatches(appInvalidate, MTInvalidateTypeEncoding) ||
        !MTMethodMatches(calendarInvalidate, MTInvalidateTypeEncoding)) {
        MTSetState(MTSearchUIAppIconImageAdapterStateMethodTypeMismatch);
        return NO;
    }
    Method methods[] = {
        appLoad, calendarLoad, bundleIdentifierMethod, sizeMethod,
        appInvalidate, calendarInvalidate,
    };
    for (NSUInteger index = 0;
         index < sizeof(methods) / sizeof(methods[0]); index++) {
        if (!MTSearchUIImplementationMatchesExpectedImage(
                method_getImplementation(methods[index]))) {
            MTSetState(
                MTSearchUIAppIconImageAdapterStateImplementationImageMismatch);
            return NO;
        }
    }
    if (!preparation()) {
        MTSetState(
            MTSearchUIAppIconImageAdapterStateResolverPreparationFailed);
        return NO;
    }

    NSLock *lock = [[NSLock alloc] init];
    NSMapTable *trackedImages = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (lock == nil || trackedImages == nil) {
        MTSetState(MTSearchUIAppIconImageAdapterStateOriginalUnavailable);
        return NO;
    }
    MTAppIconClass = appIconClass;
    MTCalendarIconClass = calendarIconClass;
    MTBundleIdentifierSelector = bundleIdentifierSelector;
    MTSizeSelector = sizeSelector;
    MTInvalidateSelector = invalidateSelector;
    MTBundleIdentifier = (MTSearchUIBundleIdentifierFunction)
        method_getImplementation(bundleIdentifierMethod);
    MTImageSize =
        (MTSearchUISizeFunction)method_getImplementation(sizeMethod);
    MTReplacementResolver = resolver;
    MTLateCacheInstaller = lateIconCacheInstaller;
    MTTrackedImagesLock = lock;
    MTTrackedImages = trackedImages;
    MTOriginalAppIconLoad =
        (MTSearchUILoadFunction)method_getImplementation(appLoad);
    MTOriginalCalendarIconLoad =
        (MTSearchUILoadFunction)method_getImplementation(calendarLoad);
    MSHookMessageEx(appIconClass, loadSelector,
                    (IMP)MTHookedAppIconLoad,
                    (IMP *)&MTOriginalAppIconLoad);
    MSHookMessageEx(calendarIconClass, loadSelector,
                    (IMP)MTHookedCalendarIconLoad,
                    (IMP *)&MTOriginalCalendarIconLoad);
    if (MTOriginalAppIconLoad == NULL ||
        MTOriginalCalendarIconLoad == NULL) {
        MTSetState(MTSearchUIAppIconImageAdapterStateOriginalUnavailable);
        return NO;
    }
    _dyld_register_func_for_add_image(MTSearchUIRuntimeImageAdded);
    MTSearchUITryInstallHomeScreenHook();
    MTSetState(MTSearchUIAppIconImageAdapterStateInstalled);
    return YES;
}

void MTSearchUIAppIconImageAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUIAppIconImageAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeSearchUIAppIconImageAdapterObservation.state,
            memory_order_acquire) !=
            MTSearchUIAppIconImageAdapterStateInstalled ||
        MTTrackedImagesLock == nil || MTTrackedImages == nil) {
        return;
    }
    [MTTrackedImagesLock lock];
    NSArray<NSArray *> *pairs =
        MTRuntimeWeakObjectMapSnapshot(MTTrackedImages);
    [MTTrackedImagesLock unlock];
    for (NSArray *pair in pairs) {
        id image = pair.firstObject;
        Class imageClass = image == nil ? Nil : object_getClass(image);
        if (imageClass == Nil ||
            !([image isKindOfClass:MTAppIconClass] ||
              [image isKindOfClass:MTCalendarIconClass])) {
            continue;
        }
        Method method = class_getInstanceMethod(
            imageClass, MTInvalidateSelector);
        if (!MTMethodMatches(method, MTInvalidateTypeEncoding) ||
            !MTSearchUIImplementationMatchesExpectedImage(
                method_getImplementation(method))) {
            continue;
        }
        ((void (*)(id, SEL))objc_msgSend)(
            image, MTInvalidateSelector);
        atomic_fetch_add_explicit(
            &MTRuntimeSearchUIAppIconImageAdapterObservation
                .refreshInvalidations,
            1, memory_order_relaxed);
    }
}
