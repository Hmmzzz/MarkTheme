#import "MTDialerButtonAdapter.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "MTDialerContract.h"
#import "MTMobilePhoneDialerABI.h"
#import "MTRuntimeABIReport.h"

#include <string.h>

static NSString *const MTAdapterID = @"mobilephone.dialer-buttons";

static const char *const MTNumberButtonClassName =
    "PHHandsetDialerNumberPadButton";
static const char *const MTNumberButtonDynamicClassName =
    "TPNumberPadDynamicButton";
static const char *const MTNumberButtonBaseClassName = "TPNumberPadButton";
static const char *const MTDialerViewClassName = "PHHandsetDialerView";
static const char *const MTCallButtonClassName = "PHBottomBarButton";
static const char *const MTButtonClassName = "UIButton";
static const char *const MTImageClassName = "UIImage";
static const char *const MTImageViewClassName = "UIImageView";
static const char *const MTColorClassName = "UIColor";
static const char *const MTNumberImageSourceSelectorName =
    "imageForCharacter:highlighted:whiteVersion:";
static const char *const MTUnhighlightedCircleAlphaSelectorName =
    "unhighlightedCircleViewAlpha";
static const char *const MTHighlightedCircleAlphaSelectorName =
    "highlightedCircleViewAlpha";
static const char *const MTNewCallButtonSelectorName = "newCallButton";
static const char *const MTNewCallOverlaySelectorName = "newOverlayView";
static const char *const MTRoundViewSelectorName = "roundView";
static const char *const MTEffectViewSelectorName = "effectView";
static const char *const MTRingViewSelectorName = "ringView";

static const char *const MTNumberImageSourceTypeEncoding =
    "@32@0:8q16B24B28";
static const char *const MTCircleAlphaTypeEncoding = "d16@0:8";
static const char *const MTObjectResultTypeEncoding = "@16@0:8";

typedef id (*MTNumberImageSourceFunction)(
    id, SEL, NSInteger, BOOL, BOOL);
typedef CGFloat (*MTCircleAlphaFunction)(id, SEL);
typedef id (*MTObjectResultFunction)(id, SEL);

typedef NS_OPTIONS(NSUInteger, MTDialerControlState) {
    MTDialerControlStateNormal = 0,
    MTDialerControlStateHighlighted = 1UL << 0,
    MTDialerControlStateDisabled = 1UL << 1,
    MTDialerControlStateSelected = 1UL << 2,
};

typedef NS_OPTIONS(NSUInteger, MTDialerAutoresizingMask) {
    MTDialerAutoresizingFlexibleWidth = 1UL << 1,
    MTDialerAutoresizingFlexibleHeight = 1UL << 4,
};

static const NSInteger MTDialerContentModeCenter = 4;

MTDialerButtonAdapterObservation MTRuntimeDialerButtonAdapterObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTDialerButtonAdapterStateDormant),
    .installAttempts = ATOMIC_VAR_INIT(0),
    .numberSourceCalls = ATOMIC_VAR_INIT(0),
    .numberNormalCalls = ATOMIC_VAR_INIT(0),
    .numberHighlightedCalls = ATOMIC_VAR_INIT(0),
    .circleAlphaCalls = ATOMIC_VAR_INIT(0),
    .circleSuppressions = ATOMIC_VAR_INIT(0),
    .callButtonCreations = ATOMIC_VAR_INIT(0),
    .callNormalReplacements = ATOMIC_VAR_INIT(0),
    .callOverlayRequests = ATOMIC_VAR_INIT(0),
    .callPressedReplacements = ATOMIC_VAR_INIT(0),
    .resolverMisses = ATOMIC_VAR_INIT(0),
    .contractRejects = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTDialerButtonAdapterObservation) == 104,
    "The Dialer native-source observation layout must remain fixed.");

static MTNumberImageSourceFunction MTOriginalNumberImageSource;
static MTCircleAlphaFunction MTOriginalUnhighlightedCircleAlpha;
static MTCircleAlphaFunction MTOriginalHighlightedCircleAlpha;
static MTObjectResultFunction MTOriginalNewCallButton;
static MTObjectResultFunction MTOriginalNewCallOverlay;
static MTDialerImageResolver MTImageResolver;
static MTDialerCompleteNumberSetResolver MTCompleteNumberSetResolver;
static MTDialerButtonPreparation MTPreparation;
static Class MTCallButtonClass;
static Class MTImageClass;
static Class MTImageViewClass;
static Class MTColorClass;
static char MTCallPressedImageAssociationKey;

