#import "MTPreferencesGraphicIconAdapter.h"

#import <CydiaSubstrate/CydiaSubstrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#include <stdbool.h>
#include <string.h>

#import "MTPreferencesGraphicIconContract.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeImageABI.h"

static NSString *const MTAdapterID = @"preferences.graphic-icon-image";
static const char *const MTIconServicesPath =
    "/System/Library/PrivateFrameworks/IconServices.framework/IconServices";

typedef id (*MTObjectGetter)(id, SEL);
typedef id (*MTImageForDescriptor)(id, SEL, id);
typedef void (*MTGetImageForDescriptor)(id, SEL, id, id);

MTPreferencesGraphicIconAdapterObservation
    MTRuntimePreferencesGraphicIconAdapterObservation = {
        .schemaVersion = 1,
        .state = ATOMIC_VAR_INIT(MTPreferencesGraphicIconAdapterStateDormant),
    };

_Static_assert(sizeof(MTPreferencesGraphicIconAdapterObservation) == 56,
    "Preferences GraphicIcon observation ABI changed");

static MTImageForDescriptor MTOriginalImageForDescriptor;
static MTGetImageForDescriptor MTOriginalGetImageForDescriptor;
static MTPreferencesGraphicIconResolver MTResolver;
static MTRuntimeReplacementPreparation MTPreparation;
static Class MTTypeIconClass;
static MTObjectGetter MTTypeGetter;
static SEL MTTypeSelector;
static _Atomic(bool) MTInstallPassScheduled = false;

static void MTSetState(MTPreferencesGraphicIconAdapterState state) {
    atomic_store_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.state,
        state, memory_order_release);
    NSString *name = state == MTPreferencesGraphicIconAdapterStateInstalled
        ? @"Installed" : state == MTPreferencesGraphicIconAdapterStateScheduled
        ? @"Scheduled" : @"Rejected";
    MTRuntimeABIReportRecordAdapterState(MTAdapterID, state, name);
}

static BOOL MTIsInstalled(void) {
    return atomic_load_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.state,
        memory_order_acquire) == MTPreferencesGraphicIconAdapterStateInstalled;
}

static NSString *MTGraphicType(id icon) {
    if (!MTIsInstalled() || object_getClass(icon) != MTTypeIconClass) return nil;
    id type = MTTypeGetter(icon, MTTypeSelector);
    if (!MTPreferencesGraphicIconTypeIsSupported(type)) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.identityResults,
        1, memory_order_relaxed);
    return [type copy];
}

static id MTResolveImage(NSString *type, id image, id descriptor) {
    if (image == nil || !MTIsInstalled()) return image;
    id replacement = MTResolver(type, image, descriptor);
    if (replacement == nil || replacement == image) return image;
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.replacementResults,
        1, memory_order_relaxed);
    return replacement;
}

static id MTHookedImageForDescriptor(id self, SEL selector, id descriptor) {
    id original = MTOriginalImageForDescriptor(self, selector, descriptor);
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.synchronousCalls,
        1, memory_order_relaxed);
    NSString *type = MTGraphicType(self);
    return type == nil ? original : MTResolveImage(type, original, descriptor);
}

static void MTHookedGetImageForDescriptor(
    id self, SEL selector, id descriptor, id completion) {
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.asynchronousCalls,
        1, memory_order_relaxed);
    NSString *type = MTGraphicType(self);
    if (type == nil) {
        MTOriginalGetImageForDescriptor(self, selector, descriptor, completion);
        return;
    }
    id wrapped = MTPreferencesGraphicIconWrapCompletion(
        completion, ^id(id original) {
            return MTResolveImage(type, original, descriptor);
        });
    if (wrapped == completion) {
        atomic_fetch_add_explicit(
            &MTRuntimePreferencesGraphicIconAdapterObservation
                .unsupportedCompletions,
            1, memory_order_relaxed);
    }
    // Do not dispatch or synthesize a completion. The original controls the
    // execution queue, lifetime, callback count, nil results and errors.
    MTOriginalGetImageForDescriptor(self, selector, descriptor, wrapped);
}

static Method MTValidatedMethod(Class cls, const char *name,
                                const char *encoding) {
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    BOOL classMatches = MTRuntimeClassMatchesImagePath(cls, MTIconServicesPath);
    MTRuntimeABIReportRecordContract(
        MTAdapterID, [NSString stringWithFormat:@"image:%s", class_getName(cls)],
        classMatches, @(MTIconServicesPath),
        class_getImageName(cls) == NULL ? nil : @(class_getImageName(cls)));
    NSString *label = [NSString stringWithFormat:@"%s.%s", class_getName(cls), name];
    MTRuntimeABIReportProbeMethodType(MTAdapterID, label, method, encoding);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    MTRuntimeABIReportProbeImplementation(MTAdapterID, label, implementation);
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return classMatches && actual != NULL && strcmp(actual, encoding) == 0 &&
        MTRuntimeImplementationResolves(implementation) ? method : NULL;
}

