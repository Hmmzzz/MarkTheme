#import "MTShareSheetActivityIdentity.h"

#import <objc/runtime.h>

#include <string.h>

static const char *const MTShareSheetObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTShareSheetClassObjectGetterTypeEncoding =
    "@24@0:8@16";
static const char *const MTShareSheetActivityBundleIdentifierGetterName =
    "_bundleIdentifierForActivityImageCreation";
static const char *const MTShareSheetContainingAppBundleIdentifierGetterName =
    "containingAppBundleIdentifier";
static const char *const MTShareSheetActivityBundleHelperGetterName =
    "activityBundleHelper";
static const char *const MTShareSheetBundleProxyGetterName = "bundleProxy";
static const char *const MTShareSheetContainingBundleGetterName =
    "containingBundle";
static const char *const MTShareSheetBundleIdentifierGetterName =
    "bundleIdentifier";
static const char *const MTShareSheetApplicationBundleIdentifierGetterName =
    "applicationBundleIdentifier";
static const char *const MTShareSheetActivityTypeGetterName = "activityType";
static const char *const MTShareSheetFallbackActivityTypeGetterName =
    "fallbackActivityType";
static const char *const MTShareSheetApplicationGetterName = "activity";
static const char *const MTShareSheetPlugInKitProxyClassName =
    "LSPlugInKitProxy";
static const char *const MTShareSheetPlugInKitProxyGetterName =
    "pluginKitProxyForIdentifier:";
static NSString *const MTShareSheetMailActivityIdentity = @"UIMailActivity";
static NSString *const MTShareSheetMessageActivityIdentity =
    @"UIMessageActivity";
static NSString *const MTShareSheetMailBundleIdentifier =
    @"com.apple.mobilemail";
static NSString *const MTShareSheetMessageBundleIdentifier =
    @"com.apple.MobileSMS";
static NSString *const MTShareSheetOpenWithApplicationActivityTypePrefix =
    @"com.apple.UIKit.activity.OpenWithApp-";

static NSString *MTShareSheetCanonicalIdentity(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *identity = [(NSString *)value
        precomposedStringWithCanonicalMapping];
    NSData *utf8 = [identity dataUsingEncoding:NSUTF8StringEncoding
                           allowLossyConversion:NO];
    if (utf8.length == 0 || utf8.length > 192) return nil;
    for (NSUInteger index = 0; index < identity.length; index++) {
        unichar character = [identity characterAtIndex:index];
        if (character == 0 || character == '/' || character == '\\' ||
            character < 0x20 || character == 0x7f) {
            return nil;
        }
    }
    return identity;
}

static id MTShareSheetInvokeObjectGetter(id object, const char *name) {
    if (object == nil || name == NULL) return nil;
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *typeEncoding = method == NULL
        ? NULL
        : method_getTypeEncoding(method);
    if (typeEncoding == NULL ||
        strcmp(typeEncoding, MTShareSheetObjectGetterTypeEncoding) != 0) {
        return nil;
    }
    IMP implementation = method_getImplementation(method);
    if (implementation == NULL) return nil;
    return ((id (*)(id, SEL))implementation)(object, selector);
}

static id MTShareSheetInvokeClassObjectGetter(Class runtimeClass,
                                              const char *name,
                                              id argument) {
    if (runtimeClass == Nil || name == NULL || argument == nil) return nil;
    SEL selector = sel_registerName(name);
    Method method = class_getClassMethod(runtimeClass, selector);
    const char *typeEncoding = method == NULL
        ? NULL
        : method_getTypeEncoding(method);
    if (typeEncoding == NULL ||
        strcmp(typeEncoding,
               MTShareSheetClassObjectGetterTypeEncoding) != 0) {
        return nil;
    }
    IMP implementation = method_getImplementation(method);
    if (implementation == NULL) return nil;
    return ((id (*)(id, SEL, id))implementation)(
        runtimeClass, selector, argument);
}

