#import "MTIconShadowSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTIconShadowConfiguration.h"
#import "MTIconShadowContract.h"
#import "MTIconShadowSnapshotResolver.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTRuntimeABIReport.h"

#include <math.h>

NSString *const MTIconShadowSnapshotModuleID = @"icon-shadow.snapshot";

static const NSUInteger MTIconShadowMaximumReadyImageSets = 3;
static const NSUInteger MTIconShadowMaximumReadyCost = 3 * 1024 * 1024;
static const NSUInteger MTIconShadowMaximumPendingImageSets = 3;
static const NSUInteger MTIconShadowMaximumFailureCount = 6;
static const CGFloat MTIconShadowMinimumIconPointDimension = 20.0;
static const CGFloat MTIconShadowMaximumIconPointDimension = 100.0;
static const CGFloat MTIconShadowLargeIPadIconPointDimension = 80.0;

MTIconShadowSnapshotObservation MTRuntimeIconShadowSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTIconShadowSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .viewResolutions = ATOMIC_VAR_INIT(0),
    .layersCreated = ATOMIC_VAR_INIT(0),
    .layerUpdates = ATOMIC_VAR_INIT(0),
    .layersRemoved = ATOMIC_VAR_INIT(0),
    .contextMisses = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconShadowSnapshotObservation) == 80,
    "The Icon Shadow ModuleRuntime observation layout must remain fixed.");

@interface MTIconShadowImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy) NSString *variant;
@property(nonatomic, strong) MTIconShadowSnapshotContext *context;
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, assign) NSUInteger residentCost;
@end

@implementation MTIconShadowImageSet
@end

@interface MTIconShadowSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<MTIconShadowImageSet *> *imageSets;
@property(nonatomic, strong) dispatch_queue_t preparationQueue;
@property(atomic, strong, nullable) MTIconShadowSnapshotContext *lastContext;
@property(atomic, copy, nullable) dispatch_block_t readyHandler;
@property(nonatomic, strong) NSMapTable<UIView *, CALayer *> *shadowLayers;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)reload;
- (BOOL)resolveIconView:(UIView *)iconView
          iconImageView:(UIView *)iconImageView;
- (void)forgetIconView:(UIView *)iconView
          iconImageView:(nullable UIView *)iconImageView;
@end

static BOOL MTIconShadowLayerIsImmediatelyBelowImageLayer(
    CALayer *shadow,
    CALayer *imageLayer,
    CALayer *containerLayer) {
    if (shadow.superlayer != containerLayer ||
        imageLayer.superlayer != containerLayer) {
        return NO;
    }
    NSArray<CALayer *> *sublayers = containerLayer.sublayers;
    NSUInteger imageIndex = [sublayers indexOfObjectIdenticalTo:imageLayer];
    return imageIndex != NSNotFound && imageIndex > 0 &&
        sublayers[imageIndex - 1] == shadow;
}

@implementation MTIconShadowSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    _imageSets = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTIconShadowMaximumReadyImageSets
        maximumReadyCost:MTIconShadowMaximumReadyCost
        maximumPendingCount:MTIconShadowMaximumPendingImageSets
        maximumFailureCount:MTIconShadowMaximumFailureCount];
    _preparationQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.icon-shadow-preparation",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    _shadowLayers = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (_imageLoader == nil || _imageSets == nil ||
        _preparationQueue == nil || _shadowLayers == nil) {
        return nil;
    }
    return self;
}

