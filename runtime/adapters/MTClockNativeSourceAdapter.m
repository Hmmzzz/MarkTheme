#import "MTClockNativeSourceAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <math.h>
#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"
#import "MTClockIconsModule.h"
#import "modules/MTClockIconSnapshotModule.h"

static NSString *const MTClockNativeSourceAdapterID =
    @"springboard-home.clock-icon-sources";
static const char *const MTClockClassName =
    "SBHClockApplicationIconImageView";
static const char *const MTClockHandsClassName = "SBHClockHandsImageSet";
static const char *const MTClockFaceSourceSelectorName =
    "iconImageWithImageInfo:includingMask:";
static const char *const MTClockHandsSourceSelectorName =
    "makeImageSetForMetrics:";
static const char *const MTClockFaceSourceTypeEncoding =
    "@52@0:8{SBIconImageInfo={CGSize=dd}dd}16B48";
static const char *const MTClockHandsSourceTypeEncoding =
    "@24@0:8r^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
    "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16";

typedef struct MTClockIconImageInfo {
    CGSize size;
    CGFloat scale;
    CGFloat continuousCornerRadius;
} MTClockIconImageInfo;

typedef id (*MTClockFaceSourceFunction)(
    id, SEL, MTClockIconImageInfo, BOOL);
typedef id (*MTClockHandsSourceFunction)(id, SEL, const void *);

MTClockNativeSourceAdapterObservation
    MTRuntimeClockNativeSourceAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTClockNativeSourceAdapterStateDormant),
        .faceSourceCalls = ATOMIC_VAR_INIT(0),
        .maskedFaceCalls = ATOMIC_VAR_INIT(0),
        .unmaskedFaceCalls = ATOMIC_VAR_INIT(0),
        .themedFaces = ATOMIC_VAR_INIT(0),
        .handSourceCalls = ATOMIC_VAR_INIT(0),
        .themedHandSets = ATOMIC_VAR_INIT(0),
        .originalFailures = ATOMIC_VAR_INIT(0),
        .resolverMisses = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTClockNativeSourceAdapterObservation) == 80,
    "Clock native-source observation ABI changed");

static MTClockFaceSourceFunction MTOriginalClockFaceSource;
static MTClockHandsSourceFunction MTOriginalClockHandsSource;
static MTClockNativeFaceResolver MTClockFaceResolver;
static BOOL (*MTClockSourcePreparation)(void);
static Class MTClockHandsClass = Nil;
static _Atomic(bool) MTClockInstallPassScheduled = false;

static BOOL MTClockImageInfoIsSupported(MTClockIconImageInfo info) {
    return isfinite(info.size.width) && isfinite(info.size.height) &&
        isfinite(info.scale) && isfinite(info.continuousCornerRadius) &&
        info.size.width == info.size.height &&
        info.size.width >= 1 && info.size.width <= 400 &&
        info.scale >= 1 && info.scale <= 3 &&
        floor(info.scale) == info.scale &&
        info.continuousCornerRadius >= 0 &&
        info.continuousCornerRadius <= info.size.width;
}

static BOOL MTClockMethodMatches(Method method,
                                 const char *typeEncoding) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static id MTHookedClockFaceSource(id self,
                                  SEL selector,
                                  MTClockIconImageInfo info,
                                  BOOL includingMask) {
    id original = MTOriginalClockFaceSource(
        self, selector, info, includingMask);
    atomic_fetch_add_explicit(
        &MTRuntimeClockNativeSourceAdapterObservation.faceSourceCalls,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        includingMask
            ? &MTRuntimeClockNativeSourceAdapterObservation.maskedFaceCalls
            : &MTRuntimeClockNativeSourceAdapterObservation.unmaskedFaceCalls,
        1, memory_order_relaxed);
    if (original == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.originalFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (!MTClockImageInfoIsSupported(info)) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return original;
    }
    id replacement = MTClockFaceResolver(
        MTClockIconTargetBundleIdentifier, info.size, info.scale,
        includingMask, original);
    if (replacement == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return original;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeClockNativeSourceAdapterObservation.themedFaces,
        1, memory_order_relaxed);
    return replacement;
}

static id MTClockImageSetComponent(id imageSet, const char *getter) {
    return ((id (*)(id, SEL))objc_msgSend)(
        imageSet, sel_registerName(getter));
}

