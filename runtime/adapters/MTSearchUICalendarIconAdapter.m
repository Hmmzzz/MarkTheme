#import "MTSearchUICalendarIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSearchUIABI.h"

static NSString *const MTSearchUICalendarAdapterID =
    @"spotlight.calendar-appearance";
static NSString *const MTCalendarBundleIdentifier = @"com.apple.mobilecal";
static const char *const MTCalendarClassName =
    "SearchUICalendarIconImage";
static const char *const MTLoadSelectorName =
    "loadImageWithScale:isDarkStyle:";
static const char *const MTLoadTypeEncoding = "@28@0:8d16B24";
static const char *const MTSizeSelectorName = "size";
static const char *const MTSizeTypeEncoding = "{CGSize=dd}16@0:8";
static const char *const MTInvalidateSelectorName = "invalidateAppIcon";
static const char *const MTInvalidateTypeEncoding = "v16@0:8";

typedef id (*MTSearchUILoadFunction)(id, SEL, CGFloat, BOOL);
typedef CGSize (*MTSearchUISizeFunction)(id, SEL);

enum {
    MTSearchUICalendarStateDormant = 0,
    MTSearchUICalendarStateScheduled = 1,
    MTSearchUICalendarStateInstalled = 2,
    MTSearchUICalendarStateRejected = 10,
};

MTSearchUICalendarIconAdapterObservation
    MTRuntimeSearchUICalendarIconAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTSearchUICalendarStateDormant),
        .calls = ATOMIC_VAR_INIT(0),
        .replacements = ATOMIC_VAR_INIT(0),
        .trackedImages = ATOMIC_VAR_INIT(0),
        .refreshRequests = ATOMIC_VAR_INIT(0),
        .refreshInvalidations = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTSearchUICalendarIconAdapterObservation) == 48,
    "SearchUI Calendar adapter observation ABI changed");

static MTSearchUILoadFunction MTOriginalCalendarLoad;
static MTSearchUISizeFunction MTCalendarSize;
static MTSearchUICalendarSurfaceResolver MTCalendarResolver;
static BOOL (*MTCalendarPreparation)(void);
static Class MTCalendarClass;
static SEL MTSizeSelector;
static SEL MTInvalidateSelector;
static NSHashTable *MTTrackedCalendarImages;
static NSLock *MTTrackedCalendarImagesLock;
static _Atomic(bool) MTInstallPassScheduled = false;

static BOOL MTMethodMatches(Method method, const char *typeEncoding) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTSearchUIImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static id MTHookedCalendarLoad(id self,
                               SEL selector,
                               CGFloat scale,
                               BOOL darkStyle) {
    id originalResult = MTOriginalCalendarLoad(
        self, selector, scale, darkStyle);
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUICalendarIconAdapterObservation.calls,
        1, memory_order_relaxed);
    [MTTrackedCalendarImagesLock lock];
    [MTTrackedCalendarImages addObject:self];
    [MTTrackedCalendarImagesLock unlock];
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUICalendarIconAdapterObservation.trackedImages,
        1, memory_order_relaxed);
    CGSize size = MTCalendarSize(self, MTSizeSelector);
    id replacement = MTCalendarResolver(
        MTCalendarBundleIdentifier, size, scale, originalResult);
    if (replacement == nil) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUICalendarIconAdapterObservation.replacements,
        1, memory_order_relaxed);
    return replacement;
}

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            memory_order_acquire) != MTSearchUICalendarStateScheduled) {
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
        MTAttemptInstallation();
    });
}

static void MTRuntimeImageAdded(const struct mach_header *header,
                                intptr_t slide) {
    (void)header;
    (void)slide;
    MTScheduleInstallPass();
}