- (nullable UIImage *)decodeResolution:
        (MTIconShadowSnapshotResolution *)resolution
                                  context:
        (MTIconShadowSnapshotContext *)context
                             residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    if (resolution == nil || context == nil ||
        resolution.targetPixelDimension == 0) {
        return nil;
    }
    MTRuntimePublishedImageResizePolicy resizePolicy =
        context.scale == 3
        ? MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
        : MTRuntimePublishedImageResizePolicyExactOrDownsample;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:resolution.targetPixelDimension
             targetPixelHeight:resolution.targetPixelDimension
                  resizePolicy:resizePolicy
                         error:NULL];
    if (decoded == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *image = [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)context.scale
        orientation:UIImageOrientationUp];
    if (image == nil ||
        fabs(image.size.width - resolution.canvasPointDimension) > 0.001 ||
        fabs(image.size.height - resolution.canvasPointDimension) > 0.001) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (nullable MTIconShadowImageSet *)buildImageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                        context:
        (MTIconShadowSnapshotContext *)context {
    MTGeneration *generation = snapshot.generation;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generation == nil ||
        generationIdentifier.length == 0 ||
        ![generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }
    NSDictionary<NSString *, id> *dictionary = generation.descriptor
        .moduleConfigurations[MTIconShadowsModuleID];
    MTIconShadowConfiguration *configuration = dictionary == nil ? nil :
        [[MTIconShadowConfiguration alloc]
            initWithDictionary:dictionary error:NULL];
    if (configuration == nil) return nil;

    MTIconShadowSnapshotResolver *resolver =
        [[MTIconShadowSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return snapshot;
            }];
    MTIconShadowSnapshotResolution *resolution = [resolver
        resolutionForVariant:configuration.defaultVariant
                      context:context
                        error:NULL];
    if (resolution == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.resourceHits,
        1, memory_order_relaxed);
    NSUInteger residentCost = 0;
    UIImage *image = [self decodeResolution:resolution
                                    context:context
                               residentCost:&residentCost];
    if (image == nil) return nil;

    MTIconShadowImageSet *imageSet = [[MTIconShadowImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.variant = configuration.defaultVariant;
    imageSet.context = context;
    imageSet.image = image;
    imageSet.residentCost = MAX((NSUInteger)1, residentCost);
    return imageSet;
}

- (void)notifyReadyHandler {
    dispatch_block_t handler = self.readyHandler;
    if (handler != nil) dispatch_async(dispatch_get_main_queue(), handler);
}

- (nullable MTIconShadowImageSet *)imageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                      context:
        (MTIconShadowSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generationIdentifier.length == 0 ||
        context == nil) {
        return nil;
    }
    MTIconShadowImageSet *ready = nil;
    uint64_t epoch = 0;
    MTRuntimeAsyncCacheDisposition disposition = [self.imageSets
        lookupObjectForGenerationIdentifier:generationIdentifier
        key:context.cacheKey object:&ready epoch:&epoch];
    if (disposition == MTRuntimeAsyncCacheDispositionReady) return ready;
    if (disposition != MTRuntimeAsyncCacheDispositionScheduled) return nil;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.preparationQueue, ^{
        @autoreleasepool {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || ![strongSelf.imageSets
                    claimPendingKey:context.cacheKey
                    generationIdentifier:generationIdentifier
                    epoch:epoch]) {
                return;
            }
            MTIconShadowImageSet *imageSet = [strongSelf
                buildImageSetForSnapshot:snapshot context:context];
            BOOL accepted = [strongSelf.imageSets
                completeKey:context.cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch object:imageSet
                cost:imageSet == nil ? 0 : imageSet.residentCost];
            if (!accepted) return;
            atomic_store_explicit(
                &MTRuntimeIconShadowSnapshotObservation.state,
                imageSet == nil ? MTIconShadowSnapshotModuleStateConfigured
                                : MTIconShadowSnapshotModuleStateReady,
                memory_order_release);
            MTRuntimeABIReportRecordModuleState(
                MTIconShadowSnapshotModuleID,
                imageSet == nil ? MTIconShadowSnapshotModuleStateConfigured
                                : MTIconShadowSnapshotModuleStateReady,
                imageSet == nil ? @"Configured" : @"Ready");
            if (imageSet != nil) [strongSelf notifyReadyHandler];
        }
    });
    return nil;
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.reloads,
        1, memory_order_relaxed);
    [self.imageSets purgeReadyObjectsAndCancelPending];
    atomic_store_explicit(
        &MTRuntimeIconShadowSnapshotObservation.state,
        MTIconShadowSnapshotModuleStateConfigured,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTIconShadowSnapshotModuleID, MTIconShadowSnapshotModuleStateConfigured, @"Configured");
    [self notifyReadyHandler];

    // The bootstrap has no UIKit context. Only reuse primitive values that a
    // real configured icon view supplied earlier.
    MTIconShadowSnapshotContext *context = self.lastContext;
    if (context != nil) {
        (void)[self imageSetForSnapshot:self.kernel.currentSnapshot
                                context:context];
    }
}

