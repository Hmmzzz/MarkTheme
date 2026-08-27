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
// static-icon resolver.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivity(id activity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityResolvingIdentity(
        id activity,
        NSString *_Nullable *_Nullable activityIdentity);
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityProxy(id activityProxy);
// Resolves the proxy's application identity and, only when that lookup falls
// through to the proxy class identity, returns the already-canonicalized value
// to the caller. Share image hooks use this to avoid walking
// activityConfiguration twice for one image request.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityProxyResolvingIdentity(
        id activityProxy,
        NSString *_Nullable *_Nullable activityIdentity);
// iOS 17.3.1 renders Mail and Messages as built-in UIActivity subclasses
// instead of passing their owning App identifiers through the provider.
FOUNDATION_EXPORT NSString *_Nullable
    MTShareSheetApplicationBundleIdentityForActivityIdentity(
        NSString *_Nullable activityIdentity);

NS_ASSUME_NONNULL_END
