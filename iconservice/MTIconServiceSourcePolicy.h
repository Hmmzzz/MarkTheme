#import <Foundation/Foundation.h>

@class MTIconServiceRequestContext;

NS_ASSUME_NONNULL_BEGIN

// Default builds remain on the exact Preferences proof gate. The integrated
// release sets MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT=1, admitting every
// exact bundle-backed application-icon request; the immutable Generation
// resolver still returns stock on a resource/policy miss.
FOUNDATION_EXPORT BOOL MTIconServiceGenerationRolloutIsEnabled(void);
FOUNDATION_EXPORT BOOL MTIconServiceSourcePolicyAllowsContext(
    MTIconServiceRequestContext *_Nullable context);

NS_ASSUME_NONNULL_END