static void MTAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            memory_order_acquire) != MTSearchUICalendarStateScheduled) {
        return;
    }
    Class calendarClass = objc_getClass(MTCalendarClassName);
    if (calendarClass == Nil) return;
    SEL loadSelector = sel_registerName(MTLoadSelectorName);
    SEL sizeSelector = sel_registerName(MTSizeSelectorName);
    SEL invalidateSelector = sel_registerName(MTInvalidateSelectorName);
    Method loadMethod = class_getInstanceMethod(calendarClass, loadSelector);
    Method sizeMethod = class_getInstanceMethod(calendarClass, sizeSelector);
    Method invalidateMethod = class_getInstanceMethod(
        calendarClass, invalidateSelector);
    MTRuntimeABIReportProbePresence(
        MTSearchUICalendarAdapterID,
        @"class:SearchUICalendarIconImage", YES);
    MTRuntimeABIReportRecordContract(
        MTSearchUICalendarAdapterID,
        @"image:SearchUICalendarIconImage",
        MTSearchUIClassMatchesExpectedImage(calendarClass),
        @"SearchUI", class_getImageName(calendarClass) == NULL
            ? nil : @(class_getImageName(calendarClass)));
    MTRuntimeABIReportProbeMethodType(
        MTSearchUICalendarAdapterID,
        @"encoding:SearchUICalendarIconImage.loadImageWithScale:isDarkStyle:",
        loadMethod, MTLoadTypeEncoding);
    if (!MTSearchUIClassMatchesExpectedImage(calendarClass) ||
        !MTMethodMatches(loadMethod, MTLoadTypeEncoding) ||
        !MTMethodMatches(sizeMethod, MTSizeTypeEncoding) ||
        !MTMethodMatches(invalidateMethod, MTInvalidateTypeEncoding) ||
        !MTCalendarPreparation()) {
        atomic_store_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            MTSearchUICalendarStateRejected, memory_order_release);
        MTRuntimeABIReportRecordAdapterState(
            MTSearchUICalendarAdapterID,
            MTSearchUICalendarStateRejected, @"Rejected");
        return;
    }
    MTCalendarClass = calendarClass;
    MTSizeSelector = sizeSelector;
    MTInvalidateSelector = invalidateSelector;
    MTCalendarSize = (MTSearchUISizeFunction)
        method_getImplementation(sizeMethod);
    MTOriginalCalendarLoad = (MTSearchUILoadFunction)
        method_getImplementation(loadMethod);
    MSHookMessageEx(
        calendarClass, loadSelector, (IMP)MTHookedCalendarLoad,
        (IMP *)&MTOriginalCalendarLoad);
    if (MTOriginalCalendarLoad == NULL) {
        atomic_store_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            MTSearchUICalendarStateRejected, memory_order_release);
        return;
    }
    atomic_store_explicit(
        &MTRuntimeSearchUICalendarIconAdapterObservation.state,
        MTSearchUICalendarStateInstalled, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTSearchUICalendarAdapterID,
        MTSearchUICalendarStateInstalled, @"Installed");
}

BOOL MTSearchUICalendarIconAdapterSchedule(
    MTSearchUICalendarSurfaceResolver resolver,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTSearchUICalendarStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            &expected, MTSearchUICalendarStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTSearchUICalendarStateScheduled ||
            expected == MTSearchUICalendarStateInstalled;
    }
    MTCalendarResolver = resolver;
    MTCalendarPreparation = preparation;
    MTTrackedCalendarImages = [NSHashTable weakObjectsHashTable];
    MTTrackedCalendarImagesLock = [[NSLock alloc] init];
    if (MTTrackedCalendarImages == nil ||
        MTTrackedCalendarImagesLock == nil) {
        return NO;
    }
    MTRuntimeABIReportRecordAdapterState(
        MTSearchUICalendarAdapterID,
        MTSearchUICalendarStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptInstallation();
    } else {
        MTScheduleInstallPass();
    }
    return YES;
}

void MTSearchUICalendarIconAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeSearchUICalendarIconAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation.state,
            memory_order_acquire) != MTSearchUICalendarStateInstalled) {
        return;
    }
    [MTTrackedCalendarImagesLock lock];
    NSArray *images = MTTrackedCalendarImages.allObjects;
    [MTTrackedCalendarImagesLock unlock];
    for (id image in images) {
        if (![image isKindOfClass:MTCalendarClass]) continue;
        Class imageClass = object_getClass(image);
        Method method = class_getInstanceMethod(
            imageClass, MTInvalidateSelector);
        if (!MTMethodMatches(method, MTInvalidateTypeEncoding)) continue;
        ((void (*)(id, SEL))objc_msgSend)(image, MTInvalidateSelector);
        atomic_fetch_add_explicit(
            &MTRuntimeSearchUICalendarIconAdapterObservation
                .refreshInvalidations,
            1, memory_order_relaxed);
    }
}