static NSString *MTReportImageName(Class runtimeClass) {
    const char *imageName = runtimeClass == Nil
        ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static BOOL MTDialerClassIsSubclassOfClass(Class candidate, Class parent) {
    for (NSUInteger depth = 0;
         candidate != Nil && depth < 64;
         depth++, candidate = class_getSuperclass(candidate)) {
        if (candidate == parent) return YES;
    }
    return NO;
}

static BOOL MTDialerObjectMatchesClass(id object, Class expectedClass) {
    return object != nil && expectedClass != Nil &&
        MTDialerClassIsSubclassOfClass(object_getClass(object), expectedClass);
}

static NSString *MTDialerSubjectForCharacter(NSInteger character) {
    NSArray<NSString *> *subjects = MTDialerNumberButtonSubjects();
    if (character < 0 || (NSUInteger)character >= subjects.count) return nil;
    return subjects[(NSUInteger)character];
}

static BOOL MTDialerMethodMatches(Method method,
                                  const char *typeEncoding,
                                  BOOL mobilePhoneImage) {
    const char *actual = method == NULL ? NULL :
        method_getTypeEncoding(method);
    if (actual == NULL || strcmp(actual, typeEncoding) != 0) return NO;
    IMP implementation = method_getImplementation(method);
    return mobilePhoneImage
        ? MTMobilePhoneDialerImplementationMatchesExpectedImage(
            implementation)
        : MTTelephonyUIDialerImplementationMatchesExpectedImage(
            implementation);
}

static id MTHookedNumberImageSource(id self,
                                    SEL selector,
                                    NSInteger character,
                                    BOOL highlighted,
                                    BOOL whiteVersion) {
    id original = MTOriginalNumberImageSource(
        self, selector, character, highlighted, whiteVersion);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.numberSourceCalls,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        highlighted
            ? &MTRuntimeDialerButtonAdapterObservation
                .numberHighlightedCalls
            : &MTRuntimeDialerButtonAdapterObservation.numberNormalCalls,
        1, memory_order_relaxed);
    NSString *subject = MTDialerSubjectForCharacter(character);
    if (!MTDialerObjectMatchesClass(original, MTImageClass) ||
        subject.length == 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return original;
    }
    // Number-pad canvases are an atomic set. If any one of the twelve slots
    // is absent or undecodable, both artwork and circle alpha stay stock.
    if (!MTCompleteNumberSetResolver()) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return original;
    }
    id replacement = MTImageResolver(subject, original);
    if (!MTDialerObjectMatchesClass(replacement, MTImageClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return original;
    }
    return replacement;
}

static CGFloat MTHookedCircleAlpha(MTCircleAlphaFunction original,
                                   id self,
                                   SEL selector) {
    CGFloat nativeAlpha = original(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.circleAlphaCalls,
        1, memory_order_relaxed);
    if (!MTCompleteNumberSetResolver()) return nativeAlpha;
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.circleSuppressions,
        1, memory_order_relaxed);
    return 0.0;
}

static CGFloat MTHookedUnhighlightedCircleAlpha(id self, SEL selector) {
    return MTHookedCircleAlpha(
        MTOriginalUnhighlightedCircleAlpha, self, selector);
}

static CGFloat MTHookedHighlightedCircleAlpha(id self, SEL selector) {
    return MTHookedCircleAlpha(
        MTOriginalHighlightedCircleAlpha, self, selector);
}

static id MTDialerObjectResult(id object, const char *selectorName) {
    return ((id (*)(id, SEL))objc_msgSend)(
        object, sel_registerName(selectorName));
}

static id MTDialerObjectResultForState(id object,
                                       const char *selectorName,
                                       NSUInteger state) {
    return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
        object, sel_registerName(selectorName), state);
}

static void MTDialerSetObject(id object,
                              const char *selectorName,
                              id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(
        object, sel_registerName(selectorName), value);
}

static void MTDialerSetBool(id object,
                            const char *selectorName,
                            BOOL value) {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        object, sel_registerName(selectorName), value);
}