static NSString *MTShareSheetContainingApplicationBundleIdentity(
    NSString *bundleIdentifier) {
    Class plugInKitProxyClass =
        objc_getClass(MTShareSheetPlugInKitProxyClassName);
    id plugInKitProxy = MTShareSheetInvokeClassObjectGetter(
        plugInKitProxyClass,
        MTShareSheetPlugInKitProxyGetterName,
        bundleIdentifier);
    id containingBundle = MTShareSheetInvokeObjectGetter(
        plugInKitProxy, MTShareSheetContainingBundleGetterName);
    NSString *containingIdentifier = MTShareSheetCanonicalIdentity(
        MTShareSheetInvokeObjectGetter(
            containingBundle, MTShareSheetBundleIdentifierGetterName));
    return containingIdentifier ?: bundleIdentifier;
}

NSString *MTShareSheetUIActivityIdentity(id activity) {
    if (activity == nil) return nil;
    return MTShareSheetCanonicalIdentity(
        NSStringFromClass(object_getClass(activity)));
}

NSString *MTShareSheetProxyActivityIdentity(id activityProxy) {
    id configuration = MTShareSheetInvokeObjectGetter(
        activityProxy, "activityConfiguration");
    id className = MTShareSheetInvokeObjectGetter(
        configuration, "activityClassName");
    return MTShareSheetCanonicalIdentity(className);
}

NSString *MTShareSheetActivityTypeIdentity(id activity) {
    return MTShareSheetCanonicalIdentity(MTShareSheetInvokeObjectGetter(
        activity, MTShareSheetActivityTypeGetterName));
}

NSString *MTShareSheetApplicationBundleIdentity(id bundleIdentifier) {
    NSString *identity = MTShareSheetCanonicalIdentity(bundleIdentifier);
    if (identity == nil) return nil;
    // iOS 16's central image provider receives a Share extension identifier,
    // while SnowBoard-compatible App icon assets are keyed by the containing
    // application's identifier. LaunchServices already owns this exact
    // relationship, so normalize it before entering the static icon resolver.
    return MTShareSheetContainingApplicationBundleIdentity(identity);
}

static NSString *MTShareSheetOpenWithApplicationBundleIdentityForType(
    NSString *activityType) {
    if (![activityType
            hasPrefix:MTShareSheetOpenWithApplicationActivityTypePrefix]) {
        return nil;
    }
    NSString *bundleIdentifier = [activityType substringFromIndex:
        MTShareSheetOpenWithApplicationActivityTypePrefix.length];
    return MTShareSheetApplicationBundleIdentity(bundleIdentifier);
}

static NSString *MTShareSheetOpenWithApplicationBundleIdentity(id activity) {
    NSString *bundleIdentifier =
        MTShareSheetOpenWithApplicationBundleIdentityForType(
            MTShareSheetActivityTypeIdentity(activity));
    if (bundleIdentifier != nil) return bundleIdentifier;
    bundleIdentifier = MTShareSheetOpenWithApplicationBundleIdentityForType(
        MTShareSheetCanonicalIdentity(MTShareSheetInvokeObjectGetter(
            activity, MTShareSheetFallbackActivityTypeGetterName)));
    return bundleIdentifier;
}

