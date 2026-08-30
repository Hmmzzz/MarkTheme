#import "MTStatusBarSignalImageAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTStatusBarSurfaceABI.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.statusbar-signal-image";

static const char *const MTSignalClassName = "STUIStatusBarSignalView";
static const char *const MTWifiClassName =
    "STUIStatusBarWifiSignalView";
static const char *const MTCellularClassName =
    "STUIStatusBarCellularSignalView";
static const char *const MTUpdateActiveBarsSelectorName =
    "_updateActiveBars";
static const char *const MTActiveBarsGetterName = "numberOfActiveBars";
static const char *const MTActiveColorGetterName = "activeColor";
static const char *const MTVoidGetterTypeEncoding = "v16@0:8";
static const char *const MTIntegerGetterTypeEncoding = "q16@0:8";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";

typedef void (*MTUpdateActiveBarsFunction)(id, SEL);
typedef NSInteger (*MTIntegerGetterFunction)(id, SEL);
typedef id (*MTObjectGetterFunction)(id, SEL);

MTStatusBarSignalImageAdapterObservation
    MTRuntimeStatusBarSignalImageAdapterObservation = {
        .schemaVersion = 3,
        .state = ATOMIC_VAR_INIT(
            MTStatusBarSignalImageAdapterStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .wifiCommitCalls = ATOMIC_VAR_INIT(0),
        .cellularCommitCalls = ATOMIC_VAR_INIT(0),
        .mainThreadCalls = ATOMIC_VAR_INIT(0),
        .resolverCalls = ATOMIC_VAR_INIT(0),
        .appliedResults = ATOMIC_VAR_INIT(0),
        .stockFallbacks = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTStatusBarSignalImageAdapterObservation) == 72,
    "Status Bar native-commit observation ABI changed");

static MTUpdateActiveBarsFunction MTOriginalWifiUpdateActiveBars;
static MTUpdateActiveBarsFunction MTOriginalCellularUpdateActiveBars;
static MTIntegerGetterFunction MTActiveBarsGetter;
static MTObjectGetterFunction MTActiveColorGetter;
static MTStatusBarSignalImageResolver MTImageResolver;
static SEL MTActiveBarsGetterSelector;
static SEL MTActiveColorGetterSelector;

static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName = runtimeClass == Nil ? NULL :
        class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static NSString *MTStatusBarContractName(NSString *kind,
                                         const char *className,
                                         const char *memberName) {
    return [NSString stringWithFormat:@"%@:%s.%s",
        kind, className, memberName];
}

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

static void MTStatusBarApplyNativeCommit(id signalView,
                                         MTStatusBarSignalKind kind) {
    if (![NSThread isMainThread]) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation
                 .contractRejects,
            1, memory_order_relaxed);
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.mainThreadCalls,
        1, memory_order_relaxed);
    if (signalView == nil || MTImageResolver == NULL ||
        MTActiveBarsGetter == NULL || MTActiveColorGetter == NULL) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation
                 .contractRejects,
            1, memory_order_relaxed);
        return;
    }
    NSInteger level = MTActiveBarsGetter(
        signalView, MTActiveBarsGetterSelector);
    id activeColor = MTActiveColorGetter(
        signalView, MTActiveColorGetterSelector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    if (MTImageResolver(signalView, activeColor, kind, level)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation
                 .appliedResults,
            1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSignalImageAdapterObservation
                 .stockFallbacks,
            1, memory_order_relaxed);
    }
}

static void MTHookedWifiUpdateActiveBars(id self, SEL selector) {
    MTOriginalWifiUpdateActiveBars(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.wifiCommitCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyNativeCommit(self, MTStatusBarSignalKindWiFi);
}

static void MTHookedCellularUpdateActiveBars(id self, SEL selector) {
    MTOriginalCellularUpdateActiveBars(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation
             .cellularCommitCalls,
        1, memory_order_relaxed);
    MTStatusBarApplyNativeCommit(self, MTStatusBarSignalKindCellular);
}

static void MTStatusBarRecordMethodContract(
    const char *className,
    const char *selectorName,
    Method method,
    const char *typeEncoding) {
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        MTStatusBarContractName(
            @"encoding", className, selectorName),
        method, typeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID,
        MTStatusBarContractName(
            @"impl", className, selectorName),
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTStatusBarRejectInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.state,
        MTStatusBarSignalImageAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTStatusBarSignalImageAdapterStateRejected,
        @"Rejected");
}

