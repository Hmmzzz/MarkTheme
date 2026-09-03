#import "MTIconShadowSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTIconShadowConfiguration.h"
#import "MTIconShadowContract.h"
#import "MTIconShadowSnapshotResolver.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

#include <math.h>

NSString *const MTIconShadowSnapshotModuleID = @"icon-shadow.snapshot";

static const CGFloat MTIconShadowMinimumIconPointDimension = 20.0;
static const CGFloat MTIconShadowMaximumIconPointDimension = 100.0;
static const CGFloat MTIconShadowLargeIPadIconPointDimension = 80.0;
static char MTIconShadowAttachmentKey;
static char MTIconShadowSuspensionCountKey;
static char MTIconShadowRestoreAfterSuspensionKey;

MTIconShadowSnapshotObservation MTRuntimeIconShadowSnapshotObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTIconShadowSnapshotModuleStateDormant),
    .preparationAttempts = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .carrierResolutions = ATOMIC_VAR_INIT(0),
    .attachmentsCreated = ATOMIC_VAR_INIT(0),
    .attachmentUpdates = ATOMIC_VAR_INIT(0),
    .attachmentsRemoved = ATOMIC_VAR_INIT(0),
    .contextMisses = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconShadowSnapshotObservation) == 80,
    "Icon Shadow carrier ModuleRuntime observation ABI changed");

@interface MTIconShadowImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTIconShadowSnapshotContext *context;
@property(nonatomic, strong) UIImage *image;
@end

@implementation MTIconShadowImageSet
@end

@interface MTIconShadowLayerAttachment : NSObject
@property(nonatomic, strong) CALayer *shadowLayer;
@end

@implementation MTIconShadowLayerAttachment

- (void)dealloc {
    [_shadowLayer removeFromSuperlayer];
}

@end


@interface MTIconShadowSnapshotModule : NSObject
@property(nonatomic, strong) MTRuntimeSnapshot *snapshot;
@property(nonatomic, strong, nullable)
    MTIconShadowConfiguration *configuration;
@property(nonatomic, strong) MTIconShadowSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, MTIconShadowImageSet *> *imageSets;
@property(nonatomic, strong) NSMutableSet<NSString *> *attemptedContexts;
@property(nonatomic, assign) NSUInteger folderTransitionCount;
@property(nonatomic, strong) NSHashTable<UIView *> *
    folderTransitionDeferredCarriers;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (BOOL)prepare;
