#import "MTCalendarUIKitSourceAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <math.h>
#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"

static NSString *const MTCalendarUIKitSourceAdapterID =
    @"calendar-ui-kit.dynamic-icon-source";
static const char *const MTCalendarUIKitImagePath =
    "/System/Library/PrivateFrameworks/"
    "CalendarUIKit.framework/CalendarUIKit";
static const char *const MTCalendarGeneratorClassName =
    "CUIKDefaultIconGenerator";
static const char *const MTCalendarGeneratorSelectorName =
    "iconImageWithDateComponents:calendar:format:size:scale:";
static const char *const MTCalendarGeneratorTypeEncoding =
    "^{CGImage=}64@0:8@16@24q32{CGSize=dd}40d56";

typedef CGImageRef _Nullable (*MTCalendarGeneratorFunction)(
    id, SEL, id, id, NSInteger, CGSize, CGFloat);

MTCalendarUIKitSourceAdapterObservation
    MTRuntimeCalendarUIKitSourceAdapterObservation = {
        .schemaVersion = 2,
        .state = ATOMIC_VAR_INIT(
            MTCalendarUIKitSourceAdapterStateDormant),
        .calls = ATOMIC_VAR_INIT(0),
        .outOfScopeCalls = ATOMIC_VAR_INIT(0),
        .originalFailures = ATOMIC_VAR_INIT(0),
        .resolverMisses = ATOMIC_VAR_INIT(0),
        .rasterRejects = ATOMIC_VAR_INIT(0),
        .replacements = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTCalendarUIKitSourceAdapterObservation) == 56,
    "CalendarUIKit source observation ABI changed");

static MTCalendarGeneratorFunction MTOriginalCalendarGenerator;
static MTCalendarUIKitSourceResolver MTCalendarSourceResolver;
static BOOL (*MTCalendarSourcePreparation)(void);
static _Atomic(bool) MTInstallPassScheduled = false;

static BOOL MTCalendarSourceContractIsSupported(CGSize pointSize,
                                                 CGFloat scale) {
    return isfinite(pointSize.width) && isfinite(pointSize.height) &&
        isfinite(scale) && pointSize.width == pointSize.height &&
        pointSize.width >= 1 && pointSize.width <= 400 &&
        scale >= 1 && scale <= 3 && floor(scale) == scale;
}

static BOOL MTCalendarGeneratorMethodMatches(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL &&
        strcmp(encoding, MTCalendarGeneratorTypeEncoding) == 0 &&
        MTRuntimeImplementationResolves(
            method_getImplementation(method));
}

static CGImageRef MTHookedCalendarGenerator(id self,
                                             SEL selector,
                                             id dateComponents,
                                             id calendar,
                                             NSInteger format,
                                             CGSize pointSize,
                                             CGFloat scale) {
    CGImageRef original = MTOriginalCalendarGenerator(
        self, selector, dateComponents, calendar, format, pointSize, scale);
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarUIKitSourceAdapterObservation.calls,
        1, memory_order_relaxed);
    // Exact 21D61 callers use format 0 for the Calendar application icon.
    // SearchUI uses format 1 when its image has no application bundle owner.
    if (format != 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.outOfScopeCalls,
            1, memory_order_relaxed);
        return original;
    }
    if (original == NULL) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.originalFailures,
            1, memory_order_relaxed);
        return NULL;
    }
    if (![dateComponents isKindOfClass:NSDateComponents.class] ||
        ![calendar isKindOfClass:NSCalendar.class] ||
        !MTCalendarSourceContractIsSupported(pointSize, scale)) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.rasterRejects,
            1, memory_order_relaxed);
        return original;
    }
    CGImageRef replacement = MTCalendarSourceResolver(
        dateComponents, calendar, format, pointSize, scale);
    if (replacement == NULL) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return original;
    }
    if (CGImageGetWidth(replacement) != CGImageGetWidth(original) ||
        CGImageGetHeight(replacement) != CGImageGetHeight(original)) {
        atomic_fetch_add_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.rasterRejects,
            1, memory_order_relaxed);
        CGImageRelease(replacement);
        return original;
    }

    // CalendarUIKit returns this CGImage at +1 and releases it after wrapping
    // it in IFImage. Preserve that private ownership convention exactly.
    CGImageRelease(original);
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarUIKitSourceAdapterObservation.replacements,
        1, memory_order_relaxed);
    return replacement;
}

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTCalendarUIKitSourceAdapterStateScheduled) {
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

static void MTRejectInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeCalendarUIKitSourceAdapterObservation.state,
        MTCalendarUIKitSourceAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTCalendarUIKitSourceAdapterID,
        MTCalendarUIKitSourceAdapterStateRejected, @"Rejected");
}