static void MTStatusBarAttemptInstallation(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class signalClass = objc_getClass(MTSignalClassName);
    Class wifiClass = objc_getClass(MTWifiClassName);
    Class cellularClass = objc_getClass(MTCellularClassName);
    SEL updateSelector = sel_registerName(
        MTUpdateActiveBarsSelectorName);
    SEL activeBarsGetterSelector = sel_registerName(
        MTActiveBarsGetterName);
    SEL activeColorGetterSelector = sel_registerName(
        MTActiveColorGetterName);
    Method wifiUpdateMethod = wifiClass == Nil ? NULL :
        class_getInstanceMethod(wifiClass, updateSelector);
    Method cellularUpdateMethod = cellularClass == Nil ? NULL :
        class_getInstanceMethod(cellularClass, updateSelector);
    Method activeBarsGetterMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, activeBarsGetterSelector);
    Method activeColorGetterMethod = signalClass == Nil ? NULL :
        class_getInstanceMethod(signalClass, activeColorGetterSelector);

    const char *classNames[] = {
        MTSignalClassName, MTWifiClassName, MTCellularClassName,
    };
    Class classes[] = { signalClass, wifiClass, cellularClass };
    for (NSUInteger index = 0; index < 3; index++) {
        const char *className = classNames[index];
        Class runtimeClass = classes[index];
        MTRuntimeABIReportProbePresence(
            MTAdapterID,
            [@"class:" stringByAppendingString:@(className)],
            runtimeClass != Nil);
        MTRuntimeABIReportRecordContract(
            MTAdapterID,
            [@"image:" stringByAppendingString:@(className)],
            MTSystemStatusUIStatusBarClassMatchesExpectedImage(
                runtimeClass),
            @"SystemStatusUI", MTReportImageName(runtimeClass));
    }

    Class wifiSuperclass = wifiClass == Nil ? Nil :
        class_getSuperclass(wifiClass);
    Class cellularSuperclass = cellularClass == Nil ? Nil :
        class_getSuperclass(cellularClass);
    MTRuntimeABIReportRecordContract(
        MTAdapterID,
        [@"superclass:" stringByAppendingString:@(MTWifiClassName)],
        MTStatusBarClassIsSubclassOfClass(wifiClass, signalClass),
        [@"inherits " stringByAppendingString:@(MTSignalClassName)],
        wifiSuperclass == Nil ? nil : @(class_getName(wifiSuperclass)));
    MTRuntimeABIReportRecordContract(
        MTAdapterID,
        [@"superclass:" stringByAppendingString:@(MTCellularClassName)],
        MTStatusBarClassIsSubclassOfClass(cellularClass, signalClass),
        [@"inherits " stringByAppendingString:@(MTSignalClassName)],
        cellularSuperclass == Nil ? nil :
            @(class_getName(cellularSuperclass)));

    MTStatusBarRecordMethodContract(
        MTWifiClassName, MTUpdateActiveBarsSelectorName,
        wifiUpdateMethod, MTVoidGetterTypeEncoding);
    MTStatusBarRecordMethodContract(
        MTCellularClassName, MTUpdateActiveBarsSelectorName,
        cellularUpdateMethod, MTVoidGetterTypeEncoding);
    MTStatusBarRecordMethodContract(
        MTSignalClassName, MTActiveBarsGetterName,
        activeBarsGetterMethod, MTIntegerGetterTypeEncoding);
    MTStatusBarRecordMethodContract(
        MTSignalClassName, MTActiveColorGetterName,
        activeColorGetterMethod, MTObjectGetterTypeEncoding);

    BOOL valid = signalClass != Nil && wifiClass != Nil &&
        cellularClass != Nil &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(signalClass) &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(wifiClass) &&
        MTSystemStatusUIStatusBarClassMatchesExpectedImage(
            cellularClass) &&
        MTStatusBarClassIsSubclassOfClass(wifiClass, signalClass) &&
        MTStatusBarClassIsSubclassOfClass(
            cellularClass, signalClass) &&
        MTStatusBarMethodMatches(
            wifiUpdateMethod, MTVoidGetterTypeEncoding) &&
        MTStatusBarMethodMatches(
            cellularUpdateMethod, MTVoidGetterTypeEncoding) &&
        MTStatusBarMethodMatches(
            activeBarsGetterMethod, MTIntegerGetterTypeEncoding) &&
        MTStatusBarMethodMatches(
            activeColorGetterMethod, MTObjectGetterTypeEncoding);
    if (!valid) {
        MTStatusBarRejectInstallation();
        return;
    }

    MTActiveBarsGetterSelector = activeBarsGetterSelector;
    MTActiveColorGetterSelector = activeColorGetterSelector;
    MTActiveBarsGetter = (MTIntegerGetterFunction)
        method_getImplementation(activeBarsGetterMethod);
    MTActiveColorGetter = (MTObjectGetterFunction)
        method_getImplementation(activeColorGetterMethod);

    // These are the two lowest shared visible commit boundaries on the exact
    // iOS 17 SystemStatusUI path. Active-count, color, style, geometry, and
    // signal-mode changes all converge here; callers and display views stay
    // wholly native and unhooked.
    MSHookMessageEx(wifiClass, updateSelector,
        (IMP)MTHookedWifiUpdateActiveBars,
        (IMP *)&MTOriginalWifiUpdateActiveBars);
    MSHookMessageEx(cellularClass, updateSelector,
        (IMP)MTHookedCellularUpdateActiveBars,
        (IMP *)&MTOriginalCellularUpdateActiveBars);
    if (MTOriginalWifiUpdateActiveBars == NULL ||
        MTOriginalCellularUpdateActiveBars == NULL ||
        MTActiveBarsGetter == NULL || MTActiveColorGetter == NULL) {
        MTStatusBarRejectInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.state,
        MTStatusBarSignalImageAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTStatusBarSignalImageAdapterStateInstalled,
        @"Installed");
}

BOOL MTStatusBarSignalImageAdapterSchedule(
    MTStatusBarSignalImageResolver resolver,
    NSError **error) {
    if (error != NULL) *error = nil;
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
    // Runtime bootstrap has already published its immutable snapshot. This
    // synchronous pass inspects only SystemStatusUI class/method metadata and
    // installs two original-first Hooks; it never enters UIKit's view graph.
    MTStatusBarAttemptInstallation();
    return atomic_load_explicit(
        &MTRuntimeStatusBarSignalImageAdapterObservation.state,
        memory_order_acquire) ==
        MTStatusBarSignalImageAdapterStateInstalled;
}