static void MTDialerSetInteger(id object,
                               const char *selectorName,
                               NSInteger value) {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(
        object, sel_registerName(selectorName), value);
}

static void MTDialerSetUnsignedInteger(id object,
                                       const char *selectorName,
                                       NSUInteger value) {
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(
        object, sel_registerName(selectorName), value);
}

static void MTDialerSetImageForState(id button,
                                     id image,
                                     NSUInteger state) {
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        button, sel_registerName("setBackgroundImage:forState:"),
        image, state);
}

static CGRect MTDialerBounds(id object) {
    return ((CGRect (*)(id, SEL))objc_msgSend)(
        object, sel_registerName("bounds"));
}

static void MTDialerHideStockCallArtwork(id button) {
    id stockImageView = MTDialerObjectResult(button, "imageView");
    id roundView = MTDialerObjectResult(
        button, MTRoundViewSelectorName);
    id effectView = MTDialerObjectResult(
        button, MTEffectViewSelectorName);
    id ringView = MTDialerObjectResult(
        button, MTRingViewSelectorName);
    MTDialerSetBool(stockImageView, "setHidden:", YES);
    MTDialerSetBool(roundView, "setHidden:", YES);
    MTDialerSetBool(effectView, "setHidden:", YES);
    MTDialerSetBool(ringView, "setHidden:", YES);
    MTDialerSetObject(button, "setBackgroundColor:",
        MTDialerObjectResult(MTColorClass, "clearColor"));
}

static id MTHookedNewCallButton(id self, SEL selector) {
    id button = MTOriginalNewCallButton(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callButtonCreations,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTDialerObjectMatchesClass(button, MTCallButtonClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return button;
    }
    id originalImage = MTDialerObjectResultForState(
        button, "imageForState:", MTDialerControlStateNormal);
    if (!MTDialerObjectMatchesClass(originalImage, MTImageClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return button;
    }
    id normalImage = MTImageResolver(
        MTDialerCallButtonSubject, originalImage);
    if (!MTDialerObjectMatchesClass(normalImage, MTImageClass)) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.resolverMisses,
            1, memory_order_relaxed);
        return button;
    }
    id pressedImage = MTImageResolver(
        MTDialerCallButtonPressedSubject, originalImage);
    if (!MTDialerObjectMatchesClass(pressedImage, MTImageClass)) {
        pressedImage = normalImage;
    }
    static const MTDialerControlState states[] = {
        MTDialerControlStateNormal,
        MTDialerControlStateHighlighted,
        MTDialerControlStateDisabled,
        MTDialerControlStateSelected,
        MTDialerControlStateHighlighted | MTDialerControlStateSelected,
        MTDialerControlStateDisabled | MTDialerControlStateSelected,
    };
    for (NSUInteger index = 0;
         index < sizeof(states) / sizeof(states[0]); index++) {
        MTDialerSetImageForState(button, normalImage, states[index]);
    }
    MTDialerHideStockCallArtwork(button);
    objc_setAssociatedObject(
        button, &MTCallPressedImageAssociationKey,
        pressedImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callNormalReplacements,
        1, memory_order_relaxed);
    return button;
}

static id MTHookedNewCallOverlay(id self, SEL selector) {
    id original = MTOriginalNewCallOverlay(self, selector);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callOverlayRequests,
        1, memory_order_relaxed);
    id pressedImage = objc_getAssociatedObject(
        self, &MTCallPressedImageAssociationKey);
    if (!MTDialerObjectMatchesClass(pressedImage, MTImageClass)) {
        return original;
    }
    id allocated = MTDialerObjectResult(MTImageViewClass, "alloc");
    id replacement = ((id (*)(id, SEL, CGRect))objc_msgSend)(
        allocated, sel_registerName("initWithFrame:"), MTDialerBounds(self));
    if (replacement == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerButtonAdapterObservation.contractRejects,
            1, memory_order_relaxed);
        return original;
    }
    MTDialerSetObject(replacement, "setImage:", pressedImage);
    MTDialerSetObject(replacement, "setBackgroundColor:",
        MTDialerObjectResult(MTColorClass, "clearColor"));
    MTDialerSetInteger(
        replacement, "setContentMode:", MTDialerContentModeCenter);
    MTDialerSetUnsignedInteger(replacement, "setAutoresizingMask:",
        MTDialerAutoresizingFlexibleWidth |
            MTDialerAutoresizingFlexibleHeight);
    MTDialerSetBool(replacement, "setUserInteractionEnabled:", NO);
    MTDialerSetBool(replacement, "setIsAccessibilityElement:", NO);
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.callPressedReplacements,
        1, memory_order_relaxed);
    return replacement;
}

