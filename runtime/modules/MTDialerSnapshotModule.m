#import "MTDialerSnapshotModule.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <os/lock.h>

#import "MTDialerContract.h"
#import "MTDialerSnapshotResolver.h"
#import "MTGenerationReader.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTRuntimeABIReport.h"

NSString *const MTDialerSnapshotModuleID = @"dialer.snapshot";

static const NSUInteger MTDialerMaximumReadyImageSets = 2;
static const NSUInteger MTDialerMaximumReadyCost = 16 * 1024 * 1024;
static const NSUInteger MTDialerMaximumPendingImageSets = 2;
static const NSUInteger MTDialerMaximumFailureCount = 4;

MTDialerSnapshotObservation MTRuntimeDialerSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTDialerSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .contextRequests = ATOMIC_VAR_INIT(0),
    .contextMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .imageSetsReady = ATOMIC_VAR_INIT(0),
    .overlaysCreated = ATOMIC_VAR_INIT(0),
    .overlaysUpdated = ATOMIC_VAR_INIT(0),
    .overlaysRemoved = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTDialerSnapshotObservation) == 88,
    "The Dialer ModuleRuntime observation layout must remain fixed.");

@interface MTDialerImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, strong) MTDialerSnapshotContext *context;
@property(nonatomic, copy) NSDictionary<NSString *, UIImage *> *images;
@property(nonatomic, assign) NSUInteger residentCost;
@end

@implementation MTDialerImageSet
@end

@interface MTDialerSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<MTDialerImageSet *> *imageSets;
@property(nonatomic, strong) dispatch_queue_t preparationQueue;
@property(atomic, assign) BOOL prepared;
@property(atomic, copy, nullable) dispatch_block_t readyHandler;
@property(nonatomic, strong) NSMapTable<UIView *, UIImageView *> *overlays;
// Per-button record of the stock subviews and extra sublayers hidden while
// a themed overlay is showing, so the original keypad artwork can be
// restored exactly when the overlay goes away.
@property(nonatomic, strong)
    NSMapTable<UIView *, NSMutableArray<NSDictionary<NSString *, id> *> *>
        *originalContentStates;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (BOOL)prepare;
- (void)reload;
- (BOOL)resolveButton:(UIView *)button
        normalSubject:(NSString *)normalSubject
   highlightedSubject:(NSString *)highlightedSubject
           highlighted:(BOOL)highlighted;
@end

@implementation MTDialerSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _imageLoader = [[MTRuntimePublishedImageLoader alloc]
        initWithMaximumEncodedByteCount:8ULL * 1024ULL * 1024ULL
        maximumDecodedByteCount:4ULL * 1024ULL * 1024ULL];
    _imageSets = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTDialerMaximumReadyImageSets
        maximumReadyCost:MTDialerMaximumReadyCost
        maximumPendingCount:MTDialerMaximumPendingImageSets
        maximumFailureCount:MTDialerMaximumFailureCount];
    _preparationQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.dialer-preparation",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    _overlays = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    _originalContentStates = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory |
                               NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsStrongMemory];
    if (_imageLoader == nil || _imageSets == nil ||
        _preparationQueue == nil || _overlays == nil ||
        _originalContentStates == nil) {
        return nil;
    }
    return self;
}