static void MTAttemptInstallation(void) {
    if (![NSThread isMainThread]) {
        MTScheduleInstallPass();
        return;
    }
    if (atomic_load_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.state,
            memory_order_acquire) !=
        MTCalendarUIKitSourceAdapterStateScheduled) {
        return;
    }
    Class generatorClass = objc_getClass(MTCalendarGeneratorClassName);
    if (generatorClass == Nil) return;
    SEL generatorSelector =
        sel_registerName(MTCalendarGeneratorSelectorName);
    Method generatorMethod = class_getInstanceMethod(
        generatorClass, generatorSelector);
    const char *classImage = class_getImageName(generatorClass);
    BOOL classMatches = classImage != NULL &&
        strcmp(classImage, MTCalendarUIKitImagePath) == 0;
    MTRuntimeABIReportProbePresence(
        MTCalendarUIKitSourceAdapterID,
        @"class:CUIKDefaultIconGenerator", YES);
    MTRuntimeABIReportRecordContract(
        MTCalendarUIKitSourceAdapterID,
        @"image:CUIKDefaultIconGenerator", classMatches,
        @(MTCalendarUIKitImagePath),
        classImage == NULL ? nil : @(classImage));
    MTRuntimeABIReportProbeMethodType(
        MTCalendarUIKitSourceAdapterID,
        @"encoding:CUIKDefaultIconGenerator."
         "iconImageWithDateComponents:calendar:format:size:scale:",
        generatorMethod, MTCalendarGeneratorTypeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTCalendarUIKitSourceAdapterID,
        @"implementation:CUIKDefaultIconGenerator.dynamicSource",
        generatorMethod == NULL ? NULL :
            method_getImplementation(generatorMethod));
    if (!classMatches ||
        !MTCalendarGeneratorMethodMatches(generatorMethod) ||
        !MTCalendarSourcePreparation()) {
        MTRejectInstallation();
        return;
    }
    MTOriginalCalendarGenerator = (MTCalendarGeneratorFunction)
        method_getImplementation(generatorMethod);
    MSHookMessageEx(
        generatorClass, generatorSelector,
        (IMP)MTHookedCalendarGenerator,
        (IMP *)&MTOriginalCalendarGenerator);
    if (MTOriginalCalendarGenerator == NULL) {
        MTRejectInstallation();
        return;
    }
    atomic_store_explicit(
        &MTRuntimeCalendarUIKitSourceAdapterObservation.state,
        MTCalendarUIKitSourceAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTCalendarUIKitSourceAdapterID,
        MTCalendarUIKitSourceAdapterStateInstalled, @"Installed");
}

BOOL MTCalendarUIKitSourceAdapterSchedule(
    MTCalendarUIKitSourceResolver resolver,
    BOOL (*preparation)(void),
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTCalendarUIKitSourceAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeCalendarUIKitSourceAdapterObservation.state,
            &expected, MTCalendarUIKitSourceAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTCalendarUIKitSourceAdapterStateScheduled ||
            expected == MTCalendarUIKitSourceAdapterStateInstalled;
    }
    MTCalendarSourceResolver = resolver;
    MTCalendarSourcePreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTCalendarUIKitSourceAdapterID,
        MTCalendarUIKitSourceAdapterStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) {
        MTAttemptInstallation();
    } else {
        MTScheduleInstallPass();
    }
    return YES;
}
