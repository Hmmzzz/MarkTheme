#import "MTCalendarApplicationIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/runtime.h>

#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTCalendarAdapterID =
    @"springboard.calendar-application-icon";
static NSString *const MTCalendarBundleIdentifier = @"com.apple.mobilecal";
static const char *const MTCalendarClassName =
    "SBHCalendarApplicationIcon";
static const char *const MTGeneratedSelectorName =
    "generateIconImageWithInfo:";
static const char *const MTUnmaskedSelectorName =
    "unmaskedIconImageWithInfo:";
static const char *const MTImageTypeEncoding =
    "@48@0:8{SBIconImageInfo={CGSize=dd}dd}16";

typedef struct MTCalendarIconImageSize {
    double width;
    double height;
} MTCalendarIconImageSize;

typedef struct MTCalendarIconImageInfo {
    MTCalendarIconImageSize size;
    double scale;
    double continuousCornerRadius;
} MTCalendarIconImageInfo;

typedef id (*MTCalendarImageFunction)(
    id, SEL, MTCalendarIconImageInfo);

MTCalendarApplicationIconAdapterObservation
    MTRuntimeCalendarApplicationIconAdapterObservation = {
        .schemaVersion = 1,
        .installed = ATOMIC_VAR_INIT(0),
        .generatedCalls = ATOMIC_VAR_INIT(0),
        .unmaskedCalls = ATOMIC_VAR_INIT(0),
        .appearanceReplacements = ATOMIC_VAR_INIT(0),
        .sourceReplacements = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTCalendarApplicationIconAdapterObservation) == 40,
    "Calendar application-icon adapter observation ABI changed");

static MTCalendarImageFunction MTOriginalGeneratedImage;
static MTCalendarImageFunction MTOriginalUnmaskedImage;
static MTRuntimeReplacementResolver MTAppearanceResolver;
static MTRuntimeReplacementResolver MTSourceResolver;

static id MTCalendarResolve(id self,
                            SEL selector,
                            MTCalendarIconImageInfo info,
                            MTCalendarImageFunction original,
                            MTRuntimeReplacementResolver resolver,
                            _Atomic(uint64_t) *calls,
                            _Atomic(uint64_t) *replacements) {
    id originalResult = original(self, selector, info);
    atomic_fetch_add_explicit(calls, 1, memory_order_relaxed);
    BOOL replaced = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        MTCalendarBundleIdentifier, originalResult, resolver, &replaced);
    if (replaced) {
        atomic_fetch_add_explicit(replacements, 1, memory_order_relaxed);
    }
    return result;
}

static id MTHookedGeneratedImage(id self,
                                 SEL selector,
                                 MTCalendarIconImageInfo info) {
    return MTCalendarResolve(
        self, selector, info, MTOriginalGeneratedImage,
        MTAppearanceResolver,
        &MTRuntimeCalendarApplicationIconAdapterObservation.generatedCalls,
        &MTRuntimeCalendarApplicationIconAdapterObservation
             .appearanceReplacements);
}

static id MTHookedUnmaskedImage(id self,
                                SEL selector,
                                MTCalendarIconImageInfo info) {
    return MTCalendarResolve(
        self, selector, info, MTOriginalUnmaskedImage, MTSourceResolver,
        &MTRuntimeCalendarApplicationIconAdapterObservation.unmaskedCalls,
        &MTRuntimeCalendarApplicationIconAdapterObservation
             .sourceReplacements);
}

static BOOL MTCalendarMethodMatches(Method method) {
    const char *encoding = method == NULL ? NULL :
        method_getTypeEncoding(method);
    return encoding != NULL &&
        strcmp(encoding, MTImageTypeEncoding) == 0 &&
        MTSpringBoardHomeImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

BOOL MTCalendarApplicationIconAdapterInstall(
    MTRuntimeReplacementResolver appearanceResolver,
    MTRuntimeReplacementResolver sourceResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (appearanceResolver == NULL || sourceResolver == NULL ||
        preparation == NULL ||
        atomic_load_explicit(
            &MTRuntimeCalendarApplicationIconAdapterObservation.installed,
            memory_order_acquire) != 0) {
        return appearanceResolver != NULL && sourceResolver != NULL &&
            preparation != NULL;
    }
    Class calendarClass = objc_getClass(MTCalendarClassName);
    SEL generatedSelector = sel_registerName(MTGeneratedSelectorName);
    SEL unmaskedSelector = sel_registerName(MTUnmaskedSelectorName);
    Method generatedMethod = calendarClass == Nil ? NULL :
        class_getInstanceMethod(calendarClass, generatedSelector);
    Method unmaskedMethod = calendarClass == Nil ? NULL :
        class_getInstanceMethod(calendarClass, unmaskedSelector);
    MTRuntimeABIReportProbePresence(
        MTCalendarAdapterID, @"class:SBHCalendarApplicationIcon",
        calendarClass != Nil);
    MTRuntimeABIReportRecordContract(
        MTCalendarAdapterID, @"image:SBHCalendarApplicationIcon",
        MTSpringBoardHomeClassMatchesExpectedImage(calendarClass),
        @"SpringBoardHome",
        calendarClass == Nil || class_getImageName(calendarClass) == NULL
            ? nil
            : @(class_getImageName(calendarClass)));
    MTRuntimeABIReportProbeMethodType(
        MTCalendarAdapterID,
        @"encoding:SBHCalendarApplicationIcon.generateIconImageWithInfo:",
        generatedMethod, MTImageTypeEncoding);
    MTRuntimeABIReportProbeMethodType(
        MTCalendarAdapterID,
        @"encoding:SBHCalendarApplicationIcon.unmaskedIconImageWithInfo:",
        unmaskedMethod, MTImageTypeEncoding);
    if (calendarClass == Nil ||
        !MTSpringBoardHomeClassMatchesExpectedImage(calendarClass) ||
        !MTCalendarMethodMatches(generatedMethod) ||
        !MTCalendarMethodMatches(unmaskedMethod) || !preparation()) {
        return NO;
    }
    MTAppearanceResolver = appearanceResolver;
    MTSourceResolver = sourceResolver;
    MTOriginalGeneratedImage = (MTCalendarImageFunction)
        method_getImplementation(generatedMethod);
    MTOriginalUnmaskedImage = (MTCalendarImageFunction)
        method_getImplementation(unmaskedMethod);
    MSHookMessageEx(
        calendarClass, generatedSelector, (IMP)MTHookedGeneratedImage,
        (IMP *)&MTOriginalGeneratedImage);
    MSHookMessageEx(
        calendarClass, unmaskedSelector, (IMP)MTHookedUnmaskedImage,
        (IMP *)&MTOriginalUnmaskedImage);
    if (MTOriginalGeneratedImage == NULL ||
        MTOriginalUnmaskedImage == NULL) {
        return NO;
    }
    atomic_store_explicit(
        &MTRuntimeCalendarApplicationIconAdapterObservation.installed,
        1, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTCalendarAdapterID, 1, @"Installed");
    return YES;
}