NSString *MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
    id activity,
    NSString **activityIdentity) {
    if (activityIdentity != NULL) *activityIdentity = nil;
    NSString *bundleIdentifier = MTShareSheetApplicationBundleIdentity(
        MTShareSheetInvokeObjectGetter(
            activity,
            MTShareSheetApplicationBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    // iOS 16 synthesizes open-document activities as
    // com.apple.UIKit.activity.OpenWithApp-<applicationIdentifier>. The final
    // remote activity proxy retains that type but does not expose the source
    // LSApplicationProxy, which is why sideloaded/jailbreak Apps such as Sileo
    // and Filza cannot be recovered through the ordinary extension path.
    bundleIdentifier =
        MTShareSheetOpenWithApplicationBundleIdentity(activity);
    if (bundleIdentifier != nil) return bundleIdentifier;

    bundleIdentifier = MTShareSheetApplicationBundleIdentity(
        MTShareSheetInvokeObjectGetter(
            activity, MTShareSheetActivityBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    // A compatible UIApplicationExtensionActivity exposes this probed getter. Keep
    // it as a fallback because specialized activities can inherit the base
    // image-creation getter without supplying a result of their own.
    bundleIdentifier = MTShareSheetApplicationBundleIdentity(
        MTShareSheetInvokeObjectGetter(
            activity, MTShareSheetContainingAppBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    // iOS 16's remote/open-in activities can leave both public-to-framework
    // activity getters empty while retaining the exact App identity on the
    // bundle helper used to create their icon. Prefer the containing App for
    // extension bundles, then accept the proxy itself for App-form bundles.
    id helper = MTShareSheetInvokeObjectGetter(
        activity, MTShareSheetActivityBundleHelperGetterName);
    id bundleProxy = MTShareSheetInvokeObjectGetter(
        helper, MTShareSheetBundleProxyGetterName);
    id containingBundle = MTShareSheetInvokeObjectGetter(
        bundleProxy, MTShareSheetContainingBundleGetterName);
    bundleIdentifier = MTShareSheetApplicationBundleIdentity(
        MTShareSheetInvokeObjectGetter(
            containingBundle, MTShareSheetBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;
    bundleIdentifier = MTShareSheetApplicationBundleIdentity(
        MTShareSheetInvokeObjectGetter(
            bundleProxy, MTShareSheetBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    // _UIHostActivityProxy is the iOS 16 in-process representation used by
    // ordinary and Photos share sheets. Its stored activity remains a final
    // exact fallback for callers that hand the proxy itself to this helper.
    id nestedActivity = MTShareSheetInvokeObjectGetter(
        activity, MTShareSheetApplicationGetterName);
    if (nestedActivity != nil && nestedActivity != activity) {
        bundleIdentifier =
            MTShareSheetApplicationBundleIdentityForActivity(nestedActivity);
        if (bundleIdentifier != nil) return bundleIdentifier;
    }

    NSString *resolvedActivityIdentity =
        MTShareSheetUIActivityIdentity(activity);
    if (activityIdentity != NULL) {
        *activityIdentity = resolvedActivityIdentity;
    }
    return MTShareSheetApplicationBundleIdentityForActivityIdentity(
        resolvedActivityIdentity);
}

NSString *MTShareSheetApplicationBundleIdentityForActivity(id activity) {
    return MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
        activity, NULL);
}

NSString *MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
    id activityProxy,
    NSString **activityIdentity) {
    if (activityIdentity != NULL) *activityIdentity = nil;
    NSString *bundleIdentifier =
        MTShareSheetApplicationBundleIdentityForActivity(activityProxy);
    if (bundleIdentifier != nil) return bundleIdentifier;

    id configuration = MTShareSheetInvokeObjectGetter(
        activityProxy, "activityConfiguration");
    bundleIdentifier =
        MTShareSheetApplicationBundleIdentityForActivity(configuration);
    if (bundleIdentifier != nil) return bundleIdentifier;

    NSString *proxyIdentity =
        MTShareSheetProxyActivityIdentity(activityProxy);
    if (activityIdentity != NULL) *activityIdentity = proxyIdentity;
    return MTShareSheetApplicationBundleIdentityForActivityIdentity(
        proxyIdentity);
}

NSString *MTShareSheetApplicationBundleIdentityForActivityProxy(
    id activityProxy) {
    return MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
        activityProxy, NULL);
}

NSString *MTShareSheetApplicationBundleIdentityForActivityIdentity(
    NSString *activityIdentity) {
    NSString *identity = MTShareSheetCanonicalIdentity(activityIdentity);
    if ([identity isEqualToString:MTShareSheetMailActivityIdentity]) {
        return MTShareSheetMailBundleIdentifier;
    }
    if ([identity isEqualToString:MTShareSheetMessageActivityIdentity]) {
        return MTShareSheetMessageBundleIdentifier;
    }
    return nil;
}
