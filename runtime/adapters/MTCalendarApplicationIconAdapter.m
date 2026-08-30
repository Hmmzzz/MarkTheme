#import "MTCalendarApplicationIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/runtime.h>

#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTSpringBoardHomeABI.h"

static NSString *const MTCalendarAdapterID =
    @"springboard.calendar-appearance";
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
        .appearanceReplacements = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTCalendarApplicationIconAdapterObservation) == 24,
    "Calendar application-icon adapter observation ABI changed");

static MTCalendarImageFunction MTOriginalGeneratedImage;
static MTCalendarApplicationAppearanceResolver MTAppearanceResolver;

static id MTHookedGeneratedImage(id self,
                                 SEL selector,
                                 MTCalendarIconImageInfo info) {
    id originalResult = MTOriginalGeneratedImage(self, selector, info);
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarApplicationIconAdapterObservation.generatedCalls,
        1, memory_order_relaxed);
    id replacement = MTAppearanceResolver(
        MTCalendarBundleIdentifier,
        CGSizeMake(info.size.width, info.size.height),
        info.scale, originalResult);
    if (replacement == nil) return originalResult;
    atomic_fetch_add_explicit(
        &MTRuntimeCalendarApplicationIconAdapterObservation
            .appearanceReplacements,
        1, memory_order_relaxed);
    return replacement;
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
    MTCalendarApplicationAppearanceResolver appearanceResolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (appearanceResolver == NULL || preparation == NULL ||
        atomic_load_explicit(
            &MTRuntimeCalendarApplicationIconAdapterObservation.installed,
            memory_order_acquire) != 0) {
        return appearanceResolver != NULL && preparation != NULL;
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
    MTOriginalGeneratedImage = (MTCalendarImageFunction)
        method_getImplementation(generatedMethod);
    MSHookMessageEx(
        calendarClass, generatedSelector, (IMP)MTHookedGeneratedImage,
        (IMP *)&MTOriginalGeneratedImage);
    if (MTOriginalGeneratedImage == NULL) {
        return NO;
    }
    atomic_store_explicit(
        &MTRuntimeCalendarApplicationIconAdapterObservation.installed,
        1, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTCalendarAdapterID, 1, @"Installed");
    return YES;
}
