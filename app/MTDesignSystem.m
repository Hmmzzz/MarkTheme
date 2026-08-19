#import "MTDesignSystem.h"

#import <math.h>
#import <QuartzCore/QuartzCore.h>

NSString *const MTInterfaceStyleSystem = @"system";
NSString *const MTInterfaceStyleLight = @"light";
NSString *const MTInterfaceStyleDark = @"dark";

static NSString *const MTInterfaceStylePreferenceKey =
    @"MarkThemeInterfaceStylePreference";

BOOL MTViewControllerCanApplyVisibleProjection(
    UIViewController * _Nullable viewController) {
    if (!viewController.isViewLoaded || viewController.view.window == nil ||
        viewController.presentedViewController != nil) {
        return NO;
    }
    UINavigationController *navigation = viewController.navigationController;
    return navigation == nil || navigation.topViewController == viewController;
}

static UIColor *MTColorRGB(CGFloat red, CGFloat green, CGFloat blue) {
    return [UIColor colorWithRed:red / 255.0
                           green:green / 255.0
                            blue:blue / 255.0
                           alpha:1.0];
}

UIColor *MTAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(255, 145, 111)
            : MTColorRGB(222, 91, 58);
    }];
}

UIColor *MTCanvasColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(16, 18, 17)
            : MTColorRGB(247, 244, 238);
    }];
}

UIColor *MTCardColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(29, 32, 30)
            : MTColorRGB(255, 253, 249);
    }];
}

UIColor *MTPrimaryActionColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(242, 239, 231)
            : MTColorRGB(29, 36, 32);
    }];
}

UIColor *MTPrimaryActionForegroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(24, 28, 26)
            : UIColor.whiteColor;
    }];
}

UIColor *MTHairlineColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor.whiteColor colorWithAlphaComponent:0.10]
            : [MTColorRGB(43, 51, 47) colorWithAlphaComponent:0.10];
    }];
}

UIColor *MTSuccessColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(105, 221, 168)
            : MTColorRGB(28, 143, 94);
    }];
}

UIColor *MTWarningColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(255, 193, 105)
            : MTColorRGB(190, 111, 24);
    }];
}

UIColor *MTDangerColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? MTColorRGB(255, 126, 121)
            : MTColorRGB(202, 56, 61);
    }];
}

UIColor *MTSpecimenInkColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.92]
            : [UIColor colorWithWhite:0.10 alpha:0.92];
    }];
}

UIColor *MTSpecimenSecondaryInkColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.64]
            : [UIColor colorWithWhite:0.16 alpha:0.62];
    }];
}

UIColor *MTTintedBackground(UIColor *color) {
    return [color colorWithAlphaComponent:0.12];
}

NSArray<UIColor *> *MTThemeGradientColors(NSString *themeIdentifier) {
    NSUInteger palette = themeIdentifier.length == 0
        ? 0
        : (themeIdentifier.hash % 4) + 1;
    NSArray<NSArray<UIColor *> *> *light = @[
        @[ MTColorRGB(241, 229, 212), MTColorRGB(218, 198, 174) ],
        @[ MTColorRGB(253, 219, 199), MTColorRGB(241, 169, 130) ],
        @[ MTColorRGB(220, 242, 225), MTColorRGB(166, 220, 194) ],
        @[ MTColorRGB(227, 222, 250), MTColorRGB(184, 179, 233) ],
        @[ MTColorRGB(213, 232, 248), MTColorRGB(159, 200, 232) ],
    ];
    NSArray<NSArray<UIColor *> *> *dark = @[
        @[ MTColorRGB(76, 65, 53), MTColorRGB(46, 42, 36) ],
        @[ MTColorRGB(104, 57, 42), MTColorRGB(59, 36, 30) ],
        @[ MTColorRGB(31, 77, 61), MTColorRGB(21, 50, 42) ],
        @[ MTColorRGB(61, 56, 105), MTColorRGB(35, 34, 67) ],
        @[ MTColorRGB(40, 69, 94), MTColorRGB(27, 45, 63) ],
    ];
    NSArray<UIColor *> *lightPalette = light[palette];
    NSArray<UIColor *> *darkPalette = dark[palette];
    return @[
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? darkPalette[0]
                : lightPalette[0];
        }],
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? darkPalette[1]
                : lightPalette[1];
        }],
    ];
}

UILabel *MTLabel(UIFontTextStyle style, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    UIFontDescriptor *descriptor =
        [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    UIFont *font = [UIFont systemFontOfSize:descriptor.pointSize weight:weight];
    UIFont *scaledFont =
        [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font];
    label.font = scaledFont;
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

UIView *MTCardView(void) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = MTCardColor();
    view.layer.cornerRadius = 22.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    view.layer.borderColor = MTHairlineColor().CGColor;
    return view;
}

void MTConfigureNavigationController(UINavigationController *navigationController) {
    if (navigationController == nil) return;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = MTCanvasColor();
    appearance.shadowColor = UIColor.clearColor;
    appearance.largeTitleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.labelColor,
        NSFontAttributeName : [UIFont systemFontOfSize:34 weight:UIFontWeightBold],
    };
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.labelColor,
        NSFontAttributeName : [UIFont systemFontOfSize:17
                                                    weight:UIFontWeightSemibold],
    };
    UINavigationBar *bar = navigationController.navigationBar;
    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    bar.compactAppearance = appearance;
    bar.compactScrollEdgeAppearance = appearance;
}