- (BOOL)applyToCarrier:(UIView *)carrier;
- (void)clearCarrier:(UIView *)carrier;
- (void)setAlpha:(CGFloat)alpha forCarrier:(UIView *)carrier;
- (void)suspendCarrier:(UIView *)carrier;
- (void)resumeCarrier:(UIView *)carrier;
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
    MTRuntimeSnapshot *snapshot = kernel.currentSnapshot;
    _snapshot = snapshot;
    NSDictionary<NSString *, id> *dictionary = snapshot.generation.descriptor
        .moduleConfigurations[MTIconShadowsModuleID];
    _configuration = dictionary == nil ? nil :
        [[MTIconShadowConfiguration alloc]
            initWithDictionary:dictionary error:NULL];
    _resolver = [[MTIconShadowSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    _imageSets = [NSMutableDictionary dictionaryWithCapacity:2];
    _attemptedContexts = [NSMutableSet setWithCapacity:2];
    _folderTransitionDeferredCarriers = [NSHashTable weakObjectsHashTable];
    if (_snapshot == nil || _resolver == nil || _imageLoader == nil ||
        _imageSets == nil || _attemptedContexts == nil ||
        _folderTransitionDeferredCarriers == nil) {
        return nil;
    }
    return self;
}

- (BOOL)prepare {
    return self.snapshot != nil && self.resolver != nil &&
        self.imageLoader != nil && self.imageSets != nil &&
        self.attemptedContexts != nil &&
        self.folderTransitionDeferredCarriers != nil;
}

- (nullable UIImage *)decodeResolution:
        (MTIconShadowSnapshotResolution *)resolution
                                  context:
        (MTIconShadowSnapshotContext *)context {
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
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (nullable MTIconShadowImageSet *)buildImageSetForContext:
        (MTIconShadowSnapshotContext *)context {
    MTRuntimeSnapshot *snapshot = self.snapshot;
    MTGeneration *generation = snapshot.generation;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generation == nil ||
        generationIdentifier.length == 0 || context == nil ||
        self.configuration == nil ||
        ![generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }

    MTIconShadowSnapshotResolution *resolution = [self.resolver
        resolutionForVariant:self.configuration.defaultVariant
                      context:context
                        error:NULL];
    if (resolution == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.resourceHits,
        1, memory_order_relaxed);
    UIImage *image = [self decodeResolution:resolution context:context];
    if (image == nil) return nil;

    MTIconShadowImageSet *imageSet = [[MTIconShadowImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.context = context;
    imageSet.image = image;
    return imageSet;
}

- (nullable MTIconShadowSnapshotContext *)contextForCarrier:
        (UIView *)carrier {
    UITraitCollection *traits = carrier.traitCollection;
    CGFloat displayScale = traits.displayScale;
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = carrier.layer.contentsScale;
    }
    if (!isfinite(displayScale)) return nil;
    NSInteger roundedScale = (NSInteger)llround(displayScale);
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(displayScale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }

    CGSize iconSize = carrier.bounds.size;
    if (!isfinite(iconSize.width) || !isfinite(iconSize.height) ||
        iconSize.width < MTIconShadowMinimumIconPointDimension ||
        iconSize.height < MTIconShadowMinimumIconPointDimension ||
        iconSize.width > MTIconShadowMaximumIconPointDimension ||
        iconSize.height > MTIconShadowMaximumIconPointDimension ||
        fabs(iconSize.width - iconSize.height) > 1.0) {
        return nil;
    }

    NSString *deviceTrait = nil;
    if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    } else {
        return nil;
    }
    BOOL largeIPadCanvas = [deviceTrait isEqualToString:@"ipad"] &&
        MAX(iconSize.width, iconSize.height) >=
            MTIconShadowLargeIPadIconPointDimension;
    return [MTIconShadowSnapshotContext
        contextWithScale:(NSUInteger)roundedScale
             deviceTrait:deviceTrait
        prefersLargeIPadCanvas:largeIPadCanvas];
}

- (nullable MTIconShadowImageSet *)imageSetForContext:
        (MTIconShadowSnapshotContext *)context {
    // The first real carrier layout reaches this boundary after UIKit has
    // supplied exact traits. Each immutable context is attempted only once.
    MTIconShadowImageSet *imageSet = self.imageSets[context.cacheKey];
    if (imageSet != nil ||
        [self.attemptedContexts containsObject:context.cacheKey]) {
        return imageSet;
    }
    [self.attemptedContexts addObject:context.cacheKey];
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.preparationAttempts,
        1, memory_order_relaxed);
    imageSet = [self buildImageSetForContext:context];
    if (imageSet != nil) self.imageSets[context.cacheKey] = imageSet;
    uint32_t state = self.imageSets.count == 0
        ? MTIconShadowSnapshotModuleStateConfigured
        : MTIconShadowSnapshotModuleStateReady;
    atomic_store_explicit(
        &MTRuntimeIconShadowSnapshotObservation.state,
        state, memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTIconShadowSnapshotModuleID, state,
        state == MTIconShadowSnapshotModuleStateReady
            ? @"Ready" : @"Configured");
    return imageSet;
}

- (nullable MTIconShadowLayerAttachment *)attachmentForCarrier:
        (UIView *)carrier
                                                       create:(BOOL)create {
    MTIconShadowLayerAttachment *attachment = objc_getAssociatedObject(
        carrier, &MTIconShadowAttachmentKey);
    if (attachment != nil || !create) return attachment;
    attachment = [[MTIconShadowLayerAttachment alloc] init];
    CALayer *layer = [CALayer layer];
    layer.name = @"com.hmmzzz.marktheme.icon-shadow";
    layer.contentsGravity = kCAGravityResizeAspect;
    layer.masksToBounds = NO;
    layer.opaque = NO;
    attachment.shadowLayer = layer;
    objc_setAssociatedObject(
        carrier, &MTIconShadowAttachmentKey, attachment,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.attachmentsCreated,
        1, memory_order_relaxed);
    return attachment;
}

- (void)clearCarrier:(UIView *)carrier {
    if (![NSThread isMainThread]) return;
    MTIconShadowLayerAttachment *attachment = [self
        attachmentForCarrier:carrier create:NO];
    if (attachment == nil) return;
    [attachment.shadowLayer removeFromSuperlayer];
    objc_setAssociatedObject(
        carrier, &MTIconShadowAttachmentKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.attachmentsRemoved,
        1, memory_order_relaxed);
}

- (void)setAlpha:(CGFloat)alpha forCarrier:(UIView *)carrier {
    if (![NSThread isMainThread] || !isfinite(alpha)) return;
    MTIconShadowLayerAttachment *attachment = [self
        attachmentForCarrier:carrier create:NO];
    CALayer *shadow = attachment.shadowLayer;
    if (shadow == nil || shadow.superlayer == nil) return;
    float targetOpacity = (float)fmin(1.0, fmax(0.0, alpha));
    if (shadow.opacity == targetOpacity) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shadow.opacity = targetOpacity;
    [CATransaction commit];
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.attachmentUpdates,
        1, memory_order_relaxed);
}

