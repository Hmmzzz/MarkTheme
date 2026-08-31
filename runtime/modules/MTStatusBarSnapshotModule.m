#import "MTStatusBarSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStatusBarSnapshotResolver.h"

NSString *const MTStatusBarSnapshotModuleID = @"statusbar.snapshot";

static const NSUInteger MTStatusBarMaximumReadyImageCount = 32;
static const NSUInteger MTStatusBarMaximumReadyImageCost = 4 * 1024 * 1024;
static const uint64_t MTStatusBarMaximumEncodedImageBytes = 1024 * 1024;
static const uint64_t MTStatusBarMaximumDecodedImageBytes = 128 * 128 * 4;

MTStatusBarSnapshotObservation MTRuntimeStatusBarSnapshotObservation = {
    .schemaVersion = 3,
    .state = ATOMIC_VAR_INIT(MTStatusBarSnapshotModuleStateDormant),
    .nativeCommitRequests = ATOMIC_VAR_INIT(0),
    .contextRequests = ATOMIC_VAR_INIT(0),
    .contextMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
    .stockRestores = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTStatusBarSnapshotObservation) == 80,
    "Status Bar native-commit Module observation ABI changed");

@interface MTStatusBarSignalPresentation : NSObject
@property(nonatomic, strong)
    NSMapTable<CALayer *, NSNumber *> *stockLayerHiddenStates;
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
    presentation.stockLayerHiddenStates = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (presentation.stockLayerHiddenStates == nil) return nil;
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
        presentation.stockLayerHiddenStates.keyEnumerator.allObjects;
    for (CALayer *layer in layers) {
        NSNumber *hidden =
            [presentation.stockLayerHiddenStates objectForKey:layer];
        if (hidden != nil) layer.hidden = hidden.boolValue;
    }
    [presentation.stockLayerHiddenStates removeAllObjects];
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
        if ([presentation.stockLayerHiddenStates objectForKey:layer] == nil ||
            !layer.hidden) {
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
        // Preserve any newer stock root raster published by Apple's
        // original-first commit before replacing that same carrier again.
        presentation.originalContents = rootLayer.contents;
        presentation.originalContentsScale = rootLayer.contentsScale;
        presentation.originalContentsGravity = rootLayer.contentsGravity;
        presentation.capturedRootState = YES;
    }

    // SystemStatusUI indexes these direct native layers in
    // _updateActiveBars. Their count, order, ownership, and identity remain
    // untouched. hidden is used instead of opacity so the subsequent native
    // cycle-animation pass cannot leak partially updated bars over the whole
    // themed raster. Every prior hidden state remains restorable.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray<CALayer *> *stockLayers = [rootLayer.sublayers copy] ?: @[];
    for (CALayer *layer in stockLayers) {
        if ([presentation.stockLayerHiddenStates objectForKey:layer] == nil) {
            [presentation.stockLayerHiddenStates
                setObject:@(layer.hidden) forKey:layer];
        }
        layer.hidden = YES;
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

@interface MTStatusBarSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTStatusBarSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong) MTRuntimeObjectCache<UIImage *> *images;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
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
    __weak MTRuntimeKernel *weakKernel = kernel;
    _resolver = [[MTStatusBarSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return weakKernel.currentSnapshot;
        }];
    _imageLoader = [[MTRuntimePublishedImageLoader alloc]
        initWithMaximumEncodedByteCount:MTStatusBarMaximumEncodedImageBytes
        maximumDecodedByteCount:MTStatusBarMaximumDecodedImageBytes];
    _images = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTStatusBarMaximumReadyImageCount
        maximumCost:MTStatusBarMaximumReadyImageCost];
    if (_resolver == nil || _imageLoader == nil || _images == nil) {
        return nil;
    }
    return self;
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

static NSString *MTStatusBarImageCacheKey(
    MTStatusBarSnapshotResolution *resolution,
    MTStatusBarSnapshotContext *context) {
    return [NSString stringWithFormat:@"%@/%@/%@/%@",
        resolution.generationIdentifier,
        resolution.canonicalResourceKey,
        resolution.resource.contentSHA256,
        context.cacheKey];
}