NSString *MTErrorPresentationMessage(NSString *fallback, NSError *error) {
    if (error == nil) return fallback;
    NSMutableArray<NSString *> *diagnostics = [NSMutableArray array];
    NSError *current = error;
    for (NSUInteger depth = 0; current != nil && depth < 6; depth++) {
        NSString *description = current.localizedDescription.length > 0
            ? current.localizedDescription : @"Unknown error";
        [diagnostics addObject:[NSString stringWithFormat:@"%@/%ld: %@",
            current.domain, (long)current.code, description]];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class]
            ? underlying : nil;
    }
    return [NSString stringWithFormat:@"%@\n\n%@", fallback,
        [diagnostics componentsJoinedByString:@"\n"]];
}

NSString *MTInterfaceStylePreference(void) {
    NSString *preference = [NSUserDefaults.standardUserDefaults
        stringForKey:MTInterfaceStylePreferenceKey];
    if ([preference isEqualToString:MTInterfaceStyleLight] ||
        [preference isEqualToString:MTInterfaceStyleDark]) {
        return preference;
    }
    return MTInterfaceStyleSystem;
}

UIUserInterfaceStyle MTPreferredInterfaceStyle(void) {
    NSString *preference = MTInterfaceStylePreference();
    if ([preference isEqualToString:MTInterfaceStyleLight]) {
        return UIUserInterfaceStyleLight;
    }
    if ([preference isEqualToString:MTInterfaceStyleDark]) {
        return UIUserInterfaceStyleDark;
    }
    return UIUserInterfaceStyleUnspecified;
}

void MTApplyInterfaceStylePreference(void) {
    NSCAssert(NSThread.isMainThread, @"Appearance must be applied on the main thread.");
    UIUserInterfaceStyle style = MTPreferredInterfaceStyle();
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            window.overrideUserInterfaceStyle = style;
        }
    }
}

void MTSetInterfaceStylePreference(NSString *preference) {
    NSString *stored = ([preference isEqualToString:MTInterfaceStyleLight] ||
                        [preference isEqualToString:MTInterfaceStyleDark])
        ? preference : MTInterfaceStyleSystem;
    [NSUserDefaults.standardUserDefaults setObject:stored
                                            forKey:MTInterfaceStylePreferenceKey];
    MTApplyInterfaceStylePreference();
}

@implementation MTPressableButton

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (!self.enabled) return;
    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.14;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted
            ? CGAffineTransformMakeScale(0.97, 0.97)
            : CGAffineTransformIdentity;
    }
                     completion:nil];
}

@end

@implementation MTGradientView

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.startPoint = CGPointMake(0.04, 0.06);
    gradient.endPoint = CGPointMake(0.96, 0.94);
    self.layer.cornerRadius = 30.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    __weak typeof(self) weakSelf = self;
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                      withHandler:^(__unused id<UITraitEnvironment> environment,
                                    __unused UITraitCollection *previous) {
        [weakSelf updateResolvedGradientColors];
    }];
    return self;
}

- (void)setGradientColors:(NSArray<UIColor *> *)gradientColors {
    _gradientColors = [gradientColors copy];
    [self updateResolvedGradientColors];
}

- (void)updateResolvedGradientColors {
    if (self.gradientColors.count == 0) return;
    UIColor *first = [self.gradientColors.firstObject
        resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *last = [self.gradientColors.lastObject
        resolvedColorWithTraitCollection:self.traitCollection];
    ((CAGradientLayer *)self.layer).colors = @[
        (id)first.CGColor,
        (id)last.CGColor,
    ];
}

@end

@implementation MTFloatingActionDockView

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    gradient.locations = @[ @0.0, @0.34, @0.68 ];
    [self updateGradientColors];
    __weak typeof(self) weakSelf = self;
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                      withHandler:^(__unused id<UITraitEnvironment> environment,
                                    __unused UITraitCollection *previous) {
        [weakSelf updateGradientColors];
    }];
    return self;
}

- (void)updateGradientColors {
    UIColor *canvas = [MTCanvasColor()
        resolvedColorWithTraitCollection:self.traitCollection];
    ((CAGradientLayer *)self.layer).colors = @[
        (id)[canvas colorWithAlphaComponent:0.0].CGColor,
        (id)[canvas colorWithAlphaComponent:0.96].CGColor,
        (id)canvas.CGColor,
    ];
}

@end

@interface MTTableSupplementaryLayoutCache ()
@property(nonatomic, assign) CGFloat measuredWidth;
@property(nonatomic, assign) BOOL needsMeasurement;
- (void)fitView:(UIView *)view
    inTableView:(UITableView *)tableView
         header:(BOOL)header;