- (NSUInteger)suspensionCountForCarrier:(UIView *)carrier {
    NSNumber *count = objc_getAssociatedObject(
        carrier, &MTIconShadowSuspensionCountKey);
    return [count isKindOfClass:NSNumber.class]
        ? count.unsignedIntegerValue : 0;
}

- (void)suspendCarrier:(UIView *)carrier {
    if (![NSThread isMainThread]) return;
    NSUInteger count = [self suspensionCountForCarrier:carrier];
    if (count == NSUIntegerMax) return;
    if (count == 0 && [self attachmentForCarrier:carrier create:NO] != nil) {
        objc_setAssociatedObject(
            carrier, &MTIconShadowRestoreAfterSuspensionKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(
        carrier, &MTIconShadowSuspensionCountKey, @(count + 1),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self clearCarrier:carrier];
}

- (void)resumeCarrier:(UIView *)carrier {
    if (![NSThread isMainThread]) return;
    NSUInteger count = [self suspensionCountForCarrier:carrier];
    if (count == 0) return;
    count--;
    BOOL shouldRestore = [objc_getAssociatedObject(
        carrier, &MTIconShadowRestoreAfterSuspensionKey) boolValue];
    objc_setAssociatedObject(
        carrier, &MTIconShadowSuspensionCountKey,
        count == 0 ? nil : @(count),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (count == 0) {
        objc_setAssociatedObject(
            carrier, &MTIconShadowRestoreAfterSuspensionKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (shouldRestore) [self applyToCarrier:carrier];
    }
}

- (BOOL)applyToCarrier:(UIView *)carrier {
    atomic_fetch_add_explicit(
        &MTRuntimeIconShadowSnapshotObservation.carrierResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return NO;

    if (self.folderTransitionCount != 0) {
        [self.folderTransitionDeferredCarriers addObject:carrier];
        [self clearCarrier:carrier];
        return NO;
    }
    if ([self suspensionCountForCarrier:carrier] != 0) {
        objc_setAssociatedObject(
            carrier, &MTIconShadowRestoreAfterSuspensionKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self clearCarrier:carrier];
        return NO;
    }

    MTIconShadowSnapshotContext *context = [self
        contextForCarrier:carrier];
    if (context == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconShadowSnapshotObservation.contextMisses,
            1, memory_order_relaxed);
        [self clearCarrier:carrier];
        return NO;
    }
    MTIconShadowImageSet *imageSet = [self imageSetForContext:context];
    if (imageSet == nil || ![imageSet.context isEqual:context]) {
        [self clearCarrier:carrier];
        return NO;
    }

    CALayer *imageLayer = carrier.layer;
    CALayer *containerLayer = imageLayer.superlayer;
    if (containerLayer == nil) {
        [self clearCarrier:carrier];
        return NO;
    }
    MTIconShadowLayerAttachment *attachment = [self
        attachmentForCarrier:carrier create:YES];
    CALayer *shadow = attachment.shadowLayer;
    if (shadow == nil) {
        [self clearCarrier:carrier];
        return NO;
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
        &MTRuntimeIconShadowSnapshotObservation.attachmentUpdates,
        1, memory_order_relaxed);
    return YES;
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
            MTIconShadowSnapshotModuleID,
            MTIconShadowSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError errorWithDomain:
            @"com.hmmzzz.marktheme.icon-shadow-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"Icon Shadow snapshot module could not initialize."
        }];
    }
    return configured;
}

BOOL MTIconShadowSnapshotPrepare(void) {
    return [MTIconShadowSnapshotInstance prepare];
}

BOOL MTIconShadowSnapshotApplyToCarrier(id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return NO;
    }
    return [MTIconShadowSnapshotInstance applyToCarrier:iconImageView];
}

