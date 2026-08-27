#import "MTStatusBarSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTGenerationDescriptor.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStatusBarSnapshotResolver.h"
#import "MTRuntimeABIReport.h"

NSString *const MTStatusBarSnapshotModuleID = @"statusbar.snapshot";

static const NSUInteger MTStatusBarMaximumReadyImageSets = 2;
static const NSUInteger MTStatusBarMaximumReadyCost = 4 * 1024 * 1024;
static const NSUInteger MTStatusBarMaximumPendingImageSets = 2;
static const NSUInteger MTStatusBarMaximumFailureCount = 4;
static const uint64_t MTStatusBarMaximumEncodedImageBytes = 1024 * 1024;
static const uint64_t MTStatusBarMaximumDecodedImageBytes = 128 * 128 * 4;
static _Atomic(uint32_t) MTStatusBarResourcesAvailable = ATOMIC_VAR_INIT(0);

MTStatusBarSnapshotObservation MTRuntimeStatusBarSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTStatusBarSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .contextRequests = ATOMIC_VAR_INIT(0),
    .contextMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .imageSetsReady = ATOMIC_VAR_INIT(0),
    .imageResolutions = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTStatusBarSnapshotObservation) == 80,
    "The Status Bar ModuleRuntime observation layout must remain fixed.");

@interface MTStatusBarSignalPresentation : NSObject
@property(nonatomic, strong)
    NSMapTable<CALayer *, NSNumber *> *stockLayerOpacities;
@property(nonatomic, strong, nullable) id originalContents;
@property(nonatomic, copy, nullable)
    CALayerContentsGravity originalContentsGravity;
@property(nonatomic, assign) CGFloat originalContentsScale;
@property(nonatomic, strong, nullable) id presentedContents;
@property(nonatomic, copy, nullable) NSString *presentedGenerationIdentifier;
@property(nonatomic, copy, nullable) NSString *presentedSubject;
@property(nonatomic, copy, nullable) NSString *presentedContextKey;
@property(nonatomic, assign) CGFloat presentedContentsScale;
@property(nonatomic, assign) BOOL capturedRootState;
@property(nonatomic, assign) BOOL themed;
@end

@implementation MTStatusBarSignalPresentation
@end

static char MTStatusBarPresentationAssociationKey;