- (nullable UIImage *)decodeResolution:
        (MTDialerSnapshotResolution *)resolution
                                  context:(MTDialerSnapshotContext *)context
                             residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    uint32_t targetDimension = (uint32_t)llround(
        MTDialerButtonPointDimension * (CGFloat)context.scale);
    MTRuntimePublishedImageResizePolicy policy = context.scale == 3
        ? MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
        : MTRuntimePublishedImageResizePolicyExactOrDownsample;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:targetDimension
             targetPixelHeight:targetDimension
                  resizePolicy:policy
                         error:NULL];
    if (decoded == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *image = [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)context.scale
        orientation:UIImageOrientationUp];
    if (image == nil ||
        fabs(image.size.width - MTDialerButtonPointDimension) > 0.001 ||
        fabs(image.size.height - MTDialerButtonPointDimension) > 0.001) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (nullable MTDialerImageSet *)buildImageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                    context:
        (MTDialerSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!snapshot.isReady || snapshot.generation == nil ||
        generationIdentifier.length == 0 ||
        ![snapshot.generation.generationIdentifier
            isEqualToString:generationIdentifier]) {
        return nil;
    }
    MTDialerSnapshotResolver *resolver = [[MTDialerSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    NSMutableDictionary<NSString *, UIImage *> *images =
        [NSMutableDictionary dictionaryWithCapacity:
            MTDialerRuntimeSubjects().count];
    NSMutableDictionary<NSString *, UIImage *> *imagesByDigest =
        [NSMutableDictionary dictionary];
    NSUInteger residentCost = 0;
    for (NSString *subject in MTDialerRuntimeSubjects()) {
        MTDialerSnapshotResolution *resolution = [resolver
            resolutionForSubject:subject context:context error:NULL];
        if (resolution == nil) continue;
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.resourceHits,
            1, memory_order_relaxed);
        NSString *digestKey = [NSString stringWithFormat:@"%@/%lu",
            resolution.resource.contentSHA256,
            (unsigned long)context.scale];
        UIImage *image = imagesByDigest[digestKey];
        if (image == nil) {
            NSUInteger imageCost = 0;
            image = [self decodeResolution:resolution
                                   context:context
                              residentCost:&imageCost];
            if (image == nil ||
                imageCost > MTDialerMaximumReadyCost -
                    MIN(residentCost, MTDialerMaximumReadyCost)) {
                continue;
            }
            residentCost += imageCost;
            imagesByDigest[digestKey] = image;
        }
        images[subject] = image;
    }
    if (images.count == 0) return nil;
    MTDialerImageSet *imageSet = [[MTDialerImageSet alloc] init];
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

- (nullable MTDialerImageSet *)imageSetForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                                  context:
        (MTDialerSnapshotContext *)context {
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (!self.prepared || !snapshot.isReady ||
        generationIdentifier.length == 0 || context == nil) {
        return nil;
    }
    MTDialerImageSet *ready = nil;
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
            MTDialerImageSet *imageSet = [strongSelf
                buildImageSetForSnapshot:snapshot context:context];
            BOOL accepted = [strongSelf.imageSets
                completeKey:context.cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch object:imageSet
                cost:imageSet == nil ? 0 : imageSet.residentCost];
            if (!accepted) return;
            atomic_store_explicit(
                &MTRuntimeDialerSnapshotObservation.state,
                imageSet == nil ? MTDialerSnapshotModuleStateConfigured
                                : MTDialerSnapshotModuleStateReady,
                memory_order_release);
            MTRuntimeABIReportRecordModuleState(
                MTDialerSnapshotModuleID,
                imageSet == nil ? MTDialerSnapshotModuleStateConfigured
                                : MTDialerSnapshotModuleStateReady,
                imageSet == nil ? @"Configured" : @"Ready");
            if (imageSet != nil) {
                atomic_fetch_add_explicit(
                    &MTRuntimeDialerSnapshotObservation.imageSetsReady,
                    1, memory_order_relaxed);
            }
            [strongSelf notifyReadyHandler];
        }
    });
    return nil;
}

- (void)prewarmCurrentSnapshot {
    if (!self.prepared) return;
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    if (!snapshot.isReady) return;
    for (NSNumber *scale in @[ @3, @2 ]) {
        MTDialerSnapshotContext *context = [MTDialerSnapshotContext
            contextWithScale:scale.unsignedIntegerValue
            deviceTrait:@"iphone"];
        (void)[self imageSetForSnapshot:snapshot context:context];
    }
}