static void MTAttemptInstallation(void);

static void MTScheduleInstallPass(void) {
    if (atomic_load_explicit(
            &MTRuntimePreferencesGraphicIconAdapterObservation.state,
            memory_order_acquire) != MTPreferencesGraphicIconAdapterStateScheduled) {
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &MTInstallPassScheduled, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(&MTInstallPassScheduled, false, memory_order_release);
        MTAttemptInstallation();
    });
}

static void MTRuntimeImageAdded(const struct mach_header *header, intptr_t slide) {
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
            &MTRuntimePreferencesGraphicIconAdapterObservation.state,
            memory_order_acquire) != MTPreferencesGraphicIconAdapterStateScheduled) {
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimePreferencesGraphicIconAdapterObservation.installAttempts,
        1, memory_order_relaxed);
    Class concrete = objc_getClass("ISConcreteIcon");
    Class typeIcon = objc_getClass("ISTypeIcon");
    if (concrete == Nil || typeIcon == Nil || objc_getClass("IFImage") == Nil ||
        objc_getClass("ISImageDescriptor") == Nil) return;
    Method sync = MTValidatedMethod(concrete, "imageForDescriptor:", "@24@0:8@16");
    Method async = MTValidatedMethod(concrete,
        "getImageForImageDescriptor:completion:", "v32@0:8@16@?24");
    Method type = MTValidatedMethod(typeIcon, "type", "@16@0:8");
    // Only the proven inherited dispatch path is accepted. A version that
    // overrides either method on ISTypeIcon requires fresh evidence.
    if (sync == NULL || async == NULL || type == NULL ||
        class_getInstanceMethod(typeIcon, method_getName(sync)) != sync ||
        class_getInstanceMethod(typeIcon, method_getName(async)) != async ||
        !MTPreparation()) {
        MTSetState(MTPreferencesGraphicIconAdapterStateRejected);
        return;
    }
    MTTypeIconClass = typeIcon;
    MTTypeGetter = (MTObjectGetter)method_getImplementation(type);
    MTTypeSelector = method_getName(type);
    IMP originalSync = method_getImplementation(sync);
    IMP originalAsync = method_getImplementation(async);
    MTOriginalImageForDescriptor = (MTImageForDescriptor)originalSync;
    MTOriginalGetImageForDescriptor = (MTGetImageForDescriptor)originalAsync;
    MSHookMessageEx(concrete, method_getName(sync),
        (IMP)MTHookedImageForDescriptor, (IMP *)&MTOriginalImageForDescriptor);
    MSHookMessageEx(concrete, method_getName(async),
        (IMP)MTHookedGetImageForDescriptor, (IMP *)&MTOriginalGetImageForDescriptor);
    if (MTOriginalImageForDescriptor == NULL ||
        MTOriginalGetImageForDescriptor == NULL) {
        // Even a rejected partial installation must retain a callable
        // original for either hook that Substrate has already installed.
        if (MTOriginalImageForDescriptor == NULL)
            MTOriginalImageForDescriptor = (MTImageForDescriptor)originalSync;
        if (MTOriginalGetImageForDescriptor == NULL)
            MTOriginalGetImageForDescriptor = (MTGetImageForDescriptor)originalAsync;
        MTSetState(MTPreferencesGraphicIconAdapterStateRejected);
        return;
    }
    MTSetState(MTPreferencesGraphicIconAdapterStateInstalled);
}

BOOL MTPreferencesGraphicIconAdapterSchedule(
    MTPreferencesGraphicIconResolver resolver,
    MTRuntimeReplacementPreparation preparation,
    NSError **error) {
    if (error != NULL) *error = nil;
    if (resolver == NULL || preparation == NULL ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"] ||
        ![NSProcessInfo.processInfo.processName isEqualToString:@"Preferences"]) {
        return NO;
    }
    uint32_t expected = MTPreferencesGraphicIconAdapterStateDormant;
    if (!atomic_compare_exchange_strong_explicit(
            &MTRuntimePreferencesGraphicIconAdapterObservation.state,
            &expected, MTPreferencesGraphicIconAdapterStateScheduled,
            memory_order_acq_rel, memory_order_acquire)) {
        return expected == MTPreferencesGraphicIconAdapterStateScheduled ||
            expected == MTPreferencesGraphicIconAdapterStateInstalled;
    }
    MTResolver = resolver;
    MTPreparation = preparation;
    MTSetState(MTPreferencesGraphicIconAdapterStateScheduled);
    _dyld_register_func_for_add_image(MTRuntimeImageAdded);
    if ([NSThread isMainThread]) MTAttemptInstallation();
    else MTScheduleInstallPass();
    return YES;
}
