#import "MTStatusBarSignalImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTStatusBarSurfaceABI.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.statusbar-signal-image";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTSignalClassName = "STUIStatusBarSignalView";
static const char *const MTWifiClassName =
    "STUIStatusBarWifiSignalView";
static const char *const MTCellularClassName =
    "STUIStatusBarCellularSignalView";
static const char *const MTSetActiveSelectorName =
    "setNumberOfActiveBars:";
static const char *const MTApplyStyleSelectorName =
    "applyStyleAttributes:";
static const char *const MTLayoutSelectorName = "layoutSubviews";
static const char *const MTActiveBarsGetterName = "numberOfActiveBars";
static const char *const MTActiveColorGetterName = "activeColor";
static const char *const MTWindowClassName = "UIWindow";
static const char *const MTAllWindowsSelectorName =
    "allWindowsIncludingInternalWindows:onlyVisibleWindows:";
static const char *const MTSubviewsSelectorName = "subviews";
static const char *const MTSetActiveTypeEncoding = "v24@0:8q16";
static const char *const MTApplyStyleTypeEncoding = "v24@0:8@16";
static const char *const MTLayoutTypeEncoding = "v16@0:8";
static const char *const MTIntegerGetterTypeEncoding = "q16@0:8";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";

typedef void (*MTSetActiveFunction)(id, SEL, NSInteger);
typedef void (*MTApplyStyleFunction)(id, SEL, id);
typedef void (*MTLayoutFunction)(id, SEL);
typedef NSInteger (*MTIntegerGetterFunction)(id, SEL);
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef id (*MTAllWindowsFunction)(id, SEL, BOOL, BOOL);

MTStatusBarSignalImageAdapterObservation
    MTRuntimeStatusBarSignalImageAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(
            MTStatusBarSignalImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .setActiveCalls = ATOMIC_VAR_INIT(0),
        .styleCalls = ATOMIC_VAR_INIT(0),
        .wifiLayoutCalls = ATOMIC_VAR_INIT(0),
        .cellularLayoutCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .appliedResults = ATOMIC_VAR_INIT(0),
        .stockRestores = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshExecutions = ATOMIC_VAR_INIT(0),
        .discoveryPasses = ATOMIC_VAR_INIT(0),
        .enumeratedWindows = ATOMIC_VAR_INIT(0),
        .visitedViews = ATOMIC_VAR_INIT(0),
        .discoveredSignalViews = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTStatusBarSignalImageAdapterObservation) == 128,
    "The Status Bar ProcessAdapter observation layout must remain fixed.");

static MTSetActiveFunction MTOriginalSetActive;
static MTApplyStyleFunction MTOriginalApplyStyle;
static MTLayoutFunction MTOriginalWifiLayout;
static MTLayoutFunction MTOriginalCellularLayout;
static MTIntegerGetterFunction MTActiveBarsGetter;
static MTObjectGetterFunction MTActiveColorGetter;
static MTStatusBarSignalImageResolver MTImageResolver;
static Class MTSignalClass;
static Class MTWifiClass;
static Class MTCellularClass;
static SEL MTActiveBarsGetterSelector;
static SEL MTActiveColorGetterSelector;
static NSHashTable *MTSignalViews;
static NSArray *MTLifecycleObserverTokens;

static BOOL MTStatusBarClassIsSubclassOfClass(Class candidate,
                                               Class parent) {
    for (NSUInteger depth = 0;
         candidate != Nil && depth < 64;
         depth++, candidate = class_getSuperclass(candidate)) {
        if (candidate == parent) return YES;
    }
    return NO;
}

