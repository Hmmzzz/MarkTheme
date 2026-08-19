#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIColor *MTAccentColor(void);
FOUNDATION_EXPORT UIColor *MTCanvasColor(void);
FOUNDATION_EXPORT UIColor *MTCardColor(void);
FOUNDATION_EXPORT UIColor *MTPrimaryActionColor(void);
FOUNDATION_EXPORT UIColor *MTPrimaryActionForegroundColor(void);
FOUNDATION_EXPORT UIColor *MTHairlineColor(void);
FOUNDATION_EXPORT UIColor *MTSuccessColor(void);
FOUNDATION_EXPORT UIColor *MTWarningColor(void);
FOUNDATION_EXPORT UIColor *MTDangerColor(void);
FOUNDATION_EXPORT UIColor *MTSpecimenInkColor(void);
FOUNDATION_EXPORT UIColor *MTSpecimenSecondaryInkColor(void);
FOUNDATION_EXPORT UIColor *MTTintedBackground(UIColor *color);
FOUNDATION_EXPORT NSArray<UIColor *> *MTThemeGradientColors(
    NSString * _Nullable themeIdentifier);

FOUNDATION_EXPORT UILabel *MTLabel(UIFontTextStyle style,
                                   UIFontWeight weight,
                                   UIColor *color);
FOUNDATION_EXPORT UIView *MTCardView(void);
FOUNDATION_EXPORT void MTConfigureNavigationController(
    UINavigationController *navigationController);
FOUNDATION_EXPORT NSString *MTErrorPresentationMessage(
    NSString *fallback, NSError * _Nullable error);
// A controller may apply view projection work only while it is the visible
// navigation leaf and is not covered by another presentation.
FOUNDATION_EXPORT BOOL MTViewControllerCanApplyVisibleProjection(
    UIViewController * _Nullable viewController);

FOUNDATION_EXPORT NSString *const MTInterfaceStyleSystem;
FOUNDATION_EXPORT NSString *const MTInterfaceStyleLight;
FOUNDATION_EXPORT NSString *const MTInterfaceStyleDark;
FOUNDATION_EXPORT NSString *MTInterfaceStylePreference(void);
FOUNDATION_EXPORT void MTSetInterfaceStylePreference(NSString *preference);
FOUNDATION_EXPORT UIUserInterfaceStyle MTPreferredInterfaceStyle(void);
FOUNDATION_EXPORT void MTApplyInterfaceStylePreference(void);

@interface MTPressableButton : UIButton
@end

@interface MTGradientView : UIView
@property(nonatomic, copy) NSArray<UIColor *> *gradientColors;
@end

@interface MTFloatingActionDockView : UIView
@end

// Bounds Auto Layout measurement for tableHeaderView/tableFooterView to the
// first pass, width changes, and explicit content invalidations.
@interface MTTableSupplementaryLayoutCache : NSObject
- (void)invalidate;
- (void)fitHeaderView:(UIView *)view inTableView:(UITableView *)tableView;
- (void)fitFooterView:(UIView *)view inTableView:(UITableView *)tableView;
@end

// A compact Home Screen-style 2x2 icon preview used by theme specimens.
@interface MTIconGridView : UIView
- (void)setIconImages:(NSArray<UIImage *> *)iconImages animated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
