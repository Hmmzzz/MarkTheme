#import "MTShareSheetActivityIdentityTests.h"

#import "adapters/MTShareSheetActivityIdentity.h"

static NSUInteger MTShareSheetIdentityAssertionCount;

static void MTShareSheetIdentityAssert(BOOL condition, NSString *message) {
    MTShareSheetIdentityAssertionCount++;
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

// UIAirDropActivity has a glyph identity but no application bundle on 21D61.
// This host-only class models that contract without loading ShareSheet.
@interface MTShareSheetTestCustomActivity : NSObject
@end
@implementation MTShareSheetTestCustomActivity
@end

@interface MTShareSheetTestActivityWrapper : NSObject
@property(nonatomic, strong, nullable) id activity;
@property(nonatomic, copy, nullable) NSString *applicationBundleIdentifier;
@end
@implementation MTShareSheetTestActivityWrapper
@end

@interface MTShareSheetTestActivityConfiguration :
    MTShareSheetTestActivityWrapper
@property(nonatomic, copy, nullable) id activityClassName;
@end
@implementation MTShareSheetTestActivityConfiguration
@end

@interface MTShareSheetTestActivityProxy : MTShareSheetTestActivityWrapper
@property(nonatomic, strong, nullable) id configuration;
@property(nonatomic) NSUInteger configurationReadCount;
- (id)activityConfiguration;
@end
@implementation MTShareSheetTestActivityProxy
- (id)activityConfiguration {
    self.configurationReadCount++;
    return self.configuration;
}
@end

NSUInteger MTRunShareSheetActivityIdentityTests(void) {
    MTShareSheetIdentityAssertionCount = 0;
    MTShareSheetTestCustomActivity *customActivity =
        [[MTShareSheetTestCustomActivity alloc] init];
    NSString *customIdentity = NSStringFromClass(customActivity.class);
    NSString *identity = @"unexpected";
    NSString *bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            customActivity, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:customIdentity],
        @"A custom activity without an App bundle must retain its class identity");

    MTShareSheetTestActivityWrapper *wrapper =
        [[MTShareSheetTestActivityWrapper alloc] init];
    wrapper.activity = customActivity;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            wrapper, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:customIdentity],
        @"A wrapper must preserve an AirDrop-style custom glyph instead of its own class");

    MTShareSheetTestActivityWrapper *outerWrapper =
        [[MTShareSheetTestActivityWrapper alloc] init];
    outerWrapper.activity = wrapper;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            outerWrapper, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:customIdentity],
        @"A valid nested wrapper chain must preserve the underlying custom glyph");

    wrapper.applicationBundleIdentifier = @"com.example.preferred";
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            wrapper, &identity);
    MTShareSheetIdentityAssert(
        [bundle isEqualToString:@"com.example.preferred"] && identity == nil,
        @"An explicit App bundle must remain preferred over a nested custom glyph");
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            outerWrapper, &identity);
    MTShareSheetIdentityAssert(
        [bundle isEqualToString:@"com.example.preferred"] && identity == nil,
        @"Nested App bundle resolution must retain the native application bridge");
    wrapper.applicationBundleIdentifier = nil;

    MTShareSheetTestActivityConfiguration *configuration =
        [[MTShareSheetTestActivityConfiguration alloc] init];
    configuration.activityClassName = @"UIAirDropActivity";
    MTShareSheetTestActivityProxy *proxy =
        [[MTShareSheetTestActivityProxy alloc] init];
    proxy.configuration = configuration;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:@"UIAirDropActivity"] &&
        proxy.configurationReadCount == 1,
        @"A configured AirDrop proxy must resolve its exact glyph with one configuration read");

    configuration.activityClassName = nil;
    configuration.activity = customActivity;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:customIdentity],
        @"A configuration must preserve its live custom activity when the class field is absent");

    proxy.configuration = nil;
    proxy.activity = customActivity;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:customIdentity],
        @"A proxy must preserve its live custom activity when configuration is absent");

    proxy.configuration = configuration;
    configuration.activityClassName = @"UIAirDropActivity";
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil &&
        [identity isEqualToString:@"UIAirDropActivity"],
        @"A valid configured activity identity must remain preferred over nested class fallback");

    proxy.activity = nil;
    configuration.activity = nil;
    configuration.activityClassName = @"unsafe/activity";
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"An unsafe configured identity must not fall back to a proxy implementation class");
    configuration.activityClassName = @42;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"A non-string configured identity must preserve stock artwork");

    wrapper.activity = wrapper;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            wrapper, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"A self-referencing wrapper must reject identity resolution without guessing a glyph");

    wrapper.activity = outerWrapper;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            outerWrapper, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"An indirect activity cycle must terminate without a replacement identity");

    configuration.activityClassName = @"UIAirDropActivity";
    proxy.activity = outerWrapper;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"A cyclic proxy must preserve stock artwork even with a configured glyph");
    proxy.activity = nil;
    configuration.activity = outerWrapper;
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
            proxy, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"A cyclic configuration activity must preserve stock artwork");
    wrapper.activity = nil;
    outerWrapper.activity = nil;
    configuration.activity = nil;

    id deepActivity = customActivity;
    for (NSUInteger index = 0; index < 9; index++) {
        MTShareSheetTestActivityWrapper *next =
            [[MTShareSheetTestActivityWrapper alloc] init];
        next.activity = deepActivity;
        deepActivity = next;
    }
    bundle =
        MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
            deepActivity, &identity);
    MTShareSheetIdentityAssert(bundle == nil && identity == nil,
        @"Excessive activity nesting must fail closed without a stack overflow or guessed glyph");

    return MTShareSheetIdentityAssertionCount;
}
