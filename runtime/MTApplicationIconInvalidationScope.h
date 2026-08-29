#import <Foundation/Foundation.h>

@class MTRuntimeSnapshot;
@class MTRuntimeFeatureState;

NS_ASSUME_NONNULL_BEGIN

// Returns installed bundle identifiers whose ordinary application-icon pixels
// are authored by the supplied immutable Generation. A malformed
// configuration or index lookup conservatively returns every valid input so
// the optimization can never suppress a required native invalidation.
FOUNDATION_EXPORT NSSet<NSString *> *
MTApplicationIconInvalidationAffectedBundleIdentifiers(
    MTRuntimeSnapshot *snapshot,
    NSArray<NSString *> *installedBundleIdentifiers);

// Ordinary application-icon source state includes only the three modules
// whose pixels are composed at the IconServices generation boundary.
FOUNDATION_EXPORT MTRuntimeFeatureState *_Nullable
MTApplicationIconSourceFeatureState(MTRuntimeSnapshot *snapshot);

// Native icon owners additionally include live Calendar/Clock state;
// Preferences and Share Sheet also own non-application UI resources. Their
// container reload is necessary when one of those source families changes,
// while unrelated features must not cause an application-icon cache purge.
FOUNDATION_EXPORT MTRuntimeFeatureState *_Nullable
MTApplicationIconOwnerFeatureState(
    MTRuntimeSnapshot *snapshot,
    BOOL includesUIResources);

FOUNDATION_EXPORT BOOL MTApplicationIconFeatureStateUsesGlobalAppearance(
    MTRuntimeFeatureState *state);

NS_ASSUME_NONNULL_END
