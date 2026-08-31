#import "MTShareSheetActivityGlyphAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"
#import "MTShareSheetABI.h"
#import "MTShareSheetActivityIdentity.h"

static NSString *const MTShareGlyphAdapterID =
    @"share-sheet.activity-glyph";

static const char *const MTProviderClassName =
    "SFUIActivityImageProvider";
static const char *const MTProviderBaseClassName = "SFUIImageProvider";
static const char *const MTRequestClassName = "SFUIActivityImageRequest";
static const char *const MTUIActivityClassName = "UIActivity";
static const char *const MTProxyClassName = "SUIHostActivityProxy";

static const char *const MTProviderRequestSelectorName =
    "performImageRequest:";
static const char *const MTProviderDeliverySelectorName =
    "deliverImage:identifier:placeholder:error:";
static const char *const MTRequestActivitySelectorName = "activity";
static const char *const MTRequestIdentifierSelectorName = "identifier";
static const char *const MTNativeApplicationImageSelectorName =
    "_activityImageForApplicationBundleIdentifier:";

static const char *const MTProviderRequestTypeEncoding = "v24@0:8@16";
static const char *const MTProviderDeliveryTypeEncoding =
    "v44@0:8@16@24B32@36";
static const char *const MTObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTApplicationImageTypeEncoding = "@24@0:8@16";

static const char *const MTSharingUIImagePath =
    "/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI";

typedef void (*MTProviderRequestFunction)(id, SEL, id);
typedef void (*MTProviderDeliveryFunction)(id, SEL, id, id, BOOL, id);
typedef id (*MTObjectGetterFunction)(id, SEL);
typedef id (*MTApplicationImageFunction)(id, SEL, id);

typedef NS_ENUM(uint32_t, MTShareGlyphState) {
    MTShareGlyphStateDormant = 0,
    MTShareGlyphStateScheduled = 1,
    MTShareGlyphStateInstalled = 2,
    MTShareGlyphStateRejected = 10,
};

MTShareSheetActivityGlyphAdapterObservation
    MTRuntimeShareSheetActivityGlyphAdapterObservation = {
        .schemaVersion = 3,
        .state = ATOMIC_VAR_INIT(MTShareGlyphStateDormant),
        .installAttempts = ATOMIC_VAR_INIT(0),
        .requestCalls = ATOMIC_VAR_INIT(0),
        .deliveryCalls = ATOMIC_VAR_INIT(0),
        .applicationContexts = ATOMIC_VAR_INIT(0),
        .customContexts = ATOMIC_VAR_INIT(0),
        .nativeApplicationBridgeResults = ATOMIC_VAR_INIT(0),
        .replacements = ATOMIC_VAR_INIT(0),
        .providersTracked = ATOMIC_VAR_INIT(0),
        .contextMisses = ATOMIC_VAR_INIT(0),
        .contractRejects = ATOMIC_VAR_INIT(0),
    };

_Static_assert(sizeof(MTShareSheetActivityGlyphAdapterObservation) == 88,
    "Share Sheet provider-source observation ABI changed");

@interface MTShareSheetDeliveryContext : NSObject
@property(nonatomic, copy, nullable) NSString *applicationBundleIdentifier;
@property(nonatomic, copy, nullable) NSString *activityIdentity;
@end

@implementation MTShareSheetDeliveryContext
@end

static char MTShareSheetDeliveryContextsKey;
static Class MTProviderClass;
static Class MTRequestClass;
static Class MTProxyClass;
static Class MTActivityClass;
static Class MTImageClass;
static SEL MTRequestActivitySelector;
static SEL MTRequestIdentifierSelector;
static SEL MTNativeApplicationImageSelector;
static MTProviderRequestFunction MTOriginalProviderRequest;
static MTProviderDeliveryFunction MTOriginalProviderDelivery;
static MTObjectGetterFunction MTRequestActivity;
static MTObjectGetterFunction MTRequestIdentifier;
static MTApplicationImageFunction MTNativeApplicationImage;
static MTRuntimeReplacementResolver MTGlyphResolver;
static MTRuntimeReplacementPreparation MTGlyphPreparation;
static BOOL MTPreparationComplete;
static _Atomic(bool) MTInstallPassScheduled = false;

