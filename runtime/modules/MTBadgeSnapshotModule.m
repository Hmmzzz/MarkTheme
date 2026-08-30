#import "MTBadgeSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "MTBadgeConfiguration.h"
#import "MTBadgeContract.h"
#import "MTBadgeSnapshotResolver.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

#include <math.h>

NSString *const MTBadgeSnapshotModuleID = @"badges.snapshot";

static const uint32_t MTBadgePointDimension = 23;

MTBadgeSnapshotObservation MTRuntimeBadgeSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTBadgeSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .lightResourceHits = ATOMIC_VAR_INIT(0),
    .darkResourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .nativeSourceResolutions = ATOMIC_VAR_INIT(0),
    .appearanceSelections = ATOMIC_VAR_INIT(0),
    .themedBackgrounds = ATOMIC_VAR_INIT(0),
    .nativeFallbacks = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTBadgeSnapshotObservation) == 80,
    "Badge native-source ModuleRuntime observation ABI changed");

@interface MTBadgeImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTBadgeSnapshotContext *context;
@property(nonatomic, strong) UIImage *lightBackground;
@property(nonatomic, strong) UIImage *darkBackground;
@end

@implementation MTBadgeImageSet
@end

@interface MTBadgeSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTBadgeSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(atomic, strong, nullable) MTBadgeImageSet *currentImageSet;
@property(atomic, assign) BOOL preparationCompleted;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)reload;
- (BOOL)prepare;
- (BOOL)applyNativeBackgroundForBadgeView:(UIView *)badgeView
                           backgroundView:(UIImageView *)backgroundView;
@end

@implementation MTBadgeSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _resolver = [[MTBadgeSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return kernel.currentSnapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    if (_resolver == nil || _imageLoader == nil) return nil;
    return self;
}

- (nullable MTBadgeSnapshotContext *)contextForTraitCollection:
        (UITraitCollection *)traits {
    if (![traits isKindOfClass:UITraitCollection.class] ||
        !isfinite(traits.displayScale)) {
        return nil;
    }
    NSInteger roundedScale = (NSInteger)llround(traits.displayScale);
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(traits.displayScale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }
    NSString *deviceTrait = nil;
    if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    }
    return [MTBadgeSnapshotContext
        contextWithScale:(NSUInteger)roundedScale
             deviceTrait:deviceTrait];
}

- (nullable MTBadgeSnapshotContext *)currentScreenContext {
    UIScreen *screen = UIScreen.mainScreen;
    UITraitCollection *traits = screen.traitCollection;
    MTBadgeSnapshotContext *context = [self
        contextForTraitCollection:traits];
    if (context != nil) return context;
    CGFloat scale = screen.scale;
    NSInteger roundedScale = isfinite(scale) ? (NSInteger)llround(scale) : 0;
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(scale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }
    NSString *deviceTrait = nil;
    if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    }
    return [MTBadgeSnapshotContext
        contextWithScale:(NSUInteger)roundedScale
             deviceTrait:deviceTrait];
}

- (nullable UIImage *)decodeResolution:
        (MTBadgeSnapshotResolution *)resolution
                                  scale:(NSUInteger)scale {
    if (resolution == nil || scale < 1 || scale > 3) return nil;
    uint32_t pixelDimension = MTBadgePointDimension * (uint32_t)scale;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:pixelDimension
             targetPixelHeight:pixelDimension
                         error:NULL];
    UIImage *image = decoded == nil ? nil : [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)scale
        orientation:UIImageOrientationUp];
    if (image == nil || image.size.width != MTBadgePointDimension ||
        image.size.height != MTBadgePointDimension) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    CGFloat cap = (MTBadgePointDimension - 1) / 2.0;
    image = [[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
        resizableImageWithCapInsets:UIEdgeInsetsMake(cap, cap, cap, cap)
        resizingMode:UIImageResizingModeStretch];
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return image;
}