- (nullable MTIconShadowSnapshotContext *)contextForIconView:
        (UIView *)iconView
                                                  iconImageView:
        (UIView *)iconImageView {
    UITraitCollection *imageTraits = iconImageView.traitCollection;
    UITraitCollection *iconTraits = iconView.traitCollection;
    CGFloat displayScale = imageTraits.displayScale;
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = iconTraits.displayScale;
    }
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = iconImageView.layer.contentsScale;
    }
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = iconView.layer.contentsScale;
    }
    if (!isfinite(displayScale)) return nil;
    NSInteger roundedScale = (NSInteger)llround(displayScale);
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(displayScale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }

    CGSize iconSize = iconImageView.bounds.size;
    if (!isfinite(iconSize.width) || !isfinite(iconSize.height) ||
        iconSize.width < MTIconShadowMinimumIconPointDimension ||
        iconSize.height < MTIconShadowMinimumIconPointDimension ||
        iconSize.width > MTIconShadowMaximumIconPointDimension ||
        iconSize.height > MTIconShadowMaximumIconPointDimension ||
        fabs(iconSize.width - iconSize.height) > 1.0) {
        return nil;
    }
    UIUserInterfaceIdiom idiom = imageTraits.userInterfaceIdiom;
    if (idiom != UIUserInterfaceIdiomPhone &&
        idiom != UIUserInterfaceIdiomPad) {
        idiom = iconTraits.userInterfaceIdiom;
    }
    NSString *deviceTrait = nil;
    if (idiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else if (idiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    } else {
        return nil;
    }
    BOOL prefersLargeIPadCanvas = [deviceTrait isEqualToString:@"ipad"] &&
        MAX(iconSize.width, iconSize.height) >=
            MTIconShadowLargeIPadIconPointDimension;
    return [MTIconShadowSnapshotContext
        contextWithScale:(NSUInteger)roundedScale
        deviceTrait:deviceTrait
        prefersLargeIPadCanvas:prefersLargeIPadCanvas];
}

- (BOOL)removeShadowForIconView:(UIView *)iconView {
    CALayer *shadow = [self.shadowLayers objectForKey:iconView];
    if (shadow == nil) return NO;
    [shadow removeFromSuperlayer];
    [self.shadowLayers removeObjectForKey:iconView];
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.layersRemoved,
        1, memory_order_relaxed);
    return YES;
}