- (BOOL)prepare {
    if (![NSThread isMainThread]) return NO;
    self.prepared = YES;
    [self prewarmCurrentSnapshot];
    return YES;
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.reloads,
        1, memory_order_relaxed);
    [self.imageSets purgeReadyObjectsAndCancelPending];
    atomic_store_explicit(
        &MTRuntimeDialerSnapshotObservation.state,
        MTDialerSnapshotModuleStateConfigured,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTDialerSnapshotModuleID, MTDialerSnapshotModuleStateConfigured, @"Configured");
    [self notifyReadyHandler];
    [self prewarmCurrentSnapshot];
}

- (nullable MTDialerSnapshotContext *)contextForView:(UIView *)view {
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
    if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        deviceTrait = @"ipad";
    } else if (traits.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        deviceTrait = @"iphone";
    } else {
        // The exact MobilePhone profile and Adapter classes are iPhone-only;
        // an early unattached view may not yet expose an idiom trait.
        deviceTrait = @"iphone";
    }
    return [MTDialerSnapshotContext
        contextWithScale:(NSUInteger)roundedScale deviceTrait:deviceTrait];
}

// The stock number-pad button draws itself as a circle view, glyph layers,
// and a press ring layered under the themed overlay. Legacy themed art is a
// fixed 75pt canvas with possible transparent margins, so any uncovered
// original element shows through as a ring around the themed button. While
// an overlay is showing, every other subview and non-view-backed sublayer is
// hidden; each element's prior state is recorded so the stock keypad returns
// exactly when the overlay is removed.
- (void)hideOriginalContentForButton:(UIView *)button
                             overlay:(UIView *)overlay {
    NSMutableArray<NSDictionary<NSString *, id> *> *records =
        [self.originalContentStates objectForKey:button];
    if (records == nil) {
        records = [NSMutableArray array];
        [self.originalContentStates setObject:records forKey:button];
    }
    void (^record)(id object) = ^(id object) {
        for (NSDictionary<NSString *, id> *record in records) {
            if (record[@"object"] == object) return;
        }
        BOOL hidden = [object isKindOfClass:[CALayer class]]
            ? ((CALayer *)object).hidden
            : ((UIView *)object).hidden;
        [records addObject:@{
            @"object" : object,
            @"hidden" : @(hidden),
        }];
        if ([object isKindOfClass:[CALayer class]]) {
            ((CALayer *)object).hidden = YES;
        } else {
            ((UIView *)object).hidden = YES;
        }
    };
    for (UIView *subview in button.subviews) {
        if (subview != overlay) record(subview);
    }
    for (CALayer *layer in button.layer.sublayers) {
        // Subview-owned layers hide together with their view; only extra
        // layers such as the stock glyph hide individually.
        if (layer == overlay.layer ||
            [layer.delegate isKindOfClass:[UIView class]]) {
            continue;
        }
        record(layer);
    }
}

- (void)restoreOriginalContentForButton:(UIView *)button {
    NSArray<NSDictionary<NSString *, id> *> *records =
        [self.originalContentStates objectForKey:button];
    if (records == nil) return;
    for (NSDictionary<NSString *, id> *record in records) {
        id object = record[@"object"];
        BOOL hidden = [record[@"hidden"] boolValue];
        if ([object isKindOfClass:[CALayer class]]) {
            ((CALayer *)object).hidden = hidden;
        } else if ([object isKindOfClass:[UIView class]]) {
            ((UIView *)object).hidden = hidden;
        }
    }
    [self.originalContentStates removeObjectForKey:button];
}

- (BOOL)removeOverlayForButton:(UIView *)button {
    UIImageView *overlay = [self.overlays objectForKey:button];
    if (overlay == nil) return NO;
    [self restoreOriginalContentForButton:button];
    [overlay removeFromSuperview];
    [self.overlays removeObjectForKey:button];
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.overlaysRemoved,
        1, memory_order_relaxed);
    return YES;
}

