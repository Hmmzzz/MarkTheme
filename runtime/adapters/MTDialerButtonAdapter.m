#import "MTDialerButtonAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#import "MTDialerContract.h"
#import "MTMobilePhoneDialerABI.h"

#include <string.h>

static const char *const MTNumberButtonClassName =
    "PHHandsetDialerNumberPadButton";
static const char *const MTNumberButtonBaseClassName = "TPNumberPadButton";
static const char *const MTDialerViewClassName = "PHHandsetDialerView";
static const char *const MTCallButtonClassName = "PHBottomBarButton";
static const char *const MTNumberButtonsSelectorName =
    "numberPadButtonsForCharacters:";
static const char *const MTNewCallButtonSelectorName = "newCallButton";
static const char *const MTReloadImagesSelectorName =
    "reloadImagesForCurrentCharacter";
static const char *const MTHighlightSelectorName = "setHighlighted:";
static const char *const MTObjectArgumentTypeEncoding = "@24@0:8@16";
static const char *const MTObjectResultTypeEncoding = "@16@0:8";
static const char *const MTVoidTypeEncoding = "v16@0:8";
static const char *const MTHighlightTypeEncoding = "v20@0:8B16";

typedef id (*MTNumberButtonsFunction)(id, SEL, id);
typedef id (*MTNewCallButtonFunction)(id, SEL);
typedef void (*MTReloadImagesFunction)(id, SEL);
typedef void (*MTSetHighlightedFunction)(id, SEL, BOOL);

MTDialerButtonAdapterObservation MTRuntimeDialerButtonAdapterObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTDialerButtonAdapterStateDormant),
    .installAttempts = ATOMIC_VAR_INIT(0),
    .numberPadCollections = ATOMIC_VAR_INIT(0),
    .numberReloadCalls = ATOMIC_VAR_INIT(0),
    .numberHighlightCalls = ATOMIC_VAR_INIT(0),
    .callButtonCreations = ATOMIC_VAR_INIT(0),
    .callHighlightCalls = ATOMIC_VAR_INIT(0),
    .resolverCalls = ATOMIC_VAR_INIT(0),
    .appliedResults = ATOMIC_VAR_INIT(0),
    .refreshRequests = ATOMIC_VAR_INIT(0),
    .refreshExecutions = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTDialerButtonAdapterObservation) == 88,
    "The Dialer ProcessAdapter observation layout must remain fixed.");

static MTNumberButtonsFunction MTOriginalNumberButtons;
static MTNewCallButtonFunction MTOriginalNewCallButton;
static MTReloadImagesFunction MTOriginalReloadImages;
static MTSetHighlightedFunction MTOriginalNumberSetHighlighted;
static MTSetHighlightedFunction MTOriginalCallSetHighlighted;
static MTDialerButtonResolver MTButtonResolver;
static MTDialerButtonPreparation MTButtonPreparation;
static Class MTNumberButtonClass;
static Class MTCallButtonClass;
static NSHashTable *MTTrackedNumberButtons;
static NSHashTable *MTTrackedCallButtons;
static char MTNormalSubjectAssociationKey;
static char MTHighlightedSubjectAssociationKey;
static char MTHighlightStateAssociationKey;

static BOOL MTDialerClassIsSubclassOfClass(Class candidate, Class parent) {
    for (NSUInteger depth = 0;
         candidate != Nil && depth < 64;
         depth++, candidate = class_getSuperclass(candidate)) {
        if (candidate == parent) return YES;
    }
    return NO;
}

static BOOL MTDialerButtonMatchesClass(id button, Class expectedClass) {
    return button != nil && expectedClass != Nil &&
        MTDialerClassIsSubclassOfClass(object_getClass(button), expectedClass);
}

static void MTDialerAssociateButton(id button,
                                    NSString *normalSubject,
                                    NSString *highlightedSubject,
                                    NSHashTable *table) {
    objc_setAssociatedObject(button, &MTNormalSubjectAssociationKey,
        normalSubject, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, &MTHighlightedSubjectAssociationKey,
        highlightedSubject, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, &MTHighlightStateAssociationKey,
        @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [table addObject:button];
}

static void MTDialerApplyButton(id button) {
    NSString *normalSubject = objc_getAssociatedObject(
        button, &MTNormalSubjectAssociationKey);
    NSString *highlightedSubject = objc_getAssociatedObject(
        button, &MTHighlightedSubjectAssociationKey);
    NSNumber *highlighted = objc_getAssociatedObject(
        button, &MTHighlightStateAssociationKey);
    if (MTButtonResolver == NULL || normalSubject.length == 0 ||
        highlightedSubject.length == 0) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.resolverCalls,
        1, memory_order_relaxed);
    if (MTButtonResolver(button, normalSubject, highlightedSubject,
                         highlighted.boolValue)) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.appliedResults,
            1, memory_order_relaxed);
    }
}