@end

@implementation MTTableSupplementaryLayoutCache

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _needsMeasurement = YES;
    return self;
}

- (void)invalidate {
    self.needsMeasurement = YES;
}

- (void)fitHeaderView:(UIView *)view inTableView:(UITableView *)tableView {
    [self fitView:view inTableView:tableView header:YES];
}

- (void)fitFooterView:(UIView *)view inTableView:(UITableView *)tableView {
    [self fitView:view inTableView:tableView header:NO];
}

- (void)fitView:(UIView *)view
    inTableView:(UITableView *)tableView
         header:(BOOL)header {
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (view == nil || width <= 0.0) return;
    if (!self.needsMeasurement && fabs(width - self.measuredWidth) <= 0.5) {
        return;
    }

    CGRect frame = view.frame;
    frame.origin = CGPointZero;
    frame.size.width = width;
    view.frame = frame;
    [view setNeedsLayout];
    [view layoutIfNeeded];
    CGFloat height = ceil([view systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (height <= 0.0) return;

    frame.size.height = height;
    view.frame = frame;
    if (header) {
        tableView.tableHeaderView = view;
    } else {
        tableView.tableFooterView = view;
    }
    self.measuredWidth = width;
    self.needsMeasurement = NO;
}

@end

@interface MTIconGridView ()
@property(nonatomic, copy) NSArray<UIImage *> *iconImages;
@property(nonatomic, copy) NSArray<UIImageView *> *imageViews;
@end

static NSArray<UIImage *> *MTIconGridFallbackImages(void) {
    static NSArray<UIImage *> *images;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *symbols = @[
            @"message.fill",
            @"photo.fill.on.rectangle.fill",
            @"music.note",
            @"safari.fill",
        ];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:30.0
                                                            weight:UIImageSymbolWeightMedium];
        NSMutableArray<UIImage *> *fallbacks =
            [NSMutableArray arrayWithCapacity:symbols.count];
        for (NSString *symbol in symbols) {
            UIImage *image = [[UIImage systemImageNamed:symbol
                withConfiguration:configuration]
                imageWithTintColor:[UIColor colorWithWhite:0.10 alpha:0.40]
                    renderingMode:UIImageRenderingModeAlwaysOriginal];
            [fallbacks addObject:image];
        }
        images = [fallbacks copy];
    });
    return images;
}

@implementation MTIconGridView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = NO;
    NSMutableArray<UIImageView *> *views = [NSMutableArray arrayWithCapacity:4];
    for (NSUInteger index = 0; index < 4; index++) {
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.clipsToBounds = YES;
        imageView.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.55];
        imageView.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:imageView];
        [views addObject:imageView];
    }
    _imageViews = views;
    _iconImages = @[];
    [self updateImagesAnimated:NO];
    return self;
}

- (void)setIconImages:(NSArray<UIImage *> *)iconImages {
    [self setIconImages:iconImages animated:NO];
}

- (void)setIconImages:(NSArray<UIImage *> *)iconImages animated:(BOOL)animated {
    NSArray<UIImage *> *nextImages = [iconImages copy];
    if ([self.iconImages isEqualToArray:nextImages]) return;
    _iconImages = nextImages;
    [self updateImagesAnimated:animated];
}

- (UIImage *)fallbackImageAtIndex:(NSUInteger)index {
    NSArray<UIImage *> *images = MTIconGridFallbackImages();
    return images[index % images.count];
}

- (void)updateImagesAnimated:(BOOL)animated {
    void (^updates)(void) = ^{
        for (NSUInteger index = 0; index < self.imageViews.count; index++) {
            UIImageView *view = self.imageViews[index];
            BOOL hasImage = index < self.iconImages.count;
            view.image = hasImage
                ? self.iconImages[index]
                : [self fallbackImageAtIndex:index];
            view.backgroundColor = hasImage
                ? UIColor.clearColor
                : [UIColor.whiteColor colorWithAlphaComponent:0.55];
        }
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:self
                          duration:0.22
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:updates
                        completion:nil];
    } else {
        updates();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat boundsSide = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    if (boundsSide <= 0.0) return;
    CGFloat spacing = MAX(6.0, MIN(10.0, boundsSide * 0.065));
    CGFloat dimension = floor((boundsSide - spacing) / 2.0);
    CGFloat gridWidth = dimension * 2.0 + spacing;
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - gridWidth) / 2.0);
    CGFloat originY = floor((CGRectGetHeight(self.bounds) - gridWidth) / 2.0);
    for (NSUInteger index = 0; index < self.imageViews.count; index++) {
        NSUInteger column = index % 2;
        NSUInteger row = index / 2;
        UIImageView *view = self.imageViews[index];
        view.frame = CGRectMake(originX + column * (dimension + spacing),
                                originY + row * (dimension + spacing),
                                dimension, dimension);
        view.layer.cornerRadius = dimension * 0.2253;
    }
}

@end