static BOOL MTClassIsSubclassOfClass(Class candidate, Class expected) {
    if (candidate == Nil || expected == Nil) return NO;
    for (Class current = candidate;
         current != Nil;
         current = class_getSuperclass(current)) {
        if (current == expected) return YES;
    }
    return NO;
}

static NSString *MTClassImageName(Class runtimeClass) {
    const char *imageName = runtimeClass == Nil
        ? NULL : class_getImageName(runtimeClass);
    return imageName == NULL ? nil : @(imageName);
}

static BOOL MTMethodHasEncoding(Method method,
                                const char *encoding) {
    const char *actual = method == NULL
        ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, encoding) == 0;
}

static BOOL MTSharingUIMethodIsHookable(Method method,
                                       const char *encoding) {
    if (!MTMethodHasEncoding(method, encoding)) return NO;
    IMP implementation = method_getImplementation(method);
    return MTRuntimeImplementationMatchesImage(
               implementation, MTSharingUIImagePath) ||
        MTRuntimeImplementationResolves(implementation);
}

static BOOL MTShareSheetMethodIsHookable(Method method,
                                        const char *encoding) {
    return MTMethodHasEncoding(method, encoding) &&
        MTShareSheetImplementationMatchesExpectedImage(
            method_getImplementation(method));
}

static NSMutableDictionary<NSString *, MTShareSheetDeliveryContext *> *
MTDeliveryContexts(id provider, BOOL create) {
    NSMutableDictionary *contexts = objc_getAssociatedObject(
        provider, &MTShareSheetDeliveryContextsKey);
    if (contexts != nil || !create) return contexts;
    contexts = [NSMutableDictionary dictionaryWithCapacity:8];
    objc_setAssociatedObject(
        provider, &MTShareSheetDeliveryContextsKey, contexts,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return contexts;
}

static MTShareSheetDeliveryContext *MTContextForActivity(id activity) {
    if (activity == nil) return nil;
    NSString *activityIdentity = nil;
    NSString *bundleIdentifier = nil;
    if (MTProxyClass != Nil && [activity isKindOfClass:MTProxyClass]) {
        bundleIdentifier =
            MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
                activity, &activityIdentity);
    } else {
        bundleIdentifier =
            MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
                activity, &activityIdentity);
    }
    if (bundleIdentifier.length == 0 && activityIdentity.length == 0) {
        return nil;
    }
    MTShareSheetDeliveryContext *context =
        [[MTShareSheetDeliveryContext alloc] init];
    context.applicationBundleIdentifier = bundleIdentifier;
    context.activityIdentity = activityIdentity;
    atomic_fetch_add_explicit(
        bundleIdentifier.length > 0
            ? &MTRuntimeShareSheetActivityGlyphAdapterObservation
                   .applicationContexts
            : &MTRuntimeShareSheetActivityGlyphAdapterObservation
                   .customContexts,
        1, memory_order_relaxed);
    return context;
}