- (nullable UIImage *)imageForResolution:
        (MTStatusBarSnapshotResolution *)resolution
                                      context:
        (MTStatusBarSnapshotContext *)context {
    NSString *cacheKey = MTStatusBarImageCacheKey(resolution, context);
    UIImage *cached = [self.images objectForKey:cacheKey];
    if (cached != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return cached;
    }

    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImagePreservingSourceDimensionsForGeneration:
            resolution.generation
                                             resource:resolution.resource
                                                error:NULL];
    if (decoded == nil || decoded.pixelWidth == 0 ||
        decoded.pixelHeight == 0 || decoded.pixelWidth > 128 ||
        decoded.pixelHeight > 128 ||
        decoded.residentCost > MTStatusBarMaximumReadyImageCost) {
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
    MTRuntimeSnapshot *current = self.kernel.currentSnapshot;
    if (!current.isReady ||
        ![current.state.activeGenerationIdentifier
            isEqualToString:resolution.generationIdentifier]) {
        return nil;
    }
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (![self.images setObject:image forKey:cacheKey
                           cost:MAX((NSUInteger)1,
                                    decoded.residentCost)]) {
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    atomic_store_explicit(
        &MTRuntimeStatusBarSnapshotObservation.state,
        MTStatusBarSnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTStatusBarSnapshotModuleID,
        MTStatusBarSnapshotModuleStateReady, @"Ready");
    return image;
}

- (BOOL)restoreStockForView:(UIView *)view {
    BOOL restored = MTStatusBarRestoreStockPresentation(view);
    if (restored) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.stockRestores,
            1, memory_order_relaxed);
    }
    return NO;
}

- (BOOL)resolveSignalView:(UIView *)signalView
              activeColor:(UIColor *)activeColor
                     kind:(MTStatusBarSignalKind)kind
                    level:(NSInteger)level {
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.nativeCommitRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread]) return NO;

    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    BOOL moduleAvailable = snapshot.isReady && snapshot.generation != nil &&
        generationIdentifier.length > 0 &&
        [snapshot.generation.generationIdentifier
            isEqualToString:generationIdentifier] &&
        [snapshot.generation.descriptor.moduleIDs
            containsObject:MTStatusBarModuleID];
    if (!moduleAvailable) return [self restoreStockForView:signalView];

    MTStatusBarArtworkStyle style;
    if (level < 0 || !MTStatusBarArtworkStyleForView(
            signalView, activeColor, &style)) {
        return [self restoreStockForView:signalView];
    }
    NSString *subject = MTStatusBarResourceSubject(
        kind, style, (NSUInteger)level);
    if (subject == nil) return [self restoreStockForView:signalView];

    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.contextRequests,
        1, memory_order_relaxed);
    MTStatusBarSnapshotContext *context = [self contextForView:signalView];
    if (context == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStatusBarSnapshotObservation.contextMisses,
            1, memory_order_relaxed);
        return [self restoreStockForView:signalView];
    }
    if (MTStatusBarPresentationIsCurrent(
            signalView, generationIdentifier, subject, context.cacheKey)) {
        return YES;
    }

    MTStatusBarSnapshotResolution *resolution = [self.resolver
        resolutionForKind:kind style:style level:(NSUInteger)level
        context:context error:NULL];
    if (resolution == nil ||
        ![resolution.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return [self restoreStockForView:signalView];
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStatusBarSnapshotObservation.resourceHits,
        1, memory_order_relaxed);
    UIImage *image = [self imageForResolution:resolution context:context];
    if (image == nil) return [self restoreStockForView:signalView];

    MTRuntimeSnapshot *current = self.kernel.currentSnapshot;
    if (!current.isReady ||
        ![current.state.activeGenerationIdentifier
            isEqualToString:generationIdentifier] ||
        !MTStatusBarApplyThemePresentation(
            signalView, image, generationIdentifier, subject,
            context.cacheKey)) {
        return [self restoreStockForView:signalView];
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
    if (error != NULL) *error = nil;
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
            MTStatusBarSnapshotModuleID,
            MTStatusBarSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.statusbar-snapshot"
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Status-bar native-commit module could not initialize."
        }];
    }
    return configured;
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
