#import "MTBadgeSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "MTBadgeConfiguration.h"
#import "MTBadgeContract.h"
#import "MTBadgeSnapshotResolver.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"

#include <math.h>

NSString *const MTBadgeSnapshotModuleID = @"badges.snapshot";

static const uint32_t MTBadgePointDimension = 23;
static const NSUInteger MTBadgeMaximumReadyImageSets = 2;
static const NSUInteger MTBadgeMaximumReadyCost = 512 * 1024;
static const NSUInteger MTBadgeMaximumPendingImageSets = 2;
static const NSUInteger MTBadgeMaximumFailureCount = 4;

MTBadgeSnapshotObservation MTRuntimeBadgeSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTBadgeSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .lightResourceHits = ATOMIC_VAR_INIT(0),
    .darkResourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .imageResolutions = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
    .originalImagesRestored = ATOMIC_VAR_INIT(0),
    .forgottenViews = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTBadgeSnapshotObservation) == 80,
    "The Badge ModuleRuntime observation layout must remain fixed.");

@interface MTBadgeImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy) NSString *variant;
@property(nonatomic, strong) MTBadgeSnapshotContext *context;
@property(nonatomic, strong) UIImage *lightBackground;
@property(nonatomic, strong) UIImage *darkBackground;
@property(nonatomic, assign) NSUInteger residentCost;
@end

@implementation MTBadgeImageSet
@end

@interface MTBadgeSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<MTBadgeImageSet *> *imageSets;
@property(nonatomic, strong) dispatch_queue_t preparationQueue;
@property(atomic, strong, nullable) MTBadgeSnapshotContext *lastContext;
@property(atomic, copy, nullable) dispatch_block_t readyHandler;
@property(nonatomic, strong) NSMapTable<UIView *, id> *originalImages;
@property(nonatomic, strong) NSMapTable<UIView *, UIImage *> *replacementImages;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)reload;
- (nullable UIImage *)resolveBadgeView:(UIView *)badgeView
                        backgroundView:(UIImageView *)backgroundView
                         originalImage:(nullable UIImage *)originalImage
                            didReplace:(BOOL *)didReplace;
- (void)forgetBadgeView:(UIView *)badgeView
          backgroundView:(nullable UIImageView *)backgroundView;
@end

@implementation MTBadgeSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    _imageSets = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTBadgeMaximumReadyImageSets
        maximumReadyCost:MTBadgeMaximumReadyCost
        maximumPendingCount:MTBadgeMaximumPendingImageSets
        maximumFailureCount:MTBadgeMaximumFailureCount];
    _preparationQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.badge-preparation",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    _originalImages = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    _replacementImages = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (_imageLoader == nil || _imageSets == nil ||
        _preparationQueue == nil || _originalImages == nil ||
        _replacementImages == nil) {
        return nil;
    }
    return self;
}