static void MTRecordMethodContract(NSString *name,
                                   Method method,
                                   const char *typeEncoding) {
    MTRuntimeABIReportProbeMethodType(
        MTAdapterID, [@"encoding:" stringByAppendingString:name],
        method, typeEncoding);
    MTRuntimeABIReportProbeImplementation(
        MTAdapterID, [@"implementation:" stringByAppendingString:name],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTRejectInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeDialerButtonAdapterObservation.state,
        MTDialerButtonAdapterStateRejected,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTDialerButtonAdapterStateRejected, @"Rejected");
}

static void MTDialerAttemptInstallation(void) {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerButtonAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class numberButtonClass = objc_getClass(MTNumberButtonClassName);
    Class dynamicButtonClass = objc_getClass(
        MTNumberButtonDynamicClassName);
    Class baseButtonClass = objc_getClass(MTNumberButtonBaseClassName);
    Class dialerViewClass = objc_getClass(MTDialerViewClassName);
    Class callButtonClass = objc_getClass(MTCallButtonClassName);
    Class buttonClass = objc_getClass(MTButtonClassName);
    Class imageClass = objc_getClass(MTImageClassName);
    Class imageViewClass = objc_getClass(MTImageViewClassName);
    Class colorClass = objc_getClass(MTColorClassName);
    if (numberButtonClass == Nil || dynamicButtonClass == Nil ||
        baseButtonClass == Nil || dialerViewClass == Nil ||
        callButtonClass == Nil || buttonClass == Nil || imageClass == Nil ||
        imageViewClass == Nil || colorClass == Nil) {
        MTRejectInstallation();
        return;
    }

    SEL numberSourceSelector = sel_registerName(
        MTNumberImageSourceSelectorName);
    SEL unhighlightedAlphaSelector = sel_registerName(
        MTUnhighlightedCircleAlphaSelectorName);
    SEL highlightedAlphaSelector = sel_registerName(
        MTHighlightedCircleAlphaSelectorName);
    SEL newCallButtonSelector = sel_registerName(
        MTNewCallButtonSelectorName);
    SEL newCallOverlaySelector = sel_registerName(
        MTNewCallOverlaySelectorName);
    Method numberSourceMethod = class_getClassMethod(
        numberButtonClass, numberSourceSelector);
    Method unhighlightedAlphaMethod = class_getClassMethod(
        numberButtonClass, unhighlightedAlphaSelector);
    Method highlightedAlphaMethod = class_getClassMethod(
        numberButtonClass, highlightedAlphaSelector);
    Method newCallButtonMethod = class_getInstanceMethod(
        dialerViewClass, newCallButtonSelector);
    Method newCallOverlayMethod = class_getInstanceMethod(
        callButtonClass, newCallOverlaySelector);
    Method roundViewMethod = class_getInstanceMethod(
        callButtonClass, sel_registerName(MTRoundViewSelectorName));
    Method effectViewMethod = class_getInstanceMethod(
        callButtonClass, sel_registerName(MTEffectViewSelectorName));
    Method ringViewMethod = class_getInstanceMethod(
        callButtonClass, sel_registerName(MTRingViewSelectorName));

    Class classes[] = {
        numberButtonClass, dynamicButtonClass, baseButtonClass,
        dialerViewClass, callButtonClass,
    };
    NSString *classNames[] = {
        @"PHHandsetDialerNumberPadButton", @"TPNumberPadDynamicButton",
        @"TPNumberPadButton", @"PHHandsetDialerView",
        @"PHBottomBarButton",
    };
    BOOL classImages[] = {
        MTMobilePhoneDialerClassMatchesExpectedImage(numberButtonClass),
        MTTelephonyUIDialerClassMatchesExpectedImage(dynamicButtonClass),
        MTTelephonyUIDialerClassMatchesExpectedImage(baseButtonClass),
        MTMobilePhoneDialerClassMatchesExpectedImage(dialerViewClass),
        MTMobilePhoneDialerClassMatchesExpectedImage(callButtonClass),
    };
    NSString *expectedImages[] = {
        @"MobilePhone", @"TelephonyUI", @"TelephonyUI",
        @"MobilePhone", @"MobilePhone",
    };
    BOOL valid = YES;
    for (NSUInteger index = 0; index < 5; index++) {
        MTRuntimeABIReportProbePresence(
            MTAdapterID,
            [@"class:" stringByAppendingString:classNames[index]], YES);
        MTRuntimeABIReportRecordContract(
            MTAdapterID,
            [@"image:" stringByAppendingString:classNames[index]],
            classImages[index], expectedImages[index],
            MTReportImageName(classes[index]));
        valid = valid && classImages[index];
    }

    BOOL immediateDynamicSuperclass =
        class_getSuperclass(numberButtonClass) == dynamicButtonClass;
    BOOL dynamicInheritsBase = MTDialerClassIsSubclassOfClass(
        dynamicButtonClass, baseButtonClass);
    BOOL callButtonInheritsButton = MTDialerClassIsSubclassOfClass(
        callButtonClass, buttonClass);
    MTRuntimeABIReportRecordContract(
        MTAdapterID,
        @"superclass:PHHandsetDialerNumberPadButton",
        immediateDynamicSuperclass,
        @"TPNumberPadDynamicButton",
        class_getSuperclass(numberButtonClass) == Nil ? nil :
            @(class_getName(class_getSuperclass(numberButtonClass))));
    MTRuntimeABIReportRecordContract(
        MTAdapterID,
        @"superclass:TPNumberPadDynamicButton",
        dynamicInheritsBase,
        @"inherits TPNumberPadButton",
        class_getSuperclass(dynamicButtonClass) == Nil ? nil :
            @(class_getName(class_getSuperclass(dynamicButtonClass))));
    MTRuntimeABIReportRecordContract(
        MTAdapterID,
        @"superclass:PHBottomBarButton",
        callButtonInheritsButton,
        @"inherits UIButton",
        class_getSuperclass(callButtonClass) == Nil ? nil :
            @(class_getName(class_getSuperclass(callButtonClass))));
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIImage", imageClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIImageView", imageViewClass != Nil);
    MTRuntimeABIReportProbePresence(
        MTAdapterID, @"class:UIColor", colorClass != Nil);

    MTRecordMethodContract(
        @"PHHandsetDialerNumberPadButton."
         "imageForCharacter:highlighted:whiteVersion:",
        numberSourceMethod, MTNumberImageSourceTypeEncoding);
    MTRecordMethodContract(
        @"PHHandsetDialerNumberPadButton."
         "unhighlightedCircleViewAlpha",
        unhighlightedAlphaMethod, MTCircleAlphaTypeEncoding);
    MTRecordMethodContract(
        @"PHHandsetDialerNumberPadButton."
         "highlightedCircleViewAlpha",
        highlightedAlphaMethod, MTCircleAlphaTypeEncoding);
    MTRecordMethodContract(
        @"PHHandsetDialerView.newCallButton",
        newCallButtonMethod, MTObjectResultTypeEncoding);
    MTRecordMethodContract(
        @"PHBottomBarButton.newOverlayView",
        newCallOverlayMethod, MTObjectResultTypeEncoding);
    MTRecordMethodContract(
        @"PHBottomBarButton.roundView",
        roundViewMethod, MTObjectResultTypeEncoding);
    MTRecordMethodContract(
        @"PHBottomBarButton.effectView",
        effectViewMethod, MTObjectResultTypeEncoding);
    MTRecordMethodContract(
        @"PHBottomBarButton.ringView",
        ringViewMethod, MTObjectResultTypeEncoding);

    valid = valid && immediateDynamicSuperclass && dynamicInheritsBase &&
        callButtonInheritsButton &&
        MTDialerMethodMatches(numberSourceMethod,
            MTNumberImageSourceTypeEncoding, NO) &&
        MTDialerMethodMatches(unhighlightedAlphaMethod,
            MTCircleAlphaTypeEncoding, NO) &&
        MTDialerMethodMatches(highlightedAlphaMethod,
            MTCircleAlphaTypeEncoding, NO) &&
        MTDialerMethodMatches(newCallButtonMethod,
            MTObjectResultTypeEncoding, YES) &&
        MTDialerMethodMatches(newCallOverlayMethod,
            MTObjectResultTypeEncoding, YES) &&
        MTDialerMethodMatches(roundViewMethod,
            MTObjectResultTypeEncoding, YES) &&
        MTDialerMethodMatches(effectViewMethod,
            MTObjectResultTypeEncoding, YES) &&
        MTDialerMethodMatches(ringViewMethod,
            MTObjectResultTypeEncoding, YES);
    if (!valid) {
        MTRejectInstallation();
        return;
    }

    MTCallButtonClass = callButtonClass;
    MTImageClass = imageClass;
    MTImageViewClass = imageViewClass;
    MTColorClass = colorClass;
    MTOriginalNumberImageSource = (MTNumberImageSourceFunction)
        method_getImplementation(numberSourceMethod);
    MTOriginalUnhighlightedCircleAlpha = (MTCircleAlphaFunction)
        method_getImplementation(unhighlightedAlphaMethod);
    MTOriginalHighlightedCircleAlpha = (MTCircleAlphaFunction)
        method_getImplementation(highlightedAlphaMethod);
    MTOriginalNewCallButton = (MTObjectResultFunction)
        method_getImplementation(newCallButtonMethod);
    MTOriginalNewCallOverlay = (MTObjectResultFunction)
        method_getImplementation(newCallOverlayMethod);
    Class numberMetaClass = object_getClass(numberButtonClass);
    MSHookMessageEx(
        numberMetaClass, numberSourceSelector,
        (IMP)MTHookedNumberImageSource,
        (IMP *)&MTOriginalNumberImageSource);
    MSHookMessageEx(
        numberMetaClass, unhighlightedAlphaSelector,
        (IMP)MTHookedUnhighlightedCircleAlpha,
        (IMP *)&MTOriginalUnhighlightedCircleAlpha);
    MSHookMessageEx(
        numberMetaClass, highlightedAlphaSelector,
        (IMP)MTHookedHighlightedCircleAlpha,
        (IMP *)&MTOriginalHighlightedCircleAlpha);
    MSHookMessageEx(
        dialerViewClass, newCallButtonSelector,
        (IMP)MTHookedNewCallButton,
        (IMP *)&MTOriginalNewCallButton);
    MSHookMessageEx(
        callButtonClass, newCallOverlaySelector,
        (IMP)MTHookedNewCallOverlay,
        (IMP *)&MTOriginalNewCallOverlay);
    if (MTOriginalNumberImageSource == NULL ||
        MTOriginalUnhighlightedCircleAlpha == NULL ||
        MTOriginalHighlightedCircleAlpha == NULL ||
        MTOriginalNewCallButton == NULL ||
        MTOriginalNewCallOverlay == NULL) {
        MTRejectInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeDialerButtonAdapterObservation.state,
        MTDialerButtonAdapterStateInstalled,
        memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTDialerButtonAdapterStateInstalled, @"Installed");
}

BOOL MTDialerButtonAdapterSchedule(
    MTDialerImageResolver resolver,
    MTDialerCompleteNumberSetResolver completeNumberSetResolver,
    MTDialerButtonPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || completeNumberSetResolver == NULL ||
        preparation == NULL) {
        return NO;
    }
    uint32_t expected = MTDialerButtonAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeDialerButtonAdapterObservation.state,
            &expected, MTDialerButtonAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTDialerButtonAdapterStateScheduled ||
            expected == MTDialerButtonAdapterStateInstalled;
    }
    MTImageResolver = resolver;
    MTCompleteNumberSetResolver = completeNumberSetResolver;
    MTPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTAdapterID, MTDialerButtonAdapterStateScheduled, @"Scheduled");
    // The new Module preparation is Foundation-only and synchronous. Running
    // it before registration removes the old image-ready race without reading
    // any UIKit singleton or constructing a display object.
    if (!MTPreparation()) {
        MTRejectInstallation();
        return NO;
    }
    MTDialerAttemptInstallation();
    return atomic_load_explicit(
        &MTRuntimeDialerButtonAdapterObservation.state,
        memory_order_acquire) == MTDialerButtonAdapterStateInstalled;
}