- (BOOL)resolveButton:(UIView *)button
        normalSubject:(NSString *)normalSubject
   highlightedSubject:(NSString *)highlightedSubject
           highlighted:(BOOL)highlighted {
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.contextRequests,
        1, memory_order_relaxed);
    if (![NSThread isMainThread] ||
        !MTDialerResourceSubjectIsSupported(normalSubject) ||
        !MTDialerResourceSubjectIsSupported(highlightedSubject)) {
        return NO;
    }
    MTDialerSnapshotContext *context = [self contextForView:button];
    if (context == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.contextMisses,
            1, memory_order_relaxed);
        [self removeOverlayForButton:button];
        return NO;
    }
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    MTDialerImageSet *imageSet = [self imageSetForSnapshot:snapshot
                                                    context:context];
    UIImage *normalImage = imageSet.images[normalSubject];
    if (imageSet == nil || normalImage == nil ||
        ![imageSet.generationIdentifier isEqualToString:
            snapshot.state.activeGenerationIdentifier]) {
        [self removeOverlayForButton:button];
        return NO;
    }
    UIImage *highlightedImage = imageSet.images[highlightedSubject] ?:
        normalImage;
    UIImageView *overlay = [self.overlays objectForKey:button];
    if (overlay == nil) {
        overlay = [[UIImageView alloc] initWithFrame:button.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = UIColor.clearColor;
        // Legacy TelephonyUI artwork is a fixed 75pt full-button canvas.
        // Center it without scaling so UIControl padding cannot enlarge it.
        overlay.contentMode = UIViewContentModeCenter;
        overlay.clipsToBounds = NO;
        overlay.userInteractionEnabled = NO;
        overlay.isAccessibilityElement = NO;
        [self.overlays setObject:overlay forKey:button];
        atomic_fetch_add_explicit(
            &MTRuntimeDialerSnapshotObservation.overlaysCreated,
            1, memory_order_relaxed);
    }
    if (overlay.superview != button) [button addSubview:overlay];
    overlay.frame = button.bounds;
    overlay.image = normalImage;
    overlay.highlightedImage = highlightedImage;
    overlay.highlighted = highlighted;
    [button bringSubviewToFront:overlay];
    [self hideOriginalContentForButton:button overlay:overlay];
    atomic_fetch_add_explicit(
        &MTRuntimeDialerSnapshotObservation.overlaysUpdated,
        1, memory_order_relaxed);
    return YES;
}

@end

static os_unfair_lock MTDialerSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTDialerSnapshotModule *MTDialerSnapshotInstance;

BOOL MTDialerSnapshotConfigure(MTRuntimeKernel *kernel,
                               NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTDialerSnapshotLock);
    if (MTDialerSnapshotInstance == nil) {
        MTDialerSnapshotInstance = [[MTDialerSnapshotModule alloc]
            initWithKernel:kernel];
    }
    BOOL configured = MTDialerSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTDialerSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeDialerSnapshotObservation.state,
            MTDialerSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTDialerSnapshotModuleID, MTDialerSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError
            errorWithDomain:@"com.hmmzzz.marktheme.dialer-snapshot"
                       code:1
                   userInfo:@{
            NSLocalizedDescriptionKey :
                @"Dialer snapshot module could not initialize."
        }];
    }
    return configured;
}

BOOL MTDialerSnapshotPrepare(void) {
    return [MTDialerSnapshotInstance prepare];
}

void MTDialerSnapshotReload(void) {
    [MTDialerSnapshotInstance reload];
}

void MTDialerSnapshotSetReadyHandler(dispatch_block_t handler) {
    MTDialerSnapshotInstance.readyHandler = handler;
}

BOOL MTDialerSnapshotResolveButton(id button,
                                   NSString *normalSubject,
                                   NSString *highlightedSubject,
                                   BOOL highlighted) {
    if (MTDialerSnapshotInstance == nil ||
        ![button isKindOfClass:UIView.class]) {
        return NO;
    }
    return [MTDialerSnapshotInstance resolveButton:(UIView *)button
                                      normalSubject:normalSubject
                                 highlightedSubject:highlightedSubject
                                         highlighted:highlighted];
}