- (nullable UIImage *)decodeResolution:
        (MTBadgeSnapshotResolution *)resolution
                                  scale:(NSUInteger)scale
                           residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    if (resolution == nil || scale == 0 || scale > 3) return nil;
    uint32_t pixelDimension = MTBadgePointDimension * (uint32_t)scale;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:pixelDimension
             targetPixelHeight:pixelDimension
                         error:NULL];
    if (decoded == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *image = [[UIImage alloc]
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
    if (residentCost != NULL) *residentCost = decoded.residentCost;
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
        generationIdentifier.length == 0 ||
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

    MTBadgeSnapshotResolver *resolver = [[MTBadgeSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    MTBadgeSnapshotResolution *light = [resolver
        resolutionForVariant:configuration.defaultVariant
                        scale:context.scale
                  deviceTrait:context.deviceTrait
                   appearance:MTBadgeAppearanceLight
                        error:NULL];
    if (light == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.lightResourceHits,
        1, memory_order_relaxed);
    NSUInteger lightCost = 0;
    UIImage *lightImage = [self decodeResolution:light
                                            scale:context.scale
                                     residentCost:&lightCost];
    if (lightImage == nil) return nil;

    MTBadgeSnapshotResolution *dark = [resolver
        resolutionForVariant:configuration.defaultVariant
                        scale:context.scale
                  deviceTrait:context.deviceTrait
                   appearance:MTBadgeAppearanceDark
                        error:NULL];
    if (dark == nil) return nil;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.darkResourceHits,
        1, memory_order_relaxed);
    NSUInteger darkCost = 0;
    UIImage *darkImage = nil;
    if ([dark.resource.contentSHA256
            isEqualToString:light.resource.contentSHA256]) {
        darkImage = lightImage;
    } else {
        darkImage = [self decodeResolution:dark
                                      scale:context.scale
                               residentCost:&darkCost];
    }
    if (darkImage == nil || lightCost > NSUIntegerMax - darkCost) return nil;

    MTBadgeImageSet *imageSet = [[MTBadgeImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.variant = configuration.defaultVariant;
    imageSet.context = context;
    imageSet.lightBackground = lightImage;
    imageSet.darkBackground = darkImage;
    imageSet.residentCost = MAX((NSUInteger)1, lightCost + darkCost);
    return imageSet;
}

- (void)notifyReadyHandler {
    dispatch_block_t handler = self.readyHandler;
    if (handler != nil) dispatch_async(dispatch_get_main_queue(), handler);
}

- (nullable MTBadgeImageSet *)imageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                 context:
        (MTBadgeSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generationIdentifier.length == 0 ||
        context == nil) {
        return nil;
    }

    MTBadgeImageSet *ready = nil;
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
            MTBadgeImageSet *imageSet = [strongSelf
                buildImageSetForSnapshot:snapshot context:context];
            BOOL accepted = [strongSelf.imageSets
                completeKey:context.cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch
                object:imageSet
                cost:imageSet == nil ? 0 : imageSet.residentCost];
            if (!accepted) return;
            atomic_store_explicit(
                &MTRuntimeBadgeSnapshotObservation.state,
                imageSet == nil ? MTBadgeSnapshotModuleStateConfigured
                                : MTBadgeSnapshotModuleStateReady,
                memory_order_release);
            if (imageSet != nil) [strongSelf notifyReadyHandler];
        }
    });
    return nil;
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.reloads,
        1, memory_order_relaxed);
    [self.imageSets purgeReadyObjectsAndCancelPending];
    atomic_store_explicit(
        &MTRuntimeBadgeSnapshotObservation.state,
        MTBadgeSnapshotModuleStateConfigured,
        memory_order_release);

    // Invalidate visible replacements first. Refresh runs asynchronously on
    // the UI owner queue and therefore restores stock without blocking the
    // Runtime reload queue or constructor.
    [self notifyReadyHandler];

    // Once an actual Badge view has supplied a valid primitive context, it is
    // safe to reuse those values for later Generation changes. The initial
    // bootstrap has no context and performs no decode here.
    MTBadgeSnapshotContext *context = self.lastContext;
    if (context != nil) {
        (void)[self imageSetForSnapshot:self.kernel.currentSnapshot
                                context:context];
    }
}

