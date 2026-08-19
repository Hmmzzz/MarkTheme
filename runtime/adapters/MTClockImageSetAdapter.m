#import "MTClockImageSetAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"
#import "MTIconImageCacheAdapter.h"
#import "MTClockIconsModule.h"
#import "modules/MTClockIconSnapshotModule.h"

#include <string.h>

static NSString *const MTAdapterID = @"springboard.clock-image-set";

// Converts one runtime class image name into a report value; an absent image
// stays nil so a missing image is distinguishable from an unexpected one.
static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName =
        runtimeClass == Nil ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static const char *const MTClockClassName =
    "SBHClockApplicationIconImageView";
static const char *const MTClockImageSetSelectorName =
    "imageSetForMetrics:";
static const char *const MTClockContentsSelectorName = "contentsImage";
static const char *const MTClockSquareContentsSelectorName =
    "squareContentsImage";
static const char *const MTClockFaceOutletTypeEncoding = "@16@0:8";
static const char *const MTClockApplyMetricsSelectorName = "applyMetrics:";
static const char *const MTClockApplyMetricsTypeEncoding =
    "v24@0:8r^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
    "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16";
static const char *const MTClockGetMetricsSelectorName = "getMetrics:";
static const char *const MTClockGetMetricsTypeEncoding =
    "v24@0:8^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
    "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16";
static const char *const MTClockImageSetTypeEncoding =
    "@24@0:8r^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
    "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16";
static const char *const MTClockSetNeedsLayoutSelectorName = "setNeedsLayout";
static const char *const MTClockLayoutIfNeededSelectorName = "layoutIfNeeded";
static const char *const MTClockViewUpdateSelectorName =
    "updateImageAnimated:";
static const char *const MTClockLayoutSelectorTypeEncoding = "v16@0:8";
static const char *const MTClockViewUpdateTypeEncoding = "v20@0:8B16";
static const char *const MTClockImageSetClassName = "SBHClockHandsImageSet";
static const uint32_t MTMaximumInstallAttempts = 80;
static const int64_t MTInstallRetryNanoseconds = 250 * NSEC_PER_MSEC;

typedef id (*MTClockMakeImageSetFunction)(id, SEL, const void *);
typedef id (*MTClockImageOutletFunction)(id, SEL);
typedef void (*MTClockApplyMetricsFunction)(id, SEL, const void *);

MTClockImageSetAdapterObservation MTRuntimeClockImageSetAdapterObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTClockImageSetAdapterStateDormant),
    .imageSetCalls = ATOMIC_VAR_INIT(0),
    .themedImageSets = ATOMIC_VAR_INIT(0),
    .backgroundCalls = ATOMIC_VAR_INIT(0),
    .themedBackgrounds = ATOMIC_VAR_INIT(0),
    .refreshRequests = ATOMIC_VAR_INIT(0),
    .refreshExecutions = ATOMIC_VAR_INIT(0),
};

static MTClockMakeImageSetFunction MTOriginalMakeImageSet;
static MTClockImageOutletFunction MTOriginalContentsImage;
static MTClockImageOutletFunction MTOriginalSquareContentsImage;
static MTClockApplyMetricsFunction MTOriginalApplyMetrics;
static NSHashTable *MTClockViews;
static NSMapTable *MTClockAppliedGenerationTokens;
static Class MTClockViewClass = Nil;
static SEL MTClockSetNeedsLayoutSelector;
static SEL MTClockLayoutIfNeededSelector;
static SEL MTClockViewUpdateSelector;

static id MTClockCurrentGenerationToken(void) {
    return MTClockIconSnapshotCurrentImageSet().generationIdentifier ?:
        NSNull.null;
}

static BOOL MTClockViewMatchesCurrentGeneration(id view) {
    id applied = [MTClockAppliedGenerationTokens objectForKey:view];
    return applied != nil && [applied isEqual:MTClockCurrentGenerationToken()];
}

static void MTClockTrackView(id view) {
    if ([MTClockViews containsObject:view]) return;
    [MTClockViews addObject:view];
    // Existing Clock views can finish their initial metrics pass before the
    // adapter is installed. Refresh once after this outlet returns so the
    // ready hand set is applied without recursing through contentsImage.
    dispatch_async(dispatch_get_main_queue(), ^{
        MTClockImageSetAdapterRefresh();
    });
}

static void MTClockReloadFace(id view) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        view, MTClockViewUpdateSelector, NO);
}

