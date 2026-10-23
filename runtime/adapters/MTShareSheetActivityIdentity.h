#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// SnowBoard-compatible Share resource identities. UIActivity uses its live
// class name; SUIHostActivityProxy uses activityConfiguration.activityClassName.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetUIActivityIdentity(id activity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetProxyActivityIdentity(id activityProxy);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetActivityTypeIdentity(id activity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentity(id bundleIdentifier);
// Extension activities render the containing App icon, not an icon keyed by
// the shared UIApplicationExtensionActivity/UISocialActivity class name.
// These helpers use only exact object getters reached from an actual Share
// image call, then canonicalize the returned identifier before it enters the
// static-icon resolver. When a wrapper contains a custom activity without an
// App bundle (such as AirDrop), ResolvingIdentity preserves the nested glyph
// identity. Cyclic or excessively nested wrappers return no identity.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivity(id activity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
        id activity,
        NSString *_Nullable *_Nullable activityIdentity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityProxy(id activityProxy);
// Resolves the proxy's application identity, then its configured class name or
// a live nested custom activity. The proxy/configuration implementation class
// is never used as a glyph identity. Reads activityConfiguration only once.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
        id activityProxy,
        NSString *_Nullable *_Nullable activityIdentity);
// iOS 17.3.1 renders Mail and Messages as built-in UIActivity subclasses;
// Photos wraps the same two destinations in PUMailActivity and
// PUMessageActivity. These exact fallbacks recover the owning App identity
// when the otherwise-preferred live bundle getters do not return a value.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityIdentity(
        NSString *_Nullable activityIdentity);

NS_ASSUME_NONNULL_END