static id MTHookedNumberButtons(id self, SEL selector, id characters) {
    id originalResult = MTOriginalNumberButtons(self, selector, characters);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.numberPadCollections,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        ![originalResult isKindOfClass:NSArray.class]) {
        return originalResult;
    }
    NSArray *buttons = originalResult;
    NSArray<NSString *> *subjects = MTDialerNumberButtonSubjects();
    NSUInteger count = MIN(buttons.count, subjects.count);
    for (NSUInteger index = 0; index < count; index++) {
        id button = buttons[index];
        if (!MTDialerButtonMatchesClass(button, MTNumberButtonClass)) continue;
        NSString *subject = subjects[index];
        MTDialerAssociateButton(button, subject, subject,
                                MTTrackedNumberButtons);
        MTDialerApplyButton(button);
    }
    return originalResult;
}

static void MTHookedReloadImages(id self, SEL selector) {
    MTOriginalReloadImages(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.numberReloadCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTDialerButtonMatchesClass(self, MTNumberButtonClass)) {
        return;
    }
    MTDialerApplyButton(self);
}

static void MTHookedNumberSetHighlighted(id self,
                                         SEL selector,
                                         BOOL highlighted) {
    MTOriginalNumberSetHighlighted(self, selector, highlighted);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.numberHighlightCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTDialerButtonMatchesClass(self, MTNumberButtonClass)) {
        return;
    }
    objc_setAssociatedObject(self, &MTHighlightStateAssociationKey,
        @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MTDialerApplyButton(self);
}

static id MTHookedNewCallButton(id self, SEL selector) {
    id originalResult = MTOriginalNewCallButton(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callButtonCreations,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTDialerButtonMatchesClass(originalResult, MTCallButtonClass)) {
        return originalResult;
    }
    MTDialerAssociateButton(originalResult, MTDialerCallButtonSubject,
        MTDialerCallButtonPressedSubject, MTTrackedCallButtons);
    MTDialerApplyButton(originalResult);
    return originalResult;
}

static void MTHookedCallSetHighlighted(id self,
                                       SEL selector,
                                       BOOL highlighted) {
    MTOriginalCallSetHighlighted(self, selector, highlighted);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callHighlightCalls,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        objc_getAssociatedObject(self,
            &MTNormalSubjectAssociationKey) == nil) {
        return;
    }
    objc_setAssociatedObject(self, &MTHighlightStateAssociationKey,
        @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MTDialerApplyButton(self);
}

static BOOL MTDialerMethodMatches(Method method,
                                  const char *typeEncoding,
                                  BOOL mobilePhoneImage) {
    if (method == NULL || typeEncoding == NULL) return NO;
    const char *actual = method_getTypeEncoding(method);
    if (actual == NULL || strcmp(actual, typeEncoding) != 0) return NO;
    IMP implementation = method_getImplementation(method);
    return mobilePhoneImage
        ? MTMobilePhoneDialerImplementationMatchesExpectedImage(
            implementation)
        : MTTelephonyUIDialerImplementationMatchesExpectedImage(
            implementation);
}