static id MTHookedClockHandsSource(id self,
                                   SEL selector,
                                   const void *metrics) {
    id original = MTOriginalClockHandsSource(self, selector, metrics);
    atomic_fetch_add_explicit(
        &MTRuntimeClockNativeSourceAdapterObservation.handSourceCalls,
        1, memory_order_relaxed);
    if (original == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.originalFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (metrics == NULL || object_getClass(original) != MTClockHandsClass) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return original;
    }
    MTClockIconImageSet *theme =
        MTClockIconSnapshotImageSetMatchingNativeComponents(
            MTClockImageSetComponent(original, "hours"),
            MTClockImageSetComponent(original, "minutes"),
            MTClockImageSetComponent(original, "seconds"),
            MTClockImageSetComponent(original, "hourMinuteDot"),
            MTClockImageSetComponent(original, "secondDot"));
    if (theme == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return original;
    }
    struct {
        const char *setter;
        id replacement;
    } components[] = {
        {"setHours:", theme.hourHand},
        {"setMinutes:", theme.minuteHand},
        {"setSeconds:", theme.secondHand},
        {"setHourMinuteDot:", theme.hourMinuteDot},
        {"setSecondDot:", theme.secondDot},
    };
    BOOL replaced = NO;
    for (NSUInteger index = 0;
         index < sizeof(components) / sizeof(components[0]); index++) {
        if (components[index].replacement == nil) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(
            original, sel_registerName(components[index].setter),
            components[index].replacement);
        replaced = YES;
    }
    if (replaced) {
        atomic_fetch_add_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.themedHandSets,
            1, memory_order_relaxed);
    }
    return original;
}

static void MTAttemptClockSourceInstallation(void);

static void MTScheduleClockInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTClockNativeSourceAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTClockInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(
            &MTClockInstallPassScheduled, false, memory_order_release);
        MTAttemptClockSourceInstallation();
    });
}

static void MTClockRuntimeImageAdded(const struct mach_header *header,
                                     intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleClockInstallPass();
}

static void MTRejectClockSourceInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeClockNativeSourceAdapterObservation.state,
        MTClockNativeSourceAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTClockNativeSourceAdapterID,
        MTClockNativeSourceAdapterStateRejected, @"Rejected");
}