static MTStatusBarSignalPresentation *MTStatusBarPresentationForView(
    UIView *view,
    BOOL create) {
    MTStatusBarSignalPresentation *presentation =
        objc_getAssociatedObject(
            view, &MTStatusBarPresentationAssociationKey);
    if (presentation != nil || !create) return presentation;
    presentation = [[MTStatusBarSignalPresentation alloc] init];
    presentation.stockLayerOpacities = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (presentation.stockLayerOpacities == nil) return nil;
    objc_setAssociatedObject(view, &MTStatusBarPresentationAssociationKey,
        presentation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return presentation;
}

static BOOL MTStatusBarRestoreStockPresentation(UIView *view) {
    MTStatusBarSignalPresentation *presentation =
        MTStatusBarPresentationForView(view, NO);
    if (presentation == nil || !presentation.themed) return NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray<CALayer *> *layers =
        presentation.stockLayerOpacities.keyEnumerator.allObjects;
    for (CALayer *layer in layers) {
        NSNumber *opacity =
            [presentation.stockLayerOpacities objectForKey:layer];
        if (opacity != nil) layer.opacity = opacity.floatValue;
    }
    [presentation.stockLayerOpacities removeAllObjects];
    if (presentation.capturedRootState) {
        CALayer *rootLayer = view.layer;
        rootLayer.contents = presentation.originalContents;
        rootLayer.contentsScale = presentation.originalContentsScale;
        rootLayer.contentsGravity = presentation.originalContentsGravity;
    }
    [CATransaction commit];
    presentation.originalContents = nil;
    presentation.originalContentsGravity = nil;
    presentation.presentedContents = nil;
    presentation.presentedGenerationIdentifier = nil;
    presentation.presentedSubject = nil;
    presentation.presentedContextKey = nil;
    presentation.presentedContentsScale = 0;
    presentation.capturedRootState = NO;
    presentation.themed = NO;
    return YES;
}

static BOOL MTStatusBarPresentationIsCurrent(
    UIView *view,
    NSString *generationIdentifier,
    NSString *subject,
    NSString *contextKey) {
    MTStatusBarSignalPresentation *presentation =
        MTStatusBarPresentationForView(view, NO);
    if (presentation == nil || !presentation.themed ||
        ![presentation.presentedGenerationIdentifier
            isEqualToString:generationIdentifier] ||
        ![presentation.presentedSubject isEqualToString:subject] ||
        ![presentation.presentedContextKey isEqualToString:contextKey]) {
        return NO;
    }
    CALayer *rootLayer = view.layer;
    if (rootLayer.contents != presentation.presentedContents ||
        rootLayer.contentsScale != presentation.presentedContentsScale ||
        ![rootLayer.contentsGravity isEqualToString:kCAGravityResizeAspect]) {
        return NO;
    }
    for (CALayer *layer in rootLayer.sublayers ?: @[]) {
        if ([presentation.stockLayerOpacities objectForKey:layer] == nil ||
            layer.opacity != 0.0f) {
            return NO;
        }
    }
    return YES;
}

static BOOL MTStatusBarApplyThemePresentation(
    UIView *view,
    UIImage *image,
    NSString *generationIdentifier,
    NSString *subject,
    NSString *contextKey) {
    CGImageRef imageRef = image.CGImage;
    if (imageRef == NULL) return NO;
    MTStatusBarSignalPresentation *presentation =
        MTStatusBarPresentationForView(view, YES);
    if (presentation == nil) return NO;
    CALayer *rootLayer = view.layer;
    if (!presentation.themed) {
        presentation.originalContents = rootLayer.contents;
        presentation.originalContentsScale = rootLayer.contentsScale;
        presentation.originalContentsGravity = rootLayer.contentsGravity;
        presentation.capturedRootState = YES;
    } else if (rootLayer.contents != presentation.presentedContents) {
        // Preserve a newer stock raster published by original-first system
        // work while the theme is active.
        presentation.originalContents = rootLayer.contents;
        presentation.originalContentsScale = rootLayer.contentsScale;
        presentation.originalContentsGravity = rootLayer.contentsGravity;
        presentation.capturedRootState = YES;
    }

    // SystemStatusUI indexes these direct layers in _updateActiveBars. Keep
    // their count, order, ownership, and identity untouched; only suppress
    // their visible output while the theme raster occupies the existing root
    // layer contents slot.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray<CALayer *> *stockLayers = [rootLayer.sublayers copy] ?: @[];
    for (CALayer *layer in stockLayers) {
        NSNumber *stored =
            [presentation.stockLayerOpacities objectForKey:layer];
        if (stored == nil || layer.opacity != 0.0f) {
            [presentation.stockLayerOpacities setObject:@(layer.opacity)
                                                 forKey:layer];
        }
        layer.opacity = 0.0f;
    }
    presentation.presentedContents = (__bridge id)imageRef;
    presentation.presentedGenerationIdentifier = generationIdentifier;
    presentation.presentedSubject = subject;
    presentation.presentedContextKey = contextKey;
    presentation.presentedContentsScale = image.scale;
    rootLayer.contents = presentation.presentedContents;
    rootLayer.contentsScale = image.scale;
    rootLayer.contentsGravity = kCAGravityResizeAspect;
    [CATransaction commit];
    presentation.themed = YES;
    return YES;
}

static BOOL MTStatusBarArtworkStyleForView(
    UIView *view,
    UIColor *activeColor,
    MTStatusBarArtworkStyle *style) {
    if (![activeColor isKindOfClass:UIColor.class] || style == NULL) {
        return NO;
    }
    UIColor *resolved = [activeColor
        resolvedColorWithTraitCollection:view.traitCollection];
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![resolved getWhite:&white alpha:&alpha]) return NO;
        red = green = blue = white;
    }
    if (alpha <= 0.0) return NO;
    CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    *style = luminance >= 0.5
        ? MTStatusBarArtworkStyleLockScreen
        : MTStatusBarArtworkStyleBlack;
    return YES;
}