static void MTClockCompleteLayout(id view) {
    ((void (*)(id, SEL))objc_msgSend)(view, MTClockSetNeedsLayoutSelector);
    ((void (*)(id, SEL))objc_msgSend)(view, MTClockLayoutIfNeededSelector);
}

static BOOL MTClockImageSetMethodMatches(Class imageSetClass,
                                         const char *selectorName,
                                         const char *typeEncoding) {
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(imageSetClass, selector);
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static id MTHookedMakeImageSet(id self, SEL selector, const void *metrics) {
    id originalImageSet = MTOriginalMakeImageSet(self, selector, metrics);
    atomic_fetch_add_explicit(
        &MTRuntimeClockImageSetAdapterObservation.imageSetCalls,
        1, memory_order_relaxed);
    MTClockIconImageSet *theme = MTClockIconSnapshotCurrentImageSet();
    Class imageSetClass = originalImageSet == nil
        ? Nil : object_getClass(originalImageSet);
    if (theme == nil || imageSetClass == Nil ||
        strcmp(class_getName(imageSetClass), MTClockImageSetClassName) != 0 ||
        !MTSpringBoardHomeClassMatchesExpectedImage(imageSetClass)) {
        return originalImageSet;
    }
    id imageSet = [imageSetClass new];
    if (imageSet == nil) return originalImageSet;
    SEL getMetrics = sel_registerName("getMetrics:");
    SEL setMetrics = sel_registerName("setMetrics:");
    unsigned char metricsBytes[232] = {0};
    ((void (*)(id, SEL, void *))objc_msgSend)(
        originalImageSet, getMetrics, metricsBytes);
    ((void (*)(id, SEL, const void *))objc_msgSend)(
        imageSet, setMetrics, metricsBytes);
    struct {
        const char *getter;
        const char *setter;
        id replacement;
    } components[] = {
        {"hours", "setHours:", theme.hourHand},
        {"minutes", "setMinutes:", theme.minuteHand},
        {"seconds", "setSeconds:", theme.secondHand},
        {"hourMinuteDot", "setHourMinuteDot:", theme.hourMinuteDot},
        {"secondDot", "setSecondDot:", theme.secondDot},
    };
    for (NSUInteger index = 0;
         index < sizeof(components) / sizeof(components[0]); index++) {
        id component = components[index].replacement;
        if (component == nil) {
            component = ((id (*)(id, SEL))objc_msgSend)(
                originalImageSet, sel_registerName(components[index].getter));
        }
        ((void (*)(id, SEL, id))objc_msgSend)(
            imageSet, sel_registerName(components[index].setter), component);
    }
    atomic_fetch_add_explicit(
        &MTRuntimeClockImageSetAdapterObservation.themedImageSets,
        1, memory_order_relaxed);
    return imageSet;
}

static id MTClockResolveFace(id original) {
    atomic_fetch_add_explicit(
        &MTRuntimeClockImageSetAdapterObservation.backgroundCalls,
        1, memory_order_relaxed);
    BOOL didReplace = NO;
    id background = MTIconImageCacheAdapterResolveReplacement(
        MTClockIconTargetBundleIdentifier, original, &didReplace);
    if (!didReplace) return original;
    atomic_fetch_add_explicit(
        &MTRuntimeClockImageSetAdapterObservation.themedBackgrounds,
        1, memory_order_relaxed);
    return background;
}

static id MTHookedClockContentsImage(id self, SEL selector) {
    MTClockTrackView(self);
    return MTClockResolveFace(MTOriginalContentsImage(self, selector));
}

static id MTHookedClockSquareContentsImage(id self, SEL selector) {
    MTClockTrackView(self);
    return MTClockResolveFace(
        MTOriginalSquareContentsImage(self, selector));
}

static void MTHookedClockApplyMetrics(id self,
                                      SEL selector,
                                      const void *metrics) {
    MTOriginalApplyMetrics(self, selector, metrics);
    MTClockTrackView(self);
    [MTClockAppliedGenerationTokens setObject:MTClockCurrentGenerationToken()
                                      forKey:self];
    // Natural applyMetrics: already runs inside the probed layoutSubviews. Only the
    // inherited image update is needed here; the caller will position all five
    // new layers after this hook returns.
    MTClockReloadFace(self);
}

static void MTClockImageSetAttemptInstallation(uint32_t attempt) {
    Class clockClass = objc_getClass(MTClockClassName);
    Class imageSetClass = objc_getClass(MTClockImageSetClassName);
    SEL selector = sel_registerName(MTClockImageSetSelectorName);
    SEL contentsSelector = sel_registerName(MTClockContentsSelectorName);
    SEL squareContentsSelector =
        sel_registerName(MTClockSquareContentsSelectorName);
    SEL applyMetricsSelector =
        sel_registerName(MTClockApplyMetricsSelectorName);
    SEL getMetricsSelector = sel_registerName(MTClockGetMetricsSelectorName);
    SEL setNeedsLayoutSelector =
        sel_registerName(MTClockSetNeedsLayoutSelectorName);
    SEL layoutIfNeededSelector =
        sel_registerName(MTClockLayoutIfNeededSelectorName);
    SEL updateSelector = sel_registerName(MTClockViewUpdateSelectorName);
    Method method = clockClass == Nil ? NULL :
        class_getClassMethod(clockClass, selector);
    Method contentsMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, contentsSelector);
    Method squareContentsMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, squareContentsSelector);
    Method applyMetricsMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, applyMetricsSelector);
    Method getMetricsMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, getMetricsSelector);
    Method setNeedsLayoutMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, setNeedsLayoutSelector);
    Method layoutIfNeededMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, layoutIfNeededSelector);
    Method updateMethod = clockClass == Nil ? NULL :
        class_getInstanceMethod(clockClass, updateSelector);
    if (method == NULL || contentsMethod == NULL ||
        squareContentsMethod == NULL || applyMetricsMethod == NULL ||
        getMetricsMethod == NULL || setNeedsLayoutMethod == NULL ||
        layoutIfNeededMethod == NULL || updateMethod == NULL ||
        imageSetClass == Nil) {
        if (attempt < MTMaximumInstallAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                MTInstallRetryNanoseconds), dispatch_get_main_queue(), ^{
                MTClockImageSetAttemptInstallation(attempt + 1);
            });
            return;
        }
        atomic_store_explicit(&MTRuntimeClockImageSetAdapterObservation.state,
            MTClockImageSetAdapterStateRejected, memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTClockImageSetAdapterStateRejected,
            @"Rejected");
        return;
    }
    const char *methodType = method_getTypeEncoding(method);
    const char *contentsType = method_getTypeEncoding(contentsMethod);
    const char *squareContentsType =
        method_getTypeEncoding(squareContentsMethod);
    const char *applyMetricsType =
        method_getTypeEncoding(applyMetricsMethod);
    const char *getMetricsType = method_getTypeEncoding(getMetricsMethod);
    const char *setNeedsLayoutType =
        method_getTypeEncoding(setNeedsLayoutMethod);
    const char *layoutIfNeededType =
        method_getTypeEncoding(layoutIfNeededMethod);
    const char *updateType = method_getTypeEncoding(updateMethod);
    // Every gate outcome is recorded so a user report explains exactly which
    // contract kept this surface stock on an untested device or build.
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBHClockApplicationIconImageView",
        clockClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:SBHClockHandsImageSet", imageSetClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBHClockApplicationIconImageView",
        MTSpringBoardHomeClassMatchesExpectedImage(clockClass),
        @"SpringBoardHome", MTReportImageName(clockClass));
    MTRuntimeABIReportRecordContract(
        MTAdapterID, @"image:SBHClockHandsImageSet",
        MTSpringBoardHomeClassMatchesExpectedImage(imageSetClass),
        @"SpringBoardHome", MTReportImageName(imageSetClass));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "imageSetForMetrics:",
        method, MTClockImageSetTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "contentsImage",
        contentsMethod, MTClockFaceOutletTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBHClockApplicationIconImageView.squareContentsImage",
        squareContentsMethod, MTClockFaceOutletTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "applyMetrics:",
        applyMetricsMethod, MTClockApplyMetricsTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "getMetrics:",
        getMetricsMethod, MTClockGetMetricsTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "setNeedsLayout",
        setNeedsLayoutMethod, MTClockLayoutSelectorTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID,
        @"encoding:SBHClockApplicationIconImageView.layoutIfNeeded",
        layoutIfNeededMethod, MTClockLayoutSelectorTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockApplicationIconImageView."
                     "updateImageAnimated:",
        updateMethod, MTClockViewUpdateTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockApplicationIconImageView."
                     "imageSetForMetrics:",
        method_getImplementation(method));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockApplicationIconImageView.contentsImage",
        method_getImplementation(contentsMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID,
        @"impl:SBHClockApplicationIconImageView.squareContentsImage",
        method_getImplementation(squareContentsMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockApplicationIconImageView.applyMetrics:",
        method_getImplementation(applyMetricsMethod));
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockApplicationIconImageView.getMetrics:",
        method_getImplementation(getMetricsMethod));
    BOOL valid = MTSpringBoardHomeClassMatchesExpectedImage(clockClass) &&
        MTSpringBoardHomeClassMatchesExpectedImage(imageSetClass) &&
        methodType != NULL &&
        strcmp(methodType, MTClockImageSetTypeEncoding) == 0 &&
        contentsType != NULL &&
        strcmp(contentsType, MTClockFaceOutletTypeEncoding) == 0 &&
        squareContentsType != NULL &&
        strcmp(squareContentsType, MTClockFaceOutletTypeEncoding) == 0 &&
        applyMetricsType != NULL &&
        strcmp(applyMetricsType, MTClockApplyMetricsTypeEncoding) == 0 &&
        getMetricsType != NULL &&
        strcmp(getMetricsType, MTClockGetMetricsTypeEncoding) == 0 &&
        setNeedsLayoutType != NULL &&
        strcmp(setNeedsLayoutType, MTClockLayoutSelectorTypeEncoding) == 0 &&
        layoutIfNeededType != NULL &&
        strcmp(layoutIfNeededType, MTClockLayoutSelectorTypeEncoding) == 0 &&
        updateType != NULL &&
        strcmp(updateType, MTClockViewUpdateTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(contentsMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(squareContentsMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(applyMetricsMethod)) &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(getMetricsMethod)) &&
        method_getImplementation(setNeedsLayoutMethod) != NULL &&
        method_getImplementation(layoutIfNeededMethod) != NULL &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(updateMethod));
    static const char *const setters[] = {
        "setHours:", "setMinutes:", "setSeconds:",
        "setHourMinuteDot:", "setSecondDot:",
    };
    static const char *const getters[] = {
        "hours", "minutes", "seconds", "hourMinuteDot", "secondDot",
    };
    for (NSUInteger index = 0;
         valid && index < sizeof(setters) / sizeof(setters[0]); index++) {
        valid = MTClockImageSetMethodMatches(
            imageSetClass, setters[index], "v24@0:8@16");
    }
    for (NSUInteger index = 0;
         valid && index < sizeof(getters) / sizeof(getters[0]); index++) {
        valid = MTClockImageSetMethodMatches(
            imageSetClass, getters[index], "@16@0:8");
    }
    valid = valid &&
        MTClockImageSetMethodMatches(imageSetClass, "getMetrics:",
            "v24@0:8o^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16") &&
        MTClockImageSetMethodMatches(imageSetClass, "setMetrics:",
            "v24@0:8rn^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16");
    // The five hand outlets and the metrics copy pair on the image-set class
    // are gates as well; each outcome is recorded with the same shape.
    for (NSUInteger index = 0;
         index < sizeof(setters) / sizeof(setters[0]); index++) {
        Method setter = class_getInstanceMethod(
            imageSetClass, sel_registerName(setters[index]));
        MTRuntimeABIReportProbeMethodType(
            MTAdapterID,
            [@"encoding:SBHClockHandsImageSet."
                stringByAppendingString:@(setters[index])],
            setter, "v24@0:8@16");
        MTRuntimeABIReportProbeImplementation(
            MTAdapterID,
            [@"impl:SBHClockHandsImageSet."
                stringByAppendingString:@(setters[index])],
            setter == NULL ? NULL : method_getImplementation(setter));
    }
    for (NSUInteger index = 0;
         index < sizeof(getters) / sizeof(getters[0]); index++) {
        Method getter = class_getInstanceMethod(
            imageSetClass, sel_registerName(getters[index]));
        MTRuntimeABIReportProbeMethodType(
            MTAdapterID,
            [@"encoding:SBHClockHandsImageSet."
                stringByAppendingString:@(getters[index])],
            getter, "@16@0:8");
        MTRuntimeABIReportProbeImplementation(
            MTAdapterID,
            [@"impl:SBHClockHandsImageSet."
                stringByAppendingString:@(getters[index])],
            getter == NULL ? NULL : method_getImplementation(getter));
    }
    Method imageSetGetMetrics = class_getInstanceMethod(
        imageSetClass, sel_registerName("getMetrics:"));
    Method imageSetSetMetrics = class_getInstanceMethod(
        imageSetClass, sel_registerName("setMetrics:"));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockHandsImageSet.getMetrics:",
        imageSetGetMetrics,
        "v24@0:8o^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
        "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16");
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockHandsImageSet.getMetrics:",
        imageSetGetMetrics == NULL ? NULL :
            method_getImplementation(imageSetGetMetrics));
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, @"encoding:SBHClockHandsImageSet.setMetrics:",
        imageSetSetMetrics,
        "v24@0:8rn^{SBHClockApplicationIconImageMetrics=ddddd{CGSize=dd}dddd"
        "{CGSize=dd}dddd{CGSize=dd}dddddd{SBIconImageInfo={CGSize=dd}dd}}16");
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, @"impl:SBHClockHandsImageSet.setMetrics:",
        imageSetSetMetrics == NULL ? NULL :
            method_getImplementation(imageSetSetMetrics));
    if (!valid) {
        atomic_store_explicit(&MTRuntimeClockImageSetAdapterObservation.state,
            MTClockImageSetAdapterStateRejected, memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTClockImageSetAdapterStateRejected,
            @"Rejected");
        return;
    }
    MTClockViewClass = clockClass;
    MTClockSetNeedsLayoutSelector = setNeedsLayoutSelector;
    MTClockLayoutIfNeededSelector = layoutIfNeededSelector;
    MTClockViewUpdateSelector = updateSelector;
    MTClockViews = [NSHashTable weakObjectsHashTable];
    MTClockAppliedGenerationTokens = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    MTOriginalMakeImageSet = (MTClockMakeImageSetFunction)
        method_getImplementation(method);
    MTOriginalContentsImage = (MTClockImageOutletFunction)
        method_getImplementation(contentsMethod);
    MTOriginalSquareContentsImage = (MTClockImageOutletFunction)
        method_getImplementation(squareContentsMethod);
    MTOriginalApplyMetrics = (MTClockApplyMetricsFunction)
        method_getImplementation(applyMetricsMethod);
    MSHookMessageEx(object_getClass(clockClass), selector,
        (IMP)MTHookedMakeImageSet, (IMP *)&MTOriginalMakeImageSet);
    MSHookMessageEx(clockClass, contentsSelector,
        (IMP)MTHookedClockContentsImage, (IMP *)&MTOriginalContentsImage);
    MSHookMessageEx(clockClass, squareContentsSelector,
        (IMP)MTHookedClockSquareContentsImage,
        (IMP *)&MTOriginalSquareContentsImage);
    MSHookMessageEx(clockClass, applyMetricsSelector,
        (IMP)MTHookedClockApplyMetrics, (IMP *)&MTOriginalApplyMetrics);
    if (MTOriginalMakeImageSet == NULL ||
        MTOriginalContentsImage == NULL ||
        MTOriginalSquareContentsImage == NULL ||
        MTOriginalApplyMetrics == NULL) {
        atomic_store_explicit(&MTRuntimeClockImageSetAdapterObservation.state,
            MTClockImageSetAdapterStateRejected, memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTAdapterID, MTClockImageSetAdapterStateRejected,
            @"Rejected");
        return;
    }
    atomic_store_explicit(&MTRuntimeClockImageSetAdapterObservation.state,
        MTClockImageSetAdapterStateInstalled, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTClockImageSetAdapterStateInstalled,
        @"Installed");
}