- (BOOL)resolveIconView:(UIView *)iconView
          iconImageView:(UIView *)iconImageView {
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.viewResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return NO;

    MTIconShadowSnapshotContext *context =
        [self contextForIconView:iconView iconImageView:iconImageView];
    if (context == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowSnapshotObservation.contextMisses,
            1, memory_order_relaxed);
        [self removeShadowForIconView:iconView];
        return NO;
    }
    self.lastContext = context;
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    MTIconShadowImageSet *imageSet = [self imageSetForSnapshot:snapshot
                                                       context:context];
    if (imageSet == nil ||
        ![imageSet.generationIdentifier isEqualToString:
            snapshot.state.activeGenerationIdentifier] ||
        ![imageSet.context isEqual:context]) {
        [self removeShadowForIconView:iconView];
        return NO;
    }

    CALayer *imageLayer = iconImageView.layer;
    CALayer *containerLayer = imageLayer.superlayer;
    if (containerLayer == nil) {
        [self removeShadowForIconView:iconView];
        return NO;
    }
    CALayer *shadow = [self.shadowLayers objectForKey:iconView];
    if (shadow == nil) {
        shadow = [CALayer layer];
        shadow.name = @"com.hmmzzz.marktheme.icon-shadow";
        shadow.contentsGravity = kCAGravityResizeAspect;
        shadow.masksToBounds = NO;
        shadow.opaque = NO;
        [self.shadowLayers setObject:shadow forKey:iconView];
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowSnapshotObservation.layersCreated,
            1, memory_order_relaxed);
    }

    id targetContents = (__bridge id)imageSet.image.CGImage;
    CGFloat targetContentsScale = imageSet.image.scale;
    CGRect targetBounds = (CGRect){ CGPointZero, imageSet.image.size };
    CGPoint targetPosition = imageLayer.position;
    CGPoint targetAnchorPoint = CGPointMake(0.5, 0.5);
    CATransform3D targetTransform = imageLayer.transform;
    float targetOpacity = imageLayer.opacity;
    BOOL targetHidden = imageLayer.hidden;
    BOOL needsPlacement =
        !MTIconShadowLayerIsImmediatelyBelowImageLayer(
            shadow, imageLayer, containerLayer);
    BOOL needsUpdate = needsPlacement || shadow.contents != targetContents ||
        shadow.contentsScale != targetContentsScale ||
        !CGRectEqualToRect(shadow.bounds, targetBounds) ||
        !CGPointEqualToPoint(shadow.position, targetPosition) ||
        !CGPointEqualToPoint(shadow.anchorPoint, targetAnchorPoint) ||
        !CATransform3DEqualToTransform(shadow.transform, targetTransform) ||
        shadow.opacity != targetOpacity || shadow.hidden != targetHidden;
    if (!needsUpdate) return YES;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (needsPlacement) {
        if (shadow.superlayer != containerLayer) {
            [shadow removeFromSuperlayer];
        }
        [containerLayer insertSublayer:shadow below:imageLayer];
    }
    if (shadow.contents != targetContents) shadow.contents = targetContents;
    if (shadow.contentsScale != targetContentsScale) {
        shadow.contentsScale = targetContentsScale;
    }
    if (!CGRectEqualToRect(shadow.bounds, targetBounds)) {
        shadow.bounds = targetBounds;
    }
    if (!CGPointEqualToPoint(shadow.position, targetPosition)) {
        shadow.position = targetPosition;
    }
    if (!CGPointEqualToPoint(shadow.anchorPoint, targetAnchorPoint)) {
        shadow.anchorPoint = targetAnchorPoint;
    }
    if (!CATransform3DEqualToTransform(
            shadow.transform, targetTransform)) {
        shadow.transform = targetTransform;
    }
    if (shadow.opacity != targetOpacity) shadow.opacity = targetOpacity;
    if (shadow.hidden != targetHidden) shadow.hidden = targetHidden;
    [CATransaction commit];
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.layerUpdates,
        1, memory_order_relaxed);
    return YES;
}

- (void)forgetIconView:(UIView *)iconView
          iconImageView:(UIView *)iconImageView {
    (void)iconImageView;
    if (![NSThread isMainThread]) return;
    [self removeShadowForIconView:iconView];
}

@end

static os_unfair_lock MTIconShadowSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTIconShadowSnapshotModule *MTIconShadowSnapshotInstance;

BOOL MTIconShadowSnapshotConfigure(MTRuntimeKernel *kernel,
                                   NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTIconShadowSnapshotLock);
    if (MTIconShadowSnapshotInstance == nil) {
        MTIconShadowSnapshotInstance = [[MTIconShadowSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTIconShadowSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTIconShadowSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeIconShadowSnapshotObservation.state,
            MTIconShadowSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTIconShadowSnapshotModuleID, MTIconShadowSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.icon-shadow-snapshot"
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Icon Shadow snapshot module could not initialize."
        }];
    }
    return configured;
}

void MTIconShadowSnapshotReload(void) {
    [MTIconShadowSnapshotInstance reload];
}

void MTIconShadowSnapshotSetReadyHandler(dispatch_block_t handler) {
    MTIconShadowSnapshotInstance.readyHandler = handler;
}

BOOL MTIconShadowSnapshotResolveView(id iconView, id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconView isKindOfClass:UIView.class] ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return NO;
    }
    return [MTIconShadowSnapshotInstance resolveIconView:iconView
                                           iconImageView:iconImageView];
}

void MTIconShadowSnapshotForgetView(id iconView, id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconView isKindOfClass:UIView.class]) {
        return;
    }
    UIView *imageView = [iconImageView isKindOfClass:UIView.class]
        ? iconImageView : nil;
    [MTIconShadowSnapshotInstance forgetIconView:iconView
                                    iconImageView:imageView];
}