static void MTHookedProviderRequest(id self, SEL selector, id request) {
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.requestCalls,
        1, memory_order_relaxed);
    BOOL validProvider = MTProviderClass != Nil &&
        [self isKindOfClass:MTProviderClass];
    BOOL validRequest = MTRequestClass != Nil &&
        [request isKindOfClass:MTRequestClass];
    if (!validProvider || !validRequest ||
        MTRequestActivity == NULL || MTRequestIdentifier == NULL) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation
                 .contractRejects,
            1, memory_order_relaxed);
        MTOriginalProviderRequest(self, selector, request);
        return;
    }

    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.providersTracked,
        1, memory_order_relaxed);

    id identifierValue = MTRequestIdentifier(
        request, MTRequestIdentifierSelector);
    id activity = MTRequestActivity(request, MTRequestActivitySelector);
    if ([identifierValue isKindOfClass:NSString.class] && activity != nil) {
        MTShareSheetDeliveryContext *context = MTContextForActivity(activity);
        if (context != nil) {
            @synchronized (self) {
                MTDeliveryContexts(self, YES)[identifierValue] = context;
            }
        } else {
            atomic_fetch_add_explicit(
                &MTRuntimeShareSheetActivityGlyphAdapterObservation
                     .contextMisses,
                1, memory_order_relaxed);
        }
    }
    MTOriginalProviderRequest(self, selector, request);
}

static id MTReplacementForDelivery(
    MTShareSheetDeliveryContext *context,
    id originalImage) {
    if (context.applicationBundleIdentifier.length > 0) {
        id nativeImage = MTNativeApplicationImage == NULL ? nil :
            MTNativeApplicationImage(
                MTActivityClass, MTNativeApplicationImageSelector,
                context.applicationBundleIdentifier);
        if (MTImageClass != Nil &&
            [nativeImage isKindOfClass:MTImageClass]) {
            atomic_fetch_add_explicit(
                &MTRuntimeShareSheetActivityGlyphAdapterObservation
                     .nativeApplicationBridgeResults,
                1, memory_order_relaxed);
            return nativeImage;
        }
        return originalImage;
    }
    if (context.activityIdentity.length == 0 ||
        MTImageClass == Nil ||
        ![originalImage isKindOfClass:MTImageClass]) {
        return originalImage;
    }
    BOOL replaced = NO;
    id result = MTRuntimeResultByApplyingReplacementResolver(
        context.activityIdentity, originalImage, MTGlyphResolver, &replaced);
    if (replaced) {
        atomic_fetch_add_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.replacements,
            1, memory_order_relaxed);
    }
    return result;
}

static void MTHookedProviderDelivery(id self,
                                     SEL selector,
                                     id image,
                                     id identifier,
                                     BOOL placeholder,
                                     id error) {
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.deliveryCalls,
        1, memory_order_relaxed);
    MTShareSheetDeliveryContext *context = nil;
    if ([identifier isKindOfClass:NSString.class]) {
        @synchronized (self) {
            NSMutableDictionary *contexts = MTDeliveryContexts(self, NO);
            context = contexts[identifier];
            if (!placeholder || error != nil) {
                [contexts removeObjectForKey:identifier];
            }
        }
    }
    id result = context == nil
        ? image : MTReplacementForDelivery(context, image);
    MTOriginalProviderDelivery(
        self, selector, result, identifier, placeholder, error);
}

static void MTRecordMethodContract(NSString *name,
                                   Method method,
                                   const char *encoding) {
    MTRuntimeABIReportProbeMethodType(
        MTShareGlyphAdapterID,
        [@"encoding:" stringByAppendingString:name],
        method, encoding);
    MTRuntimeABIReportProbeImplementation(
        MTShareGlyphAdapterID,
        [@"implementation:" stringByAppendingString:name],
        method == NULL ? NULL : method_getImplementation(method));
}

static void MTRejectInstallation(void) {
    atomic_store_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
        MTShareGlyphStateRejected, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTShareGlyphAdapterID,
        MTShareGlyphStateRejected, @"Rejected");
}

