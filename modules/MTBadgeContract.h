#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTBadgesModuleID;
FOUNDATION_EXPORT NSString *const MTBadgeSurface;
FOUNDATION_EXPORT NSString *const MTBadgeGlobalSubject;
FOUNDATION_EXPORT NSString *const MTBadgeAppearanceAny;
FOUNDATION_EXPORT NSString *const MTBadgeAppearanceLight;
FOUNDATION_EXPORT NSString *const MTBadgeAppearanceDark;

// Badge style and system appearance are independent axes. `variant` selects
// the authored style component; `trait` selects an optional device/appearance
// specialization of that style. A universal resource remains the final
// fallback for both light and dark appearances.
FOUNDATION_EXPORT NSString *_Nullable MTBadgeResourceTrait(
    NSString *deviceTrait,
    NSString *appearance);
FOUNDATION_EXPORT BOOL MTBadgeResourceTraitIsSupported(NSString *trait);
FOUNDATION_EXPORT NSArray<NSString *> *MTBadgeResourceTraitCandidates(
    NSString *deviceTrait,
    NSString *appearance);

NS_ASSUME_NONNULL_END