static BOOL MTStatusBarMethodMatches(Method method,
                                     const char *typeEncoding) {
    if (method == NULL || typeEncoding == NULL) return NO;
    const char *actual = method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSystemStatusUIStatusBarImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static NSArray *MTStatusBarAllWindows(void) {
    Class windowClass = objc_getClass(MTWindowClassName);
    SEL selector = sel_registerName(MTAllWindowsSelectorName);
    Method method = windowClass == Nil ? NULL :
        class_getClassMethod(windowClass, selector);
    IMP implementation = method == NULL ? NULL :
        method_getImplementation(method);
    if (implementation == NULL ||
        !MTUIKitCoreStatusBarWindowImplementationMatchesExpectedImage(
            implementation)) {
        return @[];
    }
    id windows = ((MTAllWindowsFunction)implementation)(
        windowClass, selector, YES, NO);
    return [windows isKindOfClass:NSArray.class] ? windows : @[];
}

static NSArray *MTStatusBarDiscoverSignalViews(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.discoveryPasses,
        1, memory_order_relaxed);
    NSArray *windows = MTStatusBarAllWindows();
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.enumeratedWindows,
        windows.count, memory_order_relaxed);
    if (windows.count == 0) return @[];
    NSMutableArray *pending = [windows mutableCopy];
    NSMutableArray *signals = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsStrongMemory |
                             NSPointerFunctionsObjectPointerPersonality];
    SEL subviewsSelector = sel_registerName(MTSubviewsSelectorName);
    while (pending.count > 0) {
        id view = pending.lastObject;
        [pending removeLastObject];
        if (view == nil || [visited containsObject:view]) continue;
        [visited addObject:view];
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.visitedViews,
            1, memory_order_relaxed);
        Class runtimeClass = object_getClass(view);
        if (MTStatusBarClassIsSubclassOfClass(runtimeClass, MTWifiClass) ||
            MTStatusBarClassIsSubclassOfClass(
                runtimeClass, MTCellularClass)) {
            [signals addObject:view];
        }
        if (![view respondsToSelector:subviewsSelector]) continue;
        id subviews = ((MTObjectGetterFunction)objc_msgSend)(
            view, subviewsSelector);
        if ([subviews isKindOfClass:NSArray.class]) {
            [pending addObjectsFromArray:subviews];
        }
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation
             .discoveredSignalViews,
        signals.count, memory_order_relaxed);
    return signals;
}

static void MTStatusBarApplyView(id view) {
    if (![NSThread isMainThread] || view == nil ||
        MTImageResolver == NULL || MTActiveBarsGetter == NULL ||
        MTActiveColorGetter == NULL) {
        return;
    }
    Class runtimeClass = object_getClass(view);
    MTStatusBarSignalKind kind;
    if (MTStatusBarClassIsSubclassOfClass(runtimeClass, MTWifiClass)) {
        kind = MTStatusBarSignalKindWiFi;
    } else if (MTStatusBarClassIsSubclassOfClass(
                   runtimeClass, MTCellularClass)) {
        kind = MTStatusBarSignalKindCellular;
    } else {
        return;
    }
    [MTSignalViews addObject:view];
    NSInteger level = MTActiveBarsGetter(view, MTActiveBarsGetterSelector);
    id activeColor = MTActiveColorGetter(view, MTActiveColorGetterSelector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    if (MTImageResolver(view, activeColor, kind, level)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.appliedResults,
            1, memory_order_relaxed);
    } else {
        // The ModuleRuntime returns NO after restoring or retaining stock.
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.stockRestores,
            1, memory_order_relaxed);
    }
}

static void MTHookedSetActive(id self, SEL selector, NSInteger bars) {
    MTOriginalSetActive(self, selector, bars);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.setActiveCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyView(self);
}

static void MTHookedApplyStyle(id self, SEL selector, id attributes) {
    MTOriginalApplyStyle(self, selector, attributes);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.styleCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyView(self);
}