- (nullable MTBadgeSnapshotContext *)contextForTraitCollection:
        (UITraitCollection *)traits {
    if (![traits isKindOfClass:UITraitCollection.class] ||
        !isfinite(traits.displayScale)) {
        return nil;
    }
    NSInteger roundedScale = (NSInteger)llround(traits.displayScale);
    if (roundedScale < 1 || roundedScale > 3) return nil;
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

- (nullable UIImage *)stockImageForBackgroundView:
        (UIImageView *)backgroundView
                                      originalImage:
        (nullable UIImage *)originalImage
                                previousReplacement:
        (nullable UIImage *)previousReplacement
                                        didReplace:(BOOL *)didReplace {
    if (previousReplacement != nil &&
        originalImage == previousReplacement) {
        id stored = [self.originalImages objectForKey:backgroundView];
        UIImage *restored = stored == NSNull.null ? nil : stored;
        [self.replacementImages removeObjectForKey:backgroundView];
        [self.originalImages removeObjectForKey:backgroundView];
        if (didReplace != NULL) *didReplace = YES;
        atomic_fetch_add_explicit(
            &MTRuntimeBadgeSnapshotObservation.originalImagesRestored,
            1, memory_order_relaxed);
        return restored;
    }
    [self.replacementImages removeObjectForKey:backgroundView];
    [self.originalImages removeObjectForKey:backgroundView];
    return originalImage;
}

- (UIImage *)resolveBadgeView:(UIView *)badgeView
               backgroundView:(UIImageView *)backgroundView
                originalImage:(UIImage *)originalImage
                   didReplace:(BOOL *)didReplace {
    if (didReplace != NULL) *didReplace = NO;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.imageResolutions,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return originalImage;

    UIImage *previousReplacement =
        [self.replacementImages objectForKey:backgroundView];
    if (originalImage != previousReplacement) {
        [self.originalImages setObject:originalImage ?: NSNull.null
                                forKey:backgroundView];
    }

    UITraitCollection *traits = badgeView.traitCollection;
    MTBadgeSnapshotContext *context =
        [self contextForTraitCollection:traits];
    if (context == nil) {
        traits = backgroundView.traitCollection;
        context = [self contextForTraitCollection:traits];
    }
    if (context == nil) {
        return [self stockImageForBackgroundView:backgroundView
                                   originalImage:originalImage
                             previousReplacement:previousReplacement
                                     didReplace:didReplace];
    }
    self.lastContext = context;

    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    MTBadgeImageSet *imageSet = [self imageSetForSnapshot:snapshot
                                                  context:context];
    NSString *activeGenerationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (imageSet == nil ||
        ![imageSet.generationIdentifier
            isEqualToString:activeGenerationIdentifier] ||
        ![imageSet.context isEqual:context]) {
        return [self stockImageForBackgroundView:backgroundView
                                   originalImage:originalImage
                             previousReplacement:previousReplacement
                                     didReplace:didReplace];
    }

    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIImage *replacement = dark ? imageSet.darkBackground
                                : imageSet.lightBackground;
    [self.replacementImages setObject:replacement forKey:backgroundView];
    if (replacement == originalImage) return originalImage;
    if (didReplace != NULL) *didReplace = YES;
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.replacementResults,
        1, memory_order_relaxed);
    return replacement;
}

- (void)forgetBadgeView:(UIView *)badgeView
          backgroundView:(UIImageView *)backgroundView {
    (void)badgeView;
    if (backgroundView != nil) {
        [self.originalImages removeObjectForKey:backgroundView];
        [self.replacementImages removeObjectForKey:backgroundView];
    }
    atomic_fetch_add_explicit(
        &MTRuntimeBadgeSnapshotObservation.forgottenViews,
        1, memory_order_relaxed);
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
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.badge-snapshot"
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

void MTBadgeSnapshotSetReadyHandler(dispatch_block_t handler) {
    MTBadgeSnapshotInstance.readyHandler = handler;
}

id MTBadgeSnapshotResolveBackgroundImage(id badgeView,
                                         id backgroundView,
                                         id originalImage,
                                         BOOL *didReplace) {
    if (didReplace != NULL) *didReplace = NO;
    if (MTBadgeSnapshotInstance == nil ||
        ![badgeView isKindOfClass:UIView.class] ||
        ![backgroundView isKindOfClass:UIImageView.class] ||
        (originalImage != nil &&
         ![originalImage isKindOfClass:UIImage.class])) {
        return originalImage;
    }
    return [MTBadgeSnapshotInstance
        resolveBadgeView:badgeView
        backgroundView:backgroundView
        originalImage:originalImage
        didReplace:didReplace];
}

void MTBadgeSnapshotForgetBadgeView(id badgeView, id backgroundView) {
    if (MTBadgeSnapshotInstance == nil ||
        ![badgeView isKindOfClass:UIView.class]) {
        return;
    }
    UIImageView *imageView = [backgroundView
        isKindOfClass:UIImageView.class] ? backgroundView : nil;
    [MTBadgeSnapshotInstance forgetBadgeView:badgeView
                               backgroundView:imageView];
}
