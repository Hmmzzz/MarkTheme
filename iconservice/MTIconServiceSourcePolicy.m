#import "MTIconServiceSourcePolicy.h"

#import "MTIconServiceABI.h"
#import "MTIconServiceProvenCanary.h"

#if !defined(MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT)
#define MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT 0
#endif

_Static_assert(MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT == 0 ||
               MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT == 1,
    "MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT must be disabled or enabled");

BOOL MTIconServiceGenerationRolloutIsEnabled(void) {
    return MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT == 1;
}

BOOL MTIconServiceSourcePolicyAllowsContext(
    MTIconServiceRequestContext *context) {
    if (context == nil) return NO;
    if (MTIconServiceGenerationRolloutIsEnabled()) return YES;
    return MTIconServiceProvenCanaryAllowsRequest(
        context.bundleIdentifier,
        context.iconDigest,
        context.descriptorDigest,
        context.pointSize,
        context.scale);
}