@interface MTStatusBarImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTStatusBarSnapshotContext *context;
@property(nonatomic, copy) NSDictionary<NSString *, UIImage *> *images;
@property(nonatomic, assign) NSUInteger residentCost;
@end

@implementation MTStatusBarImageSet
@end

@interface MTStatusBarSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<MTStatusBarImageSet *> *imageSets;
@property(nonatomic, strong) dispatch_queue_t preparationQueue;
@property(atomic, strong, nullable) MTStatusBarSnapshotContext *lastContext;
@property(atomic, copy, nullable) dispatch_block_t readyHandler;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (void)reload;
- (BOOL)resolveSignalView:(UIView *)signalView
              activeColor:(nullable UIColor *)activeColor
                     kind:(MTStatusBarSignalKind)kind
                    level:(NSInteger)level;
@end

@implementation MTStatusBarSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _imageLoader = [[MTRuntimePublishedImageLoader alloc]
        initWithMaximumEncodedByteCount:MTStatusBarMaximumEncodedImageBytes
        maximumDecodedByteCount:MTStatusBarMaximumDecodedImageBytes];
    _imageSets = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTStatusBarMaximumReadyImageSets
        maximumReadyCost:MTStatusBarMaximumReadyCost
        maximumPendingCount:MTStatusBarMaximumPendingImageSets
        maximumFailureCount:MTStatusBarMaximumFailureCount];
    _preparationQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.statusbar-preparation",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    if (_imageLoader == nil || _imageSets == nil ||
        _preparationQueue == nil) {
        return nil;
    }
    return self;
}