- (nullable MTBadgeImageSet *)buildImageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                   context:
        (MTBadgeSnapshotContext *)context {
    MTGeneration *generation = snapshot.generation;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generation == nil ||
        generationIdentifier.length == 0 || context == nil ||
        ![generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }

    NSDictionary<NSString *, id> *dictionary = generation.descriptor
        .moduleConfigurations[MTBadgesModuleID];
    MTBadgeConfiguration *configuration = dictionary == nil ? nil :
        [[MTBadgeConfiguration alloc]
            initWithDictionary:dictionary error:NULL];
    if (configuration == nil) return nil;

    MTBadgeSnapshotResolution *light = [self.resolver
        resolutionForVariant:configuration.defaultVariant
                        scale:context.scale
                  deviceTrait:context.deviceTrait
                   appearance:MTBadgeAppearanceLight
                        error:NULL];
    if (light == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.lightResourceHits,
        1, memory_order_relaxed);
    UIImage *lightImage = [self decodeResolution:light scale:context.scale];
    if (lightImage == nil) return nil;

    MTBadgeSnapshotResolution *dark = [self.resolver
        resolutionForVariant:configuration.defaultVariant
                        scale:context.scale
                  deviceTrait:context.deviceTrait
                   appearance:MTBadgeAppearanceDark
                        error:NULL];
    if (dark == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.darkResourceHits,
        1, memory_order_relaxed);
    UIImage *darkImage = [dark.resource.contentSHA256
            isEqualToString:light.resource.contentSHA256]
        ? lightImage : [self decodeResolution:dark scale:context.scale];
    if (darkImage == nil) return nil;

    MTBadgeImageSet *imageSet = [[MTBadgeImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.context = context;
    imageSet.lightBackground = lightImage;
    imageSet.darkBackground = darkImage;
    return imageSet;
}

- (void)publishImageSet:(nullable MTBadgeImageSet *)imageSet {
    self.currentImageSet = imageSet;
    self.preparationCompleted = YES;
    atomic_store_explicit(
        &MTRuntimeBadgeSnapshotObservation.state,
        imageSet == nil ? MTBadgeSnapshotModuleStateConfigured
                        : MTBadgeSnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTBadgeSnapshotModuleID,
        imageSet == nil ? MTBadgeSnapshotModuleStateConfigured
                        : MTBadgeSnapshotModuleStateReady,
        imageSet == nil ? @"Configured" : @"Ready");
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.reloads,
        1, memory_order_relaxed);
    self.preparationCompleted = NO;
    if (![NSThread isMainThread]) {
        self.currentImageSet = nil;
        return;
    }
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    MTBadgeSnapshotContext *context = [self currentScreenContext];
    MTBadgeImageSet *imageSet = [self
        buildImageSetForSnapshot:snapshot context:context];
    [self publishImageSet:imageSet];
}

- (BOOL)prepare {
    // This is called while the injected Runtime constructor is installing the
    // ABI-gated Hook. UIKit process singletons are not safe to initialize at
    // that point, so preparation is deliberately a Foundation-only readiness
    // check. The first native SBIconBadgeView source call performs the tiny,
    // one-time 23pt decode after Apple's view initializer has completed.
    return self.kernel != nil && self.resolver != nil &&
        self.imageLoader != nil;
}

- (BOOL)applyNativeBackgroundForBadgeView:(UIView *)badgeView
                           backgroundView:(UIImageView *)backgroundView {
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.nativeSourceResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.nativeFallbacks,
            1, memory_order_relaxed);
        return NO;
    }

    if (!self.preparationCompleted) [self reload];

    MTBadgeImageSet *imageSet = self.currentImageSet;
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    UITraitCollection *traits = badgeView.traitCollection;
    MTBadgeSnapshotContext *context = [self
        contextForTraitCollection:traits];
    if (context == nil) {
        traits = backgroundView.traitCollection;
        context = [self contextForTraitCollection:traits];
    }
    // A freshly initialized view may not have joined SpringBoard's hierarchy
    // yet, so its inherited traits can legitimately be unspecified at this
    // source boundary. The image set was prepared from the owning screen
    // immediately before the Hook was installed; use that same native
    // environment until UIKit propagates the view traits.
    if (context == nil ||
        traits.userInterfaceStyle == UIUserInterfaceStyleUnspecified) {
        UITraitCollection *screenTraits = UIScreen.mainScreen.traitCollection;
        MTBadgeSnapshotContext *screenContext = [self
            contextForTraitCollection:screenTraits];
        if (screenContext != nil) {
            traits = screenTraits;
            context = screenContext;
        }
    }
    if (imageSet == nil || context == nil ||
        ![imageSet.context isEqual:context] ||
        ![imageSet.generationIdentifier isEqualToString:
            snapshot.state.activeGenerationIdentifier]) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.nativeFallbacks,
            1, memory_order_relaxed);
        return NO;
    }

    // UIImageAsset must not sit between the published raster and Apple's
    // carrier here. On iOS 17.3.1, retrieving a registered @3x resizable
    // image with a style-only trait collection returns a @1x 69-point image
    // while retaining 11-point cap insets. SBDarkeningImageView then
    // compresses the 47-point center into its 24-point native bounds, which
    // both blurs the artwork and makes its outer detail appear clipped.
    // Selecting the immutable source image directly preserves its authored
    // 23-point logical size and device scale.
    UIImage *image = traits.userInterfaceStyle == UIUserInterfaceStyleDark
        ? imageSet.darkBackground : imageSet.lightBackground;
    BOOL imageMatchesNativeContext = image != nil &&
        fabs(image.scale - (CGFloat)context.scale) <= 0.001 &&
        fabs(image.size.width - MTBadgePointDimension) <= 0.001 &&
        fabs(image.size.height - MTBadgePointDimension) <= 0.001;
    if (!imageMatchesNativeContext) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.nativeFallbacks,
            1, memory_order_relaxed);
        return NO;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.appearanceSelections,
        1, memory_order_relaxed);

    // Apple's init has already installed its fixed system-red color. The
    // transparent themed raster replaces that paint while the original
    // SBDarkeningImageView continues to own darkening, parallax, resizing,
    // corner radius, text animation, and reuse behavior.
    backgroundView.backgroundColor = nil;
    backgroundView.image = image;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.themedBackgrounds,
        1, memory_order_relaxed);
    return YES;
}