BOOL MTClockImageSetAdapterSchedule(NSError **error) {
    (void)error;
    uint32_t expected = MTClockImageSetAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeClockImageSetAdapterObservation.state, &expected,
            MTClockImageSetAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTClockImageSetAdapterStateScheduled ||
            expected == MTClockImageSetAdapterStateInstalled;
    }
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTClockImageSetAdapterStateScheduled,
        @"Scheduled");
    if ([NSThread isMainThread]) {
        MTClockImageSetAttemptInstallation(1);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            MTClockImageSetAttemptInstallation(1);
        });
    }
    return YES;
}

void MTClockImageSetAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeClockImageSetAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeClockImageSetAdapterObservation.state,
            memory_order_acquire) != MTClockImageSetAdapterStateInstalled) {
        return;
    }
    for (id view in MTClockViews.allObjects) {
        if (!MTRuntimeClassIsSubclassOfClass(
                object_getClass(view), MTClockViewClass)) continue;
        if (MTClockViewMatchesCurrentGeneration(view)) {
            MTClockReloadFace(view);
        } else {
            // The probed layoutSubviews owns the complete getMetrics/applyMetrics
            // and five-layer positioning sequence. Mark it dirty and let that
            // sequence run once, instead of creating an unpositioned set first.
            MTClockCompleteLayout(view);
        }
        atomic_fetch_add_explicit(
            &MTRuntimeClockImageSetAdapterObservation.refreshExecutions,
            1, memory_order_relaxed);
    }
}