- (nullable UIImage *)decodeResolution:
        (MTStatusBarSnapshotResolution *)resolution
                                  context:(MTStatusBarSnapshotContext *)context
                             residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImagePreservingSourceDimensionsForGeneration:
            resolution.generation
                                             resource:resolution.resource
                                                error:NULL];
    if (decoded == nil || decoded.pixelWidth > 128 ||
        decoded.pixelHeight > 128) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *image = [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)context.scale
        orientation:UIImageOrientationUp];
    if (image == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (nullable MTStatusBarImageSet *)buildImageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                       context:
        (MTStatusBarSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || snapshot.generation == nil ||
        generationIdentifier.length == 0 ||
        ![snapshot.generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }
    MTStatusBarSnapshotResolver *resolver =
        [[MTStatusBarSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return snapshot;
            }];
    NSMutableDictionary<NSString *, UIImage *> *images =
        [NSMutableDictionary dictionaryWithCapacity:
            MTStatusBarRuntimeSubjects().count];
    NSMutableDictionary<NSString *, UIImage *> *imagesByDigest =
        [NSMutableDictionary dictionary];
    NSUInteger residentCost = 0;
    for (NSUInteger style = MTStatusBarArtworkStyleBlack;
         style <= MTStatusBarArtworkStyleLockScreen; style++) {
        for (NSUInteger kind = MTStatusBarSignalKindCellular;
             kind <= MTStatusBarSignalKindWiFi; kind++) {
            NSUInteger maximum = MTStatusBarMaximumLevel(
                (MTStatusBarSignalKind)kind);
            for (NSUInteger level = 0; level <= maximum; level++) {
                NSString *subject = MTStatusBarResourceSubject(
                    (MTStatusBarSignalKind)kind,
                    (MTStatusBarArtworkStyle)style, level);
                MTStatusBarSnapshotResolution *resolution = [resolver
                    resolutionForKind:(MTStatusBarSignalKind)kind
                                 style:(MTStatusBarArtworkStyle)style
                                 level:level context:context error:NULL];
                if (subject == nil || resolution == nil) continue;
                atomic_fetch_add_explicit(
                    &MTRuntimeStatusBarSnapshotObservation.resourceHits,
                    1, memory_order_relaxed);
                NSString *digestKey = resolution.resource.contentSHA256;
                UIImage *image = imagesByDigest[digestKey];
                if (image == nil) {
                    NSUInteger imageCost = 0;
                    image = [self decodeResolution:resolution
                                           context:context
                                      residentCost:&imageCost];
                    if (image == nil ||
                        imageCost > MTStatusBarMaximumReadyCost -
                            MIN(residentCost,
                                MTStatusBarMaximumReadyCost)) {
                        continue;
                    }
                    residentCost += imageCost;
                    imagesByDigest[digestKey] = image;
                }
                images[subject] = image;
            }
        }
    }
    if (images.count == 0) return nil;
    MTStatusBarImageSet *imageSet = [[MTStatusBarImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.context = context;
    imageSet.images = images;
    imageSet.residentCost = MAX((NSUInteger)1, residentCost);
    return imageSet;
}

- (void)notifyReadyHandler {
    dispatch_block_t handler = self.readyHandler;
    if (handler != nil) dispatch_async(dispatch_get_main_queue(), handler);
}

- (nullable MTStatusBarImageSet *)imageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                     context:
        (MTStatusBarSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || generationIdentifier.length == 0 ||
        context == nil) {
        return nil;
    }
    MTStatusBarImageSet *ready = nil;
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
            MTStatusBarImageSet *imageSet = [strongSelf
                buildImageSetForSnapshot:snapshot context:context];
            BOOL accepted = [strongSelf.imageSets
                completeKey:context.cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch object:imageSet
                cost:imageSet == nil ? 0 : imageSet.residentCost];
            if (!accepted) return;
            atomic_store_explicit(
                &MTRuntimeStatusBarSnapshotObservation.state,
                imageSet == nil
                    ? MTStatusBarSnapshotModuleStateConfigured
                    : MTStatusBarSnapshotModuleStateReady,
                memory_order_release);
            MTRuntimeABIReportRecordModuleState(
                MTStatusBarSnapshotModuleID,
                imageSet == nil ? MTStatusBarSnapshotModuleStateConfigured
                                : MTStatusBarSnapshotModuleStateReady,
                imageSet == nil ? @"Configured" : @"Ready");
            if (imageSet != nil) {
                atomic_fetch_add_explicit(
                    &MTRuntimeStatusBarSnapshotObservation.imageSetsReady,
                    1, memory_order_relaxed);
            }
            [strongSelf notifyReadyHandler];
        }
    });
    return nil;
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.reloads,
        1, memory_order_relaxed);
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    BOOL resourcesAvailable = snapshot.isReady &&
        [snapshot.generation.descriptor.moduleIDs
            containsObject:MTStatusBarModuleID];
    atomic_store_explicit(&MTStatusBarResourcesAvailable,
                          resourcesAvailable ? 1 : 0,
                          memory_order_release);
    [self.imageSets purgeReadyObjectsAndCancelPending];
    atomic_store_explicit(
        &MTRuntimeStatusBarSnapshotObservation.state,
        MTStatusBarSnapshotModuleStateConfigured,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTStatusBarSnapshotModuleID, MTStatusBarSnapshotModuleStateConfigured, @"Configured");
    // Refresh first so disable/rollback immediately restore stock. If a real
    // view has already supplied a context, asynchronously prepare the newly
    // accepted Generation without consulting any UIKit singleton.
    [self notifyReadyHandler];
    MTStatusBarSnapshotContext *context = self.lastContext;
    if (context != nil) {
        (void)[self imageSetForSnapshot:snapshot
                                context:context];
    }
}

- (nullable MTStatusBarSnapshotContext *)contextForView:(UIView *)view {
    UITraitCollection *traits = view.traitCollection;
    CGFloat displayScale = traits.displayScale;
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = view.layer.contentsScale;
    }
    if (!isfinite(displayScale) || displayScale < 1.0) {
        displayScale = view.contentScaleFactor;
    }
    if (!isfinite(displayScale)) return nil;
    NSInteger roundedScale = (NSInteger)llround(displayScale);
    if (roundedScale < 1 || roundedScale > 3 ||
        fabs(displayScale - (CGFloat)roundedScale) > 0.001) {
        return nil;
    }
    NSString *deviceTrait = nil;
    if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    }
    return [MTStatusBarSnapshotContext
        contextWithScale:(NSUInteger)roundedScale deviceTrait:deviceTrait];
}

