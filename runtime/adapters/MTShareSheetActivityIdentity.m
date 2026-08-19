#import "MTShareSheetActivityIdentity.h"

#import <objc/runtime.h>

#include <string.h>

static const char *const MTShareSheetObjectGetterTypeEncoding = "@16@0:8";
static const char *const MTShareSheetActivityBundleIdentifierGetterName =
    "_bundleIdentifierForActivityImageCreation";
static const char *const MTShareSheetContainingAppBundleIdentifierGetterName =
    "containingAppBundleIdentifier";
static NSString *const MTShareSheetMailActivityIdentity = @"UIMailActivity";
static NSString *const MTShareSheetMessageActivityIdentity =
    @"UIMessageActivity";
static NSString *const MTShareSheetMailBundleIdentifier =
    @"com.apple.mobilemail";
static NSString *const MTShareSheetMessageBundleIdentifier =
    @"com.apple.MobileSMS";

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

NSString *MTShareSheetApplicationBundleIdentity(id bundleIdentifier) {
    return MTShareSheetCanonicalIdentity(bundleIdentifier);
}

NSString *MTShareSheetApplicationBundleIdentityForActivity(id activity) {
    NSString *bundleIdentifier = MTShareSheetCanonicalIdentity(
        MTShareSheetInvokeObjectGetter(
            activity, MTShareSheetActivityBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    // UIApplicationExtensionActivity exposes this exact 21D61 getter. Keep
    // it as a fallback because specialized activities can inherit the base
    // image-creation getter without supplying a result of their own.
    bundleIdentifier = MTShareSheetCanonicalIdentity(
        MTShareSheetInvokeObjectGetter(
            activity, MTShareSheetContainingAppBundleIdentifierGetterName));
    if (bundleIdentifier != nil) return bundleIdentifier;

    return MTShareSheetApplicationBundleIdentityForActivityIdentity(
        MTShareSheetUIActivityIdentity(activity));
}

NSString *MTShareSheetApplicationBundleIdentityForActivityProxy(
    id activityProxy) {
    NSString *bundleIdentifier =
        MTShareSheetApplicationBundleIdentityForActivity(activityProxy);
    if (bundleIdentifier != nil) return bundleIdentifier;

    id configuration = MTShareSheetInvokeObjectGetter(
        activityProxy, "activityConfiguration");
    id activity = MTShareSheetInvokeObjectGetter(configuration, "activity");
    bundleIdentifier =
        MTShareSheetApplicationBundleIdentityForActivity(activity);
    if (bundleIdentifier != nil) return bundleIdentifier;

    return MTShareSheetApplicationBundleIdentityForActivityIdentity(
        MTShareSheetProxyActivityIdentity(activityProxy));
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