static void MTHookedWifiLayout(id self, SEL selector) {
    MTOriginalWifiLayout(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.wifiLayoutCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyView(self);
}

static void MTHookedCellularLayout(id self, SEL selector) {
    MTOriginalCellularLayout(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation
             .cellularLayoutCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return;
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyView(self);
}

static void MTStatusBarAttemptInstallation(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class signalClass = objc_getClass(MTSignalClassName);
    Class wifiClass = objc_getClass(MTWifiClassName);
    Class cellularClass = objc_getClass(MTCellularClassName);
    SEL setActiveSelector = sel_registerName(MTSetActiveSelectorName);
    SEL applyStyleSelector = sel_registerName(MTApplyStyleSelectorName);
    SEL layoutSelector = sel_registerName(MTLayoutSelectorName);
    SEL activeBarsGetterSelector = sel_registerName(
        MTActiveBarsGetterName);
    SEL activeColorGetterSelector = sel_registerName(
        MTActiveColorGetterName);
    Method setActiveMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, setActiveSelector);
    Method applyStyleMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, applyStyleSelector);
    Method activeBarsGetterMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, activeBarsGetterSelector);
    Method activeColorGetterMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, activeColorGetterSelector);
    Method wifiLayoutMethod = wifiClass == Nil ? NULL :
        class_getInstanceMethod(wifiClass, layoutSelector);
    Method cellularLayoutMethod = cellularClass == Nil ? NULL :
        class_getInstanceMethod(cellularClass, layoutSelector);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:STUIStatusBarSignalView", signalClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:STUIStatusBarWifiSignalView", wifiClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:STUIStatusBarCellularSignalView",
        cellularClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:STUIStatusBarSignalView",
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(signalClass),
        @"SystemStatusUI", MTReportImageName(signalClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:STUIStatusBarWifiSignalView",
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(wifiClass),
        @"SystemStatusUI", MTReportImageName(wifiClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:STUIStatusBarCellularSignalView",
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(cellularClass),
        @"SystemStatusUI", MTReportImageName(cellularClass));
    Class wifiSuperclass = wifiClass == Nil ? Nil :
        class_getSuperclass(wifiClass);
    Class cellularSuperclass = cellularClass == Nil ? Nil :
        class_getSuperclass(cellularClass);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"superclass:STUIStatusBarWifiSignalView",
        MTStatusBarClassIsSubclassOfClass(wifiClass, signalClass),
        @"inherits STUIStatusBarSignalView",
        wifiSuperclass == Nil ? nil : @(class_getName(wifiSuperclass)));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"superclass:STUIStatusBarCellularSignalView",
        MTStatusBarClassIsSubclassOfClass(cellularClass, signalClass),
        @"inherits STUIStatusBarSignalView",
        cellularSuperclass == Nil ? nil :
            @(class_getName(cellularSuperclass)));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:STUIStatusBarSignalView."
                     "setNumberOfActiveBars:",
        setActiveMethod, MTSetActiveTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:STUIStatusBarSignalView."
                     "applyStyleAttributes:",
        applyStyleMethod, MTApplyStyleTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:STUIStatusBarSignalView.numberOfActiveBars",
        activeBarsGetterMethod, MTIntegerGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:STUIStatusBarSignalView.activeColor",
        activeColorGetterMethod, MTObjectGetterTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:STUIStatusBarWifiSignalView.layoutSubviews",
        wifiLayoutMethod, MTLayoutTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:STUIStatusBarCellularSignalView.layoutSubviews",
        cellularLayoutMethod, MTLayoutTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:STUIStatusBarSignalView."
                     "setNumberOfActiveBars:",
        setActiveMethod == NULL ? NULL :
            method_getImplementation(setActiveMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:STUIStatusBarSignalView."
                     "applyStyleAttributes:",
        applyStyleMethod == NULL ? NULL :
            method_getImplementation(applyStyleMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:STUIStatusBarSignalView.numberOfActiveBars",
        activeBarsGetterMethod == NULL ? NULL :
            method_getImplementation(activeBarsGetterMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:STUIStatusBarSignalView.activeColor",
        activeColorGetterMethod == NULL ? NULL :
            method_getImplementation(activeColorGetterMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:STUIStatusBarWifiSignalView.layoutSubviews",
        wifiLayoutMethod == NULL ? NULL :
            method_getImplementation(wifiLayoutMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID,
        @"impl:STUIStatusBarCellularSignalView.layoutSubviews",
        cellularLayoutMethod == NULL ? NULL :
            method_getImplementation(cellularLayoutMethod));
    BOOL valid = signalClass != Nil && wifiClass != Nil &&
        cellularClass != Nil &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(signalClass) &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(wifiClass) &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(cellularClass) &&
        MTStatusBarClassIsSubclassOfClass(wifiClass, signalClass) &&
        MTStatusBarClassIsSubclassOfClass(cellularClass, signalClass) &&
        MTStatusBarMethodMatches(
            setActiveMethod, MTSetActiveTypeEncoding) &&
        MTStatusBarMethodMatches(
            applyStyleMethod, MTApplyStyleTypeEncoding) &&
        MTStatusBarMethodMatches(
            activeBarsGetterMethod, MTIntegerGetterTypeEncoding) &&
        MTStatusBarMethodMatches(
            activeColorGetterMethod, MTObjectGetterTypeEncoding) &&
        MTStatusBarMethodMatches(wifiLayoutMethod, MTLayoutTypeEncoding) &&
        MTStatusBarMethodMatches(
            cellularLayoutMethod, MTLayoutTypeEncoding);
    if (!valid) {
        atomic_store_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.state,
            MTStatusBarSignalImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTStatusBarSignalImageAdapterStateRejected,
            @"Rejected");
        return;
    }
    MTSignalClass = signalClass;
    MTWifiClass = wifiClass;
    MTCellularClass = cellularClass;
    MTActiveBarsGetterSelector = activeBarsGetterSelector;
    MTActiveColorGetterSelector = activeColorGetterSelector;
    MTActiveBarsGetter = (MTIntegerGetterFunction)
        method_getImplementation(activeBarsGetterMethod);
    MTActiveColorGetter = (MTObjectGetterFunction)
        method_getImplementation(activeColorGetterMethod);
    MTSignalViews = [NSHashTable weakObjectsHashTable];
    if (MTSignalViews == nil) {
        atomic_store_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.state,
            MTStatusBarSignalImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTStatusBarSignalImageAdapterStateRejected,
            @"Rejected");
        return;
    }
    MSHookMessageEx(signalClass, setActiveSelector,
        (IMP)MTHookedSetActive, (IMP *)&MTOriginalSetActive);
    MSHookMessageEx(signalClass, applyStyleSelector,
        (IMP)MTHookedApplyStyle, (IMP *)&MTOriginalApplyStyle);
    MSHookMessageEx(wifiClass, layoutSelector,
        (IMP)MTHookedWifiLayout, (IMP *)&MTOriginalWifiLayout);
    MSHookMessageEx(cellularClass, layoutSelector,
        (IMP)MTHookedCellularLayout, (IMP *)&MTOriginalCellularLayout);
    if (MTOriginalSetActive == NULL || MTOriginalApplyStyle == NULL ||
        MTOriginalWifiLayout == NULL || MTOriginalCellularLayout == NULL ||
        MTActiveBarsGetter == NULL || MTActiveColorGetter == NULL) {
        atomic_store_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.state,
            MTStatusBarSignalImageAdapterStateRejected,
            memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTStatusBarSignalImageAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.state,
        MTStatusBarSignalImageAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTStatusBarSignalImageAdapterStateInstalled,
        @"Installed");

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mainQueue = NSOperationQueue.mainQueue;
    void (^refresh)(NSNotification *) = ^(NSNotification *notification) {
        (void)notification;
        MTStatusBarSignalImageAdapterRefresh();
    };
    id didFinish = [center
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:mainQueue
                usingBlock:refresh];
    id didBecomeActive = [center
        addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                    object:nil
                     queue:mainQueue
                usingBlock:refresh];
    MTLifecycleObserverTokens = @[ didFinish, didBecomeActive ];
    dispatch_async(dispatch_get_main_queue(), ^{
        MTStatusBarSignalImageAdapterRefresh();
    });
}

BOOL MTStatusBarSignalImageAdapterSchedule(
    MTStatusBarSignalImageResolver resolver,
    NSError **error) {
    (void)error;
    if (resolver == NULL) return NO;
    uint32_t expected = MTStatusBarSignalImageAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.state,
            &expected, MTStatusBarSignalImageAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTStatusBarSignalImageAdapterStateScheduled ||
            expected == MTStatusBarSignalImageAdapterStateInstalled;
    }
    MTImageResolver = resolver;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTStatusBarSignalImageAdapterStateScheduled,
        @"Scheduled");
    // Register exact SystemStatusUI hooks synchronously. Only class, method,
    // and image metadata is inspected; live view discovery stays on a later
    // main-thread UIKit boundary.
    MTStatusBarAttemptInstallation();
    return atomic_load_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.state,
        memory_order_acquire) ==
        MTStatusBarSignalImageAdapterStateInstalled;
}

void MTStatusBarSignalImageAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MTStatusBarSignalImageAdapterRefresh();
        });
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation.state,
            memory_order_acquire) !=
            MTStatusBarSignalImageAdapterStateInstalled) {
        return;
    }
    for (id view in MTStatusBarDiscoverSignalViews()) {
        [MTSignalViews addObject:view];
    }
    NSArray *views = MTSignalViews.allObjects;
    for (id view in views) {
        Class runtimeClass = object_getClass(view);
        if (!MTStatusBarClassIsSubclassOfClass(runtimeClass, MTWifiClass) &&
            !MTStatusBarClassIsSubclassOfClass(
                runtimeClass, MTCellularClass)) {
            continue;
        }
        MTStatusBarApplyView(view);
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation
                 .refreshExecutions,
            1, memory_order_relaxed);
    }
}