- (BOOL)resolveSignalView:(UIView *)signalView
              activeColor:(UIColor *)activeColor
                     kind:(MTStatusBarSignalKind)kind
                    level:(NSInteger)level {
    if (![NSThread isMainThread]) return NO;
    if (!atomic_load_explicit(
            &MTStatusBarResourcesAvailable, memory_order_acquire)) {
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.imageResolutions,
        1, memory_order_relaxed);
    MTStatusBarArtworkStyle style;
    if (level < 0 || !MTStatusBarArtworkStyleForView(
            signalView, activeColor, &style)) {
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    NSString *subject = MTStatusBarResourceSubject(
        kind, style, (NSUInteger)level);
    if (subject == nil) {
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.contextRequests,
        1, memory_order_relaxed);
    MTStatusBarSnapshotContext *context = [self contextForView:signalView];
    if (context == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.contextMisses,
            1, memory_order_relaxed);
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    self.lastContext = context;
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (MTStatusBarPresentationIsCurrent(
            signalView, generationIdentifier, subject, context.cacheKey)) {
        return YES;
    }
    MTStatusBarImageSet *imageSet = [self imageSetForSnapshot:snapshot
                                                      context:context];
    UIImage *image = imageSet.images[subject];
    if (imageSet == nil || image == nil ||
        ![imageSet.generationIdentifier isEqualToString:
            snapshot.state.activeGenerationIdentifier] ||
        ![imageSet.context isEqual:context]) {
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    if (!MTStatusBarApplyThemePresentation(
            signalView, image, generationIdentifier, subject,
            context.cacheKey)) {
        MTStatusBarRestoreStockPresentation(signalView);
        return NO;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.replacementResults,
        1, memory_order_relaxed);
    return YES;
}

@end

static os_unfair_lock MTStatusBarSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTStatusBarSnapshotModule *MTStatusBarSnapshotInstance;

BOOL MTStatusBarSnapshotConfigure(MTRuntimeKernel *kernel, NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTStatusBarSnapshotLock);
    if (MTStatusBarSnapshotInstance == nil) {
        MTStatusBarSnapshotInstance = [[MTStatusBarSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTStatusBarSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTStatusBarSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeStatusBarSnapshotObservation.state,
            MTStatusBarSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTStatusBarSnapshotModuleID, MTStatusBarSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.statusbar-snapshot"
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Status-bar snapshot module could not initialize."
        }];
    }
    return configured;
}

void MTStatusBarSnapshotReload(void) {
    [MTStatusBarSnapshotInstance reload];
}

BOOL MTStatusBarSnapshotShouldResolveSignalView(id signalView) {
    if (atomic_load_explicit(
            &MTStatusBarResourcesAvailable, memory_order_acquire)) {
        return YES;
    }
    if (![signalView isKindOfClass:UIView.class]) return NO;
    MTStatusBarSignalPresentation *presentation =
        MTStatusBarPresentationForView(signalView, NO);
    return presentation.themed;
}

void MTStatusBarSnapshotSetReadyHandler(dispatch_block_t handler) {
    MTStatusBarSnapshotInstance.readyHandler = handler;
}

BOOL MTStatusBarSnapshotResolveSignalView(id signalView,
                                         id activeColor,
                                         MTStatusBarSignalKind kind,
                                         NSInteger level) {
    if (MTStatusBarSnapshotInstance == nil ||
        ![signalView isKindOfClass:UIView.class]) {
        return NO;
    }
    return [MTStatusBarSnapshotInstance
        resolveSignalView:(UIView *)signalView
        activeColor:[activeColor isKindOfClass:UIColor.class]
            ? activeColor : nil
        kind:kind level:level];
}