static void MTDialerAttemptInstallation(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class dialerViewClass = objc_getClass(MTDialerViewClassName);
    Class numberButtonClass = objc_getClass(MTNumberButtonClassName);
    Class numberButtonBaseClass = objc_getClass(MTNumberButtonBaseClassName);
    Class callButtonClass = objc_getClass(MTCallButtonClassName);
    SEL numberButtonsSelector = sel_registerName(
        MTNumberButtonsSelectorName);
    SEL newCallButtonSelector = sel_registerName(
        MTNewCallButtonSelectorName);
    SEL reloadImagesSelector = sel_registerName(
        MTReloadImagesSelectorName);
    SEL highlightedSelector = sel_registerName(MTHighlightSelectorName);
    Method numberButtonsMethod = dialerViewClass == Nil ? NULL :
        class_getInstanceMethod(dialerViewClass, numberButtonsSelector);
    Method newCallButtonMethod = dialerViewClass == Nil ? NULL :
        class_getInstanceMethod(dialerViewClass, newCallButtonSelector);
    Method reloadImagesMethod = numberButtonBaseClass == Nil ? NULL :
        class_getInstanceMethod(numberButtonBaseClass, reloadImagesSelector);
    Method numberHighlightMethod = numberButtonBaseClass == Nil ? NULL :
        class_getInstanceMethod(numberButtonBaseClass, highlightedSelector);
    Method callHighlightMethod = callButtonClass == Nil ? NULL :
        class_getInstanceMethod(callButtonClass, highlightedSelector);

    BOOL valid = dialerViewClass != Nil && numberButtonClass != Nil &&
        numberButtonBaseClass != Nil && callButtonClass != Nil &&
        MTMobilePhoneDialerClassMatchesExpectedImage(dialerViewClass) &&
        MTMobilePhoneDialerClassMatchesExpectedImage(numberButtonClass) &&
        MTTelephonyUIDialerClassMatchesExpectedImage(numberButtonBaseClass) &&
        MTMobilePhoneDialerClassMatchesExpectedImage(callButtonClass) &&
        MTDialerClassIsSubclassOfClass(numberButtonClass,
                                       numberButtonBaseClass) &&
        MTDialerMethodMatches(numberButtonsMethod,
                              MTObjectArgumentTypeEncoding, YES) &&
        MTDialerMethodMatches(newCallButtonMethod,
                              MTObjectResultTypeEncoding, YES) &&
        MTDialerMethodMatches(reloadImagesMethod,
                              MTVoidTypeEncoding, NO) &&
        MTDialerMethodMatches(numberHighlightMethod,
                              MTHighlightTypeEncoding, NO) &&
        MTDialerMethodMatches(callHighlightMethod,
                              MTHighlightTypeEncoding, YES);
    if (!valid || MTButtonPreparation == NULL) {
        atomic_store_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            MTDialerButtonAdapterStateRejected,
            memory_order_release);
        return;
    }

    MTNumberButtonClass = numberButtonClass;
    MTCallButtonClass = callButtonClass;
    MTTrackedNumberButtons = [NSHashTable weakObjectsHashTable];
    MTTrackedCallButtons = [NSHashTable weakObjectsHashTable];
    if (MTTrackedNumberButtons == nil || MTTrackedCallButtons == nil) {
        atomic_store_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            MTDialerButtonAdapterStateRejected,
            memory_order_release);
        return;
    }
    MTOriginalNumberButtons = (MTNumberButtonsFunction)
        method_getImplementation(numberButtonsMethod);
    MTOriginalNewCallButton = (MTNewCallButtonFunction)
        method_getImplementation(newCallButtonMethod);
    MTOriginalReloadImages = (MTReloadImagesFunction)
        method_getImplementation(reloadImagesMethod);
    MTOriginalNumberSetHighlighted = (MTSetHighlightedFunction)
        method_getImplementation(numberHighlightMethod);
    MTOriginalCallSetHighlighted = (MTSetHighlightedFunction)
        method_getImplementation(callHighlightMethod);
    MSHookMessageEx(dialerViewClass, numberButtonsSelector,
        (IMP)MTHookedNumberButtons, (IMP *)&MTOriginalNumberButtons);
    MSHookMessageEx(dialerViewClass, newCallButtonSelector,
        (IMP)MTHookedNewCallButton, (IMP *)&MTOriginalNewCallButton);
    MSHookMessageEx(numberButtonBaseClass, reloadImagesSelector,
        (IMP)MTHookedReloadImages, (IMP *)&MTOriginalReloadImages);
    MSHookMessageEx(numberButtonBaseClass, highlightedSelector,
        (IMP)MTHookedNumberSetHighlighted,
        (IMP *)&MTOriginalNumberSetHighlighted);
    MSHookMessageEx(callButtonClass, highlightedSelector,
        (IMP)MTHookedCallSetHighlighted,
        (IMP *)&MTOriginalCallSetHighlighted);
    if (MTOriginalNumberButtons == NULL ||
        MTOriginalNewCallButton == NULL ||
        MTOriginalReloadImages == NULL ||
        MTOriginalNumberSetHighlighted == NULL ||
        MTOriginalCallSetHighlighted == NULL) {
        atomic_store_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            MTDialerButtonAdapterStateRejected,
            memory_order_release);
        return;
    }
    atomic_store_explicit(
        &MTRuntimeDialerButtonAdapterObservation.state,
        MTDialerButtonAdapterStateInstalled,
        memory_order_release);
}

BOOL MTDialerButtonAdapterSchedule(MTDialerButtonResolver resolver,
                                   MTDialerButtonPreparation preparation,
                                   NSError **error) {
    (void)error;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTDialerButtonAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            &expected, MTDialerButtonAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTDialerButtonAdapterStateScheduled ||
            expected == MTDialerButtonAdapterStateInstalled;
    }
    MTButtonResolver = resolver;
    MTButtonPreparation = preparation;
    // Class/method/image validation and MSHook registration are independent of
    // UIKit process state. Install synchronously while the dylib constructor
    // still precedes MobilePhone view construction, otherwise the one-shot
    // number-pad and call-button factories can be missed permanently.
    MTDialerAttemptInstallation();
    if (atomic_load_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            memory_order_acquire) != MTDialerButtonAdapterStateInstalled) {
        return NO;
    }
    // Image preparation remains behind a deterministic main-queue boundary.
    // Hooks that run first stay original-first and merely retain weak targets;
    // the ready handler refreshes them after bounded decoding completes.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (MTButtonPreparation != NULL) (void)MTButtonPreparation();
    });
    return YES;
}

void MTDialerButtonAdapterRefresh(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.refreshRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        atomic_load_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            memory_order_acquire) != MTDialerButtonAdapterStateInstalled) {
        return;
    }
    NSArray *numberButtons = MTTrackedNumberButtons.allObjects;
    NSArray *callButtons = MTTrackedCallButtons.allObjects;
    for (id button in [numberButtons arrayByAddingObjectsFromArray:
            callButtons]) {
        MTDialerApplyButton(button);
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.refreshExecutions,
            1, memory_order_relaxed);
    }
}