@end

static os_unfair_lock MTBadgeSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTBadgeSnapshotModule *MTBadgeSnapshotInstance;

BOOL MTBadgeSnapshotConfigure(MTRuntimeKernel *kernel, NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTBadgeSnapshotLock);
    if (MTBadgeSnapshotInstance == nil) {
        MTBadgeSnapshotInstance = [[MTBadgeSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTBadgeSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTBadgeSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeBadgeSnapshotObservation.state,
            MTBadgeSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTBadgeSnapshotModuleID,
            MTBadgeSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError errorWithDomain:
            @"com.hmmzzz.marktheme.badge-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"Badge snapshot module could not initialize."
        }];
    }
    return configured;
}

void MTBadgeSnapshotReload(void) {
    [MTBadgeSnapshotInstance reload];
}

BOOL MTBadgeSnapshotPrepare(void) {
    return [MTBadgeSnapshotInstance prepare];
}

BOOL MTBadgeSnapshotApplyNativeBackground(id badgeView,
                                          id nativeBackgroundView) {
    if (MTBadgeSnapshotInstance == nil ||
        ![badgeView isKindOfClass:UIView.class] ||
        ![nativeBackgroundView isKindOfClass:UIImageView.class]) {
        return NO;
    }
    return [MTBadgeSnapshotInstance
        applyNativeBackgroundForBadgeView:badgeView
                            backgroundView:nativeBackgroundView];
}