void MTIconShadowSnapshotClearCarrier(id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return;
    }
    objc_setAssociatedObject(
        iconImageView, &MTIconShadowRestoreAfterSuspensionKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [MTIconShadowSnapshotInstance clearCarrier:iconImageView];
}

void MTIconShadowSnapshotSetCarrierAlpha(id iconImageView,
                                         CGFloat alpha) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return;
    }
    [MTIconShadowSnapshotInstance setAlpha:alpha
                                forCarrier:iconImageView];
}

void MTIconShadowSnapshotSuspendCarrier(id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return;
    }
    [MTIconShadowSnapshotInstance suspendCarrier:iconImageView];
}

void MTIconShadowSnapshotResumeCarrier(id iconImageView) {
    if (MTIconShadowSnapshotInstance == nil ||
        ![iconImageView isKindOfClass:UIView.class]) {
        return;
    }
    [MTIconShadowSnapshotInstance resumeCarrier:iconImageView];
}

void MTIconShadowSnapshotBeginFolderTransition(void) {
    if (![NSThread isMainThread] ||
        MTIconShadowSnapshotInstance == nil) return;
    NSUInteger count = MTIconShadowSnapshotInstance.folderTransitionCount;
    if (count != NSUIntegerMax) {
        if (count == 0) {
            [MTIconShadowSnapshotInstance.folderTransitionDeferredCarriers
                removeAllObjects];
        }
        MTIconShadowSnapshotInstance.folderTransitionCount = count + 1;
    }
}

void MTIconShadowSnapshotEndFolderTransition(void) {
    if (![NSThread isMainThread] ||
        MTIconShadowSnapshotInstance == nil) return;
    NSUInteger count = MTIconShadowSnapshotInstance.folderTransitionCount;
    if (count != 0) {
        count--;
        MTIconShadowSnapshotInstance.folderTransitionCount = count;
        if (count == 0) {
            NSArray<UIView *> *carriers =
                MTIconShadowSnapshotInstance
                    .folderTransitionDeferredCarriers.allObjects;
            [MTIconShadowSnapshotInstance.folderTransitionDeferredCarriers
                removeAllObjects];
            for (UIView *carrier in carriers) {
                [MTIconShadowSnapshotInstance applyToCarrier:carrier];
            }
        }
    }
}