static void MTRecordClockComponentContract(Class imageSetClass,
                                           const char *selectorName,
                                           const char *typeEncoding) {
    Method method = class_getInstanceMethod(
        imageSetClass, sel_registerName(selectorName));
    NSString *contract = [@"encoding:SBHClockHandsImageSet."
        stringByAppendingString:@(selectorName)];
    MTRuntimeABIReportProbeMethodType(
        MTClockNativeSourceAdapterID, contract, method, typeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTClockNativeSourceAdapterID,
        [@"implementation:SBHClockHandsImageSet."
            stringByAppendingString:@(selectorName)],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTAttemptClockSourceInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleClockInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTClockNativeSourceAdapterStateScheduled) {
        return;
    }
    Class clockClass = objc_getClass(MTClockClassName);
    Class imageSetClass = objc_getClass(MTClockHandsClassName);
    if (clockClass == Nil || imageSetClass == Nil) return;

    SEL faceSelector = sel_registerName(MTClockFaceSourceSelectorName);
    SEL handsSelector = sel_registerName(MTClockHandsSourceSelectorName);
    Method faceMethod = class_getClassMethod(clockClass, faceSelector);
    Method handsMethod = class_getClassMethod(clockClass, handsSelector);
    MTRuntimeABIReportProbePresence(
        MTClockNativeSourceAdapterID,
        @"class:SBHClockApplicationIconImageView", YES);
    MTRuntimeABIReportProbePresence(
        MTClockNativeSourceAdapterID,
        @"class:SBHClockHandsImageSet", YES);
    MTRuntimeABIReportRecordContract(
        MTClockNativeSourceAdapterID,
        @"image:SBHClockApplicationIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(clockClass),
        @"SpringBoardHome",
        class_getImageName(clockClass) == NULL
            ? nil : @(class_getImageName(clockClass)));
    MTRuntimeABIReportRecordContract(
        MTClockNativeSourceAdapterID,
        @"image:SBHClockHandsImageSet",
        MTSpringBoardHomeClassMatchesExpectedImage(imageSetClass),
        @"SpringBoardHome",
        class_getImageName(imageSetClass) == NULL
            ? nil : @(class_getImageName(imageSetClass)));
    MTRuntimeABIReportProbeMethodType(
        MTClockNativeSourceAdapterID,
        @"encoding:SBHClockApplicationIconImageView."
         "iconImageWithImageInfo:includingMask:",
        faceMethod, MTClockFaceSourceTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTClockNativeSourceAdapterID,
        @"encoding:SBHClockApplicationIconImageView."
         "makeImageSetForMetrics:",
        handsMethod, MTClockHandsSourceTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTClockNativeSourceAdapterID,
        @"implementation:SBHClockApplicationIconImageView.faceSource",
        faceMethod == NULL ? NULL : method_getImplementation(faceMethod));
    MTRuntimeABIReportProbeImplementation(
        MTClockNativeSourceAdapterID,
        @"implementation:SBHClockApplicationIconImageView.handsSource",
        handsMethod == NULL ? NULL : method_getImplementation(handsMethod));

    static const char *const getters[] = {
        "hours", "minutes", "seconds", "hourMinuteDot", "secondDot",
    };
    static const char *const setters[] = {
        "setHours:", "setMinutes:", "setSeconds:",
        "setHourMinuteDot:", "setSecondDot:",
    };
    BOOL valid =
        MTSpringBoardHomeClassMatchesExpectedImage(clockClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(imageSetClass) &&
        MTClockMethodMatches(faceMethod, MTClockFaceSourceTypeEncoding) &&
        MTClockMethodMatches(handsMethod, MTClockHandsSourceTypeEncoding);
    for (NSUInteger index = 0;
         index < sizeof(getters) / sizeof(getters[0]); index++) {
        MTRecordClockComponentContract(
            imageSetClass, getters[index], "@16@0:8");
        MTRecordClockComponentContract(
            imageSetClass, setters[index], "v24@0:8@16");
        valid = valid && MTClockMethodMatches(
            class_getInstanceMethod(
                imageSetClass, sel_registerName(getters[index])),
            "@16@0:8") &&
            MTClockMethodMatches(
                class_getInstanceMethod(
                    imageSetClass, sel_registerName(setters[index])),
                "v24@0:8@16");
    }
    if (!valid || !MTClockSourcePreparation()) {
        MTRejectClockSourceInstallation();
        return;
    }

    MTClockHandsClass = imageSetClass;
    MTOriginalClockFaceSource = (MTClockFaceSourceFunction)
        method_getImplementation(faceMethod);
    MTOriginalClockHandsSource = (MTClockHandsSourceFunction)
        method_getImplementation(handsMethod);
    Class clockMetaClass = object_getClass(clockClass);
    MSHookMessageEx(
        clockMetaClass, faceSelector, (IMP)MTHookedClockFaceSource,
        (IMP *)&MTOriginalClockFaceSource);
    MSHookMessageEx(
        clockMetaClass, handsSelector, (IMP)MTHookedClockHandsSource,
        (IMP *)&MTOriginalClockHandsSource);
    if (MTOriginalClockFaceSource == NULL ||
        MTOriginalClockHandsSource == NULL) {
        MTRejectClockSourceInstallation();
        return;
    }
    atomic_store_explicit(
        &MTRuntimeClockNativeSourceAdapterObservation.state,
        MTClockNativeSourceAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTClockNativeSourceAdapterID,
        MTClockNativeSourceAdapterStateInstalled, @"Installed");
}

BOOL MTClockNativeSourceAdapterSchedule(
    MTClockNativeFaceResolver faceResolver,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (faceResolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTClockNativeSourceAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeClockNativeSourceAdapterObservation.state,
            &expected, MTClockNativeSourceAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTClockNativeSourceAdapterStateScheduled ||
            expected == MTClockNativeSourceAdapterStateInstalled;
    }
    MTClockFaceResolver = faceResolver;
    MTClockSourcePreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTClockNativeSourceAdapterID,
        MTClockNativeSourceAdapterStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTClockRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptClockSourceInstallation();
    } else {
        MTScheduleClockInstallPass();
    }
    return YES;
}