static BOOL MTPrepareIfNeeded(void) {
    if (MTPreparationComplete) return YES;
    MTPreparationComplete = MTGlyphPreparation != NULL &&
        MTGlyphPreparation();
    return MTPreparationComplete;
}

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            memory_order_acquire) != MTShareGlyphStateScheduled) {
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
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            memory_order_acquire) != MTShareGlyphStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.installAttempts,
        1, memory_order_relaxed);

    Class providerClass = objc_getClass(MTProviderClassName);
    Class providerBaseClass = objc_getClass(MTProviderBaseClassName);
    Class requestClass = objc_getClass(MTRequestClassName);
    Class activityClass = objc_getClass(MTUIActivityClassName);
    Class proxyClass = objc_getClass(MTProxyClassName);
    Class imageClass = objc_getClass("UIImage");
    if (providerClass == Nil || providerBaseClass == Nil ||
        requestClass == Nil || activityClass == Nil || proxyClass == Nil ||
        imageClass == Nil) {
        return;
    }

    SEL requestSelector = sel_registerName(
        MTProviderRequestSelectorName);
    SEL deliverySelector = sel_registerName(
        MTProviderDeliverySelectorName);
    SEL activitySelector = sel_registerName(
        MTRequestActivitySelectorName);
    SEL identifierSelector = sel_registerName(
        MTRequestIdentifierSelectorName);
    SEL nativeImageSelector = sel_registerName(
        MTNativeApplicationImageSelectorName);
    Method requestMethod = class_getInstanceMethod(
        providerClass, requestSelector);
    Method deliveryMethod = class_getInstanceMethod(
        providerClass, deliverySelector);
    Method activityMethod = class_getInstanceMethod(
        requestClass, activitySelector);
    Method identifierMethod = class_getInstanceMethod(
        requestClass, identifierSelector);
    Method nativeImageMethod = class_getClassMethod(
        activityClass, nativeImageSelector);

    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID, @"image:SFUIActivityImageProvider",
        MTRuntimeClassMatchesImagePath(
            providerClass, MTSharingUIImagePath),
        @"SharingUI", MTClassImageName(providerClass));
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID, @"image:SFUIImageProvider",
        MTRuntimeClassMatchesImagePath(
            providerBaseClass, MTSharingUIImagePath),
        @"SharingUI", MTClassImageName(providerBaseClass));
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID, @"image:SFUIActivityImageRequest",
        MTRuntimeClassMatchesImagePath(
            requestClass, MTSharingUIImagePath),
        @"SharingUI", MTClassImageName(requestClass));
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID, @"image:UIActivity",
        MTShareSheetClassMatchesExpectedImage(activityClass),
        @"ShareSheet", MTClassImageName(activityClass));
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID, @"image:SUIHostActivityProxy",
        MTShareSheetClassMatchesExpectedImage(proxyClass),
        @"ShareSheet", MTClassImageName(proxyClass));
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID,
        @"hierarchy:SFUIActivityImageProvider<SFUIImageProvider",
        MTClassIsSubclassOfClass(providerClass, providerBaseClass),
        @"matched", MTClassIsSubclassOfClass(
            providerClass, providerBaseClass) ? @"matched" : @"mismatched");
    MTRuntimeABIReportRecordContract(
        MTShareGlyphAdapterID,
        @"hierarchy:SUIHostActivityProxy<UIActivity",
        MTClassIsSubclassOfClass(proxyClass, activityClass),
        @"matched", MTClassIsSubclassOfClass(
            proxyClass, activityClass) ? @"matched" : @"mismatched");
    MTRecordMethodContract(
        @"SFUIActivityImageProvider.performImageRequest:",
        requestMethod, MTProviderRequestTypeEncoding);
    MTRecordMethodContract(
        @"SFUIImageProvider.deliverImage:identifier:placeholder:error:",
        deliveryMethod, MTProviderDeliveryTypeEncoding);
    MTRecordMethodContract(
        @"SFUIActivityImageRequest.activity",
        activityMethod, MTObjectGetterTypeEncoding);
    MTRecordMethodContract(
        @"SFUIImageRequest.identifier",
        identifierMethod, MTObjectGetterTypeEncoding);
    MTRecordMethodContract(
        @"UIActivity._activityImageForApplicationBundleIdentifier:",
        nativeImageMethod, MTApplicationImageTypeEncoding);

    BOOL valid =
        MTRuntimeClassMatchesImagePath(
            providerClass, MTSharingUIImagePath) &&
        MTRuntimeClassMatchesImagePath(
            providerBaseClass, MTSharingUIImagePath) &&
        MTRuntimeClassMatchesImagePath(
            requestClass, MTSharingUIImagePath) &&
        MTShareSheetClassMatchesExpectedImage(activityClass) &&
        MTShareSheetClassMatchesExpectedImage(proxyClass) &&
        MTClassIsSubclassOfClass(providerClass, providerBaseClass) &&
        MTClassIsSubclassOfClass(proxyClass, activityClass) &&
        MTSharingUIMethodIsHookable(
            requestMethod, MTProviderRequestTypeEncoding) &&
        MTSharingUIMethodIsHookable(
            deliveryMethod, MTProviderDeliveryTypeEncoding) &&
        MTSharingUIMethodIsHookable(
            activityMethod, MTObjectGetterTypeEncoding) &&
        MTSharingUIMethodIsHookable(
            identifierMethod, MTObjectGetterTypeEncoding) &&
        MTShareSheetMethodIsHookable(
            nativeImageMethod, MTApplicationImageTypeEncoding) &&
        MTPrepareIfNeeded();
    if (!valid) {
        MTRejectInstallation();
        return;
    }

    MTProviderClass = providerClass;
    MTRequestClass = requestClass;
    MTProxyClass = proxyClass;
    MTActivityClass = activityClass;
    MTImageClass = imageClass;
    MTRequestActivitySelector = activitySelector;
    MTRequestIdentifierSelector = identifierSelector;
    MTNativeApplicationImageSelector = nativeImageSelector;
    MTRequestActivity = (MTObjectGetterFunction)
        method_getImplementation(activityMethod);
    MTRequestIdentifier = (MTObjectGetterFunction)
        method_getImplementation(identifierMethod);
    MTNativeApplicationImage = (MTApplicationImageFunction)
        method_getImplementation(nativeImageMethod);
    MTOriginalProviderRequest = (MTProviderRequestFunction)
        method_getImplementation(requestMethod);
    MTOriginalProviderDelivery = (MTProviderDeliveryFunction)
        method_getImplementation(deliveryMethod);
    MSHookMessageEx(
        providerClass, requestSelector,
        (IMP)MTHookedProviderRequest,
        (IMP *)&MTOriginalProviderRequest);
    MSHookMessageEx(
        providerClass, deliverySelector,
        (IMP)MTHookedProviderDelivery,
        (IMP *)&MTOriginalProviderDelivery);
    if (MTOriginalProviderRequest == NULL ||
        MTOriginalProviderDelivery == NULL ||
        MTRequestActivity == NULL || MTRequestIdentifier == NULL ||
        MTNativeApplicationImage == NULL) {
        MTRejectInstallation();
        return;
    }

    atomic_store_explicit(
        &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
        MTShareGlyphStateInstalled, memory_order_release);
    MTRuntimeABIReportRecordAdapterState(
        MTShareGlyphAdapterID,
        MTShareGlyphStateInstalled, @"Installed");
}

BOOL MTShareSheetActivityGlyphAdapterSchedule(
    MTRuntimeReplacementResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL) return NO;
    uint32_t expected = MTShareGlyphStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimeShareSheetActivityGlyphAdapterObservation.state,
            &expected, MTShareGlyphStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTShareGlyphStateScheduled ||
            expected == MTShareGlyphStateInstalled;
    }
    MTGlyphResolver = resolver;
    MTGlyphPreparation = preparation;
    MTRuntimeABIReportRecordAdapterState(
        MTShareGlyphAdapterID,
        MTShareGlyphStateScheduled, @"Scheduled");
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) MTAttemptInstallation();
    else MTScheduleInstallPass();
    return YES;
}
