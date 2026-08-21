#import "MTStaticIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTCalendarIconContent.h"
#import "MTCalendarIconRenderer.h"
#import "MTCalendarIconSnapshotResolver.h"
#import "MTClockIconsModule.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTStaticIconSnapshotResolver.h"
#import "MTStaticIconVisualProofContract.h"
#import "MTRuntimeABIReport.h"

NSString *const MTStaticIconSnapshotModuleID = @"static-icons.snapshot";
NSString *const MTStaticIconSnapshotModuleErrorDomain =
    @"com.hmmzzz.marktheme.static-icon-snapshot-module";

static const NSUInteger MTStaticIconMaximumReadyCount = 64;
static const NSUInteger MTStaticIconMaximumReadyCost = 32 * 1024 * 1024;
static const NSUInteger MTStaticIconMaximumPendingCount = 64;
static const NSUInteger MTStaticIconMaximumFailureCount = 256;
const NSUInteger MTStaticIconSnapshotPrewarmBatchLimit = 64;

@protocol MTStaticIconImageLike <NSObject>
@property(nonatomic, readonly) CGImageRef CGImage;
@property(nonatomic, readonly) CGFloat scale;
@end

typedef BOOL (*MTStaticIconImageContractValidator)(CGSize, CGFloat);

typedef struct MTStaticIconImageContract {
    CGSize pointSize;
    NSUInteger scale;
    NSUInteger pixelWidth;
    NSUInteger pixelHeight;
} MTStaticIconImageContract;

// Prewarming targets the running display rather than a pinned factor, so an
// untested iPhone family warms the geometry it will actually request. This
// only chooses which speculative decode to schedule; a miss still resolves on
// demand through the same bounded contract.
static CGFloat MTStaticIconPrewarmScale(void) {
    UIScreen *mainScreen = UIScreen.mainScreen;
    return MTStaticIconClampedPrewarmScale(
        mainScreen == nil ? 0 : mainScreen.scale);
}

static NSString *MTStaticIconDeviceTrait(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? @"ipad" : @"iphone";
}

static MTStaticIconImageContract MTStaticIconImageContractMake(
    CGSize pointSize,
    CGFloat scale) {
    return (MTStaticIconImageContract) {
        .pointSize = pointSize,
        .scale = (NSUInteger)scale,
        .pixelWidth = (NSUInteger)(pointSize.width * scale),
        .pixelHeight = (NSUInteger)(pointSize.height * scale),
    };
}

MTStaticIconSnapshotObservation MTRuntimeStaticIconSnapshotObservation = {
    .schemaVersion = 2,
    .state = ATOMIC_VAR_INIT(MTStaticIconSnapshotModuleStateDormant),
    .lookupCalls = ATOMIC_VAR_INIT(0),
    .unsupportedOriginalMisses = ATOMIC_VAR_INIT(0),
    .snapshotMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .decodeScheduled = ATOMIC_VAR_INIT(0),
    .pendingMisses = ATOMIC_VAR_INIT(0),
    .failureMisses = ATOMIC_VAR_INIT(0),
    .saturatedMisses = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .staleCompletions = ATOMIC_VAR_INIT(0),
    .memoryPressurePurges = ATOMIC_VAR_INIT(0),
    .cacheEvictions = ATOMIC_VAR_INIT(0),
    .prewarmBatches = ATOMIC_VAR_INIT(0),
    .prewarmIdentifiers = ATOMIC_VAR_INIT(0),
    .prewarmResourceHits = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTStaticIconSnapshotObservation) == 144,
    "The M3-E snapshot observation layout must remain fixed.");

static NSString *MTStaticIconCacheKey(
    NSString *bundleIdentifier,
    MTCalendarIconContent *calendarContent,
    MTStaticIconImageContract imageContract) {
    BOOL primaryContract = imageContract.pixelWidth == 180 &&
        imageContract.pixelHeight == 180 && imageContract.scale == 3;
    if (calendarContent == nil && primaryContract) {
        return bundleIdentifier;
    }
    NSString *base = [NSString stringWithFormat:@"%@|%lux%lu@%lu",
        bundleIdentifier,
        (unsigned long)imageContract.pixelWidth,
        (unsigned long)imageContract.pixelHeight,
        (unsigned long)imageContract.scale];
    return calendarContent == nil ? base :
        [base stringByAppendingFormat:@"|calendar|%@",
            calendarContent.cacheIdentifier];
}

@interface MTStaticIconSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong) MTStaticIconSnapshotResolver *resolver;
@property(nonatomic, strong, nullable)
    MTCalendarIconSnapshotResolver *calendarResolver;
@property(nonatomic, strong, nullable)
    MTCalendarIconContentProvider *calendarContentProvider;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<UIImage *> *cache;
@property(nonatomic, strong) dispatch_queue_t decodeQueue;
@property(nonatomic, strong) dispatch_source_t memoryPressureSource;
@property(atomic, copy, nullable)
    MTStaticIconSnapshotImageReadyHandler imageReadyHandler;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
       calendarCompositeEnabled:(BOOL)calendarCompositeEnabled;
- (id _Nullable)resolveBundleIdentifier:(NSString *)bundleIdentifier
                      originalPointSize:(CGSize)originalPointSize
                                  scale:(CGFloat)scale
                      contractValidator:
                          (MTStaticIconImageContractValidator)contractValidator;
- (UIImage *_Nullable)readyImageForBundleIdentifier:
    (NSString *)bundleIdentifier
                                          pointSize:(CGSize)pointSize
                                              scale:(CGFloat)scale;
- (void)scheduleDecodeForResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                            cacheKey:(NSString *)cacheKey
                               epoch:(uint64_t)epoch
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *_Nullable)calendarConfiguration
                     calendarContent:
                    (MTCalendarIconContent *_Nullable)calendarContent
                       imageContract:
                    (MTStaticIconImageContract)imageContract
                         notifyReady:(BOOL)notifyReady;
- (UIImage *_Nullable)decodePendingResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                            cacheKey:(NSString *)cacheKey
                               epoch:(uint64_t)epoch
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *_Nullable)calendarConfiguration
                     calendarContent:
                    (MTCalendarIconContent *_Nullable)calendarContent
                       imageContract:
                    (MTStaticIconImageContract)imageContract
                         notifyReady:(BOOL)notifyReady;
- (UIImage *_Nullable)decodeImageForResolution:
    (MTStaticIconSnapshotResolution *)resolution
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *_Nullable)calendarConfiguration
                     calendarContent:
                    (MTCalendarIconContent *_Nullable)calendarContent
                       imageContract:
                    (MTStaticIconImageContract)imageContract
                        residentCost:(NSUInteger *)residentCost;
- (UIImage *_Nullable)decodeImageForResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *_Nullable)calendarConfiguration
                     calendarContent:
                    (MTCalendarIconContent *_Nullable)calendarContent
                       imageContract:
                    (MTStaticIconImageContract)imageContract
                        residentCost:(NSUInteger *)residentCost;
- (void)prewarmBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
    expectedGenerationIdentifier:(NSString *)expectedGenerationIdentifier
                       completion:
                           (MTStaticIconSnapshotPrewarmCompletion)completion;
@end

@implementation MTStaticIconSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
       calendarCompositeEnabled:(BOOL)calendarCompositeEnabled {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _resolver = [[MTStaticIconSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return kernel.currentSnapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    if (calendarCompositeEnabled) {
        _calendarResolver = [[MTCalendarIconSnapshotResolver alloc] init];
        _calendarContentProvider =
            [[MTCalendarIconContentProvider alloc] init];
    }
    _cache = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTStaticIconMaximumReadyCount
        maximumReadyCost:MTStaticIconMaximumReadyCost
        maximumPendingCount:MTStaticIconMaximumPendingCount
        maximumFailureCount:MTStaticIconMaximumFailureCount];
    _decodeQueue = dispatch_queue_create(
        "com.hmmzzz.marktheme.static-icon-decode",
        dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    _memoryPressureSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (_resolver == nil || _imageLoader == nil || _cache == nil ||
        _decodeQueue == nil || _memoryPressureSource == nil) {
        return nil;
    }
    if (calendarCompositeEnabled &&
        (_calendarResolver == nil || _calendarContentProvider == nil)) {
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_memoryPressureSource, ^{
        MTStaticIconSnapshotModule *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.cache purgeReadyObjectsAndCancelPending];
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.memoryPressurePurges,
            1, memory_order_relaxed);
    });
    dispatch_resume(_memoryPressureSource);
    return self;
}

- (UIImage *)readyImageForBundleIdentifier:(NSString *)bundleIdentifier
                                  pointSize:(CGSize)pointSize
                                      scale:(CGFloat)scale {
    if (bundleIdentifier.length == 0 ||
        [bundleIdentifier
            isEqualToString:MTCalendarIconTargetBundleIdentifier]) {
        return nil;
    }
    if (!MTStaticIconSystemSurfaceImageContractIsSupported(pointSize, scale)) {
        return nil;
    }
    NSString *generationIdentifier =
        self.kernel.currentSnapshot.generation.generationIdentifier;
    if (generationIdentifier.length == 0) return nil;
    MTStaticIconImageContract imageContract =
        MTStaticIconImageContractMake(pointSize, scale);
    NSString *cacheKey = MTStaticIconCacheKey(
        bundleIdentifier, nil, imageContract);
    UIImage *ready = [self.cache
        readyObjectForGenerationIdentifier:generationIdentifier
        key:cacheKey];
    if (ready != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.lookupCalls,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.resourceHits,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
    }
    return ready;
}

- (id)resolveBundleIdentifier:(NSString *)bundleIdentifier
            originalPointSize:(CGSize)originalPointSize
                        scale:(CGFloat)scale
            contractValidator:
                (MTStaticIconImageContractValidator)contractValidator {
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.lookupCalls,
        1, memory_order_relaxed);
    if (!contractValidator(originalPointSize, scale)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.unsupportedOriginalMisses,
            1, memory_order_relaxed);
        return nil;
    }
    MTStaticIconImageContract imageContract =
        MTStaticIconImageContractMake(originalPointSize, scale);

    MTGeneration *generation = self.kernel.currentSnapshot.generation;
    NSString *generationIdentifier = generation.generationIdentifier;
    if (generationIdentifier.length == 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        return nil;
    }

    NSError *calendarError = nil;
    MTCalendarIconConfiguration *calendarConfiguration =
        [self.calendarResolver
            configurationForBundleIdentifier:bundleIdentifier
                                   generation:generation
                                        error:&calendarError];
    MTCalendarIconContent *calendarContent = calendarConfiguration == nil
        ? nil : self.calendarContentProvider.currentContent;
    if (calendarError != nil ||
        (calendarConfiguration != nil && calendarContent == nil)) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        return nil;
    }

    NSString *cacheKey = MTStaticIconCacheKey(
        bundleIdentifier, calendarContent, imageContract);
    UIImage *ready = nil;
    uint64_t epoch = 0;
    MTRuntimeAsyncCacheDisposition disposition = [self.cache
        lookupObjectForGenerationIdentifier:generationIdentifier
        key:cacheKey object:&ready epoch:&epoch];
    BOOL ownsPendingEntry = NO;
    switch (disposition) {
        case MTRuntimeAsyncCacheDispositionReady:
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.cacheHits,
                1, memory_order_relaxed);
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.resourceHits,
                1, memory_order_relaxed);
            return ready;
        case MTRuntimeAsyncCacheDispositionFailed:
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.failureMisses,
                1, memory_order_relaxed);
            return nil;
        case MTRuntimeAsyncCacheDispositionPending:
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.pendingMisses,
                1, memory_order_relaxed);
            ownsPendingEntry = [self.cache claimPendingKey:cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch];
            break;
        case MTRuntimeAsyncCacheDispositionScheduled:
            ownsPendingEntry = [self.cache claimPendingKey:cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch];
            break;
        case MTRuntimeAsyncCacheDispositionSaturated:
            break;
    }
    if (disposition != MTRuntimeAsyncCacheDispositionSaturated &&
        !ownsPendingEntry) {
        return [self.cache waitForPendingKey:cacheKey
            generationIdentifier:generationIdentifier
            epoch:epoch];
    }

    NSError *resolutionError = nil;
    NSArray<MTStaticIconSnapshotResolution *> *resolutions = [self.resolver
        resolutionsForBundleIdentifier:bundleIdentifier
        scale:(NSUInteger)scale
        deviceTrait:MTStaticIconDeviceTrait()
        error:&resolutionError];
    if (resolutions.count == 0) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        if (ownsPendingEntry) {
            (void)[self.cache completeKey:cacheKey
                generationIdentifier:generationIdentifier
                epoch:epoch object:nil cost:0];
        }
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.resourceHits,
        1, memory_order_relaxed);

    if (disposition == MTRuntimeAsyncCacheDispositionSaturated) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.saturatedMisses,
            1, memory_order_relaxed);
        // Saturation is caused only by speculative background work. A
        // demanded icon bypasses that admission limit once and returns the
        // decoded object directly, while still checking the Generation.
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.decodeScheduled,
            1, memory_order_relaxed);
        NSUInteger residentCost = 0;
        ready = [self decodeImageForResolutions:resolutions
                              bundleIdentifier:bundleIdentifier
                          calendarConfiguration:calendarConfiguration
                                calendarContent:calendarContent
                                  imageContract:imageContract
                                   residentCost:&residentCost];
        if (![self.cache.activeGenerationIdentifier
                isEqualToString:generationIdentifier]) {
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.staleCompletions,
                1, memory_order_relaxed);
            return nil;
        }
        atomic_fetch_add_explicit(
            ready == nil
                ? &MTRuntimeStaticIconSnapshotObservation.decodeFailures
                : &MTRuntimeStaticIconSnapshotObservation.decodeSuccesses,
            1, memory_order_relaxed);
        return ready;
    }

    return [self decodePendingResolutions:resolutions
                                cacheKey:cacheKey
                                   epoch:epoch
                        bundleIdentifier:bundleIdentifier
                   calendarConfiguration:calendarConfiguration
                         calendarContent:calendarContent
                           imageContract:imageContract
                             notifyReady:NO];
}

- (UIImage *)decodeImageForResolution:
    (MTStaticIconSnapshotResolution *)resolution
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *)calendarConfiguration
                     calendarContent:(MTCalendarIconContent *)calendarContent
                       imageContract:
                           (MTStaticIconImageContract)imageContract
                        residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    NSError *decodeError = nil;
    BOOL usesLegacyClockCanvas = [bundleIdentifier
            isEqualToString:MTClockIconTargetBundleIdentifier] &&
        imageContract.pixelWidth == 180 &&
        imageContract.pixelHeight == 180;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
        resource:resolution.resource
        targetPixelWidth:imageContract.pixelWidth
        targetPixelHeight:imageContract.pixelHeight
        resizePolicy:usesLegacyClockCanvas
            ? MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale
            : MTRuntimePublishedImageResizePolicyBoundedScaleToFill
        error:&decodeError];
    UIImage *image = decoded == nil ? nil : [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:(CGFloat)imageContract.scale
        orientation:UIImageOrientationUp];
    if (image != nil && calendarConfiguration != nil) {
        image = MTCalendarIconRenderBackground(
            image, calendarConfiguration, calendarContent);
    }
    if (!CGSizeEqualToSize(image.size, imageContract.pointSize) ||
        image.scale != imageContract.scale ||
        decoded.residentCost > MTStaticIconMaximumReadyCost) {
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    return image;
}

- (UIImage *)decodeImageForResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *)calendarConfiguration
                     calendarContent:(MTCalendarIconContent *)calendarContent
                       imageContract:
                           (MTStaticIconImageContract)imageContract
                        residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    for (MTStaticIconSnapshotResolution *resolution in resolutions) {
        NSUInteger candidateCost = 0;
        UIImage *image = [self decodeImageForResolution:resolution
                                       bundleIdentifier:bundleIdentifier
                                   calendarConfiguration:calendarConfiguration
                                         calendarContent:calendarContent
                                           imageContract:imageContract
                                            residentCost:&candidateCost];
        if (image != nil) {
            if (residentCost != NULL) *residentCost = candidateCost;
            return image;
        }
    }
    return nil;
}

- (UIImage *)decodePendingResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                            cacheKey:(NSString *)cacheKey
                               epoch:(uint64_t)epoch
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *)calendarConfiguration
                     calendarContent:(MTCalendarIconContent *)calendarContent
                       imageContract:
                           (MTStaticIconImageContract)imageContract
                         notifyReady:(BOOL)notifyReady {
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.decodeScheduled,
        1, memory_order_relaxed);
    NSUInteger residentCost = 0;
    MTStaticIconSnapshotResolution *primaryResolution = resolutions.firstObject;
    if (primaryResolution == nil) return nil;
    UIImage *image = [self decodeImageForResolutions:resolutions
                                  bundleIdentifier:bundleIdentifier
                              calendarConfiguration:calendarConfiguration
                                    calendarContent:calendarContent
                                      imageContract:imageContract
                                       residentCost:&residentCost];
    uint64_t evictionsBefore = self.cache.evictionCount;
    BOOL accepted = [self.cache
        completeKey:cacheKey
        generationIdentifier:primaryResolution.generationIdentifier
        epoch:epoch
        object:image
        cost:image == nil ? 0 : residentCost];
    if (!accepted) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.staleCompletions,
            1, memory_order_relaxed);
        return nil;
    }
    if (image != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.decodeSuccesses,
            1, memory_order_relaxed);
        MTStaticIconSnapshotImageReadyHandler handler =
            notifyReady ? self.imageReadyHandler : nil;
        if (handler != nil) {
            handler(bundleIdentifier, primaryResolution.generationIdentifier);
        }
    } else {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
    }
    uint64_t evictionsAfter = self.cache.evictionCount;
    if (evictionsAfter > evictionsBefore) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.cacheEvictions,
            evictionsAfter - evictionsBefore, memory_order_relaxed);
    }
    return image;
}

- (void)scheduleDecodeForResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                            cacheKey:(NSString *)cacheKey
                               epoch:(uint64_t)epoch
                    bundleIdentifier:(NSString *)bundleIdentifier
               calendarConfiguration:
                    (MTCalendarIconConfiguration *)calendarConfiguration
                     calendarContent:
                    (MTCalendarIconContent *)calendarContent
                       imageContract:
                    (MTStaticIconImageContract)imageContract
                         notifyReady:(BOOL)notifyReady {
    MTStaticIconSnapshotResolution *primaryResolution = resolutions.firstObject;
    if (primaryResolution == nil) return;
    dispatch_async(self.decodeQueue, ^{
        if (![self.cache claimPendingKey:cacheKey
                generationIdentifier:primaryResolution.generationIdentifier
                epoch:epoch]) {
            (void)[self.cache waitForPendingKey:cacheKey
                generationIdentifier:primaryResolution.generationIdentifier
                epoch:epoch];
            return;
        }
        [self decodePendingResolutions:resolutions
                             cacheKey:cacheKey
                                epoch:epoch
                     bundleIdentifier:bundleIdentifier
                calendarConfiguration:calendarConfiguration
                      calendarContent:calendarContent
                        imageContract:imageContract
                          notifyReady:notifyReady];
    });
}

- (void)prewarmBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
    expectedGenerationIdentifier:(NSString *)expectedGenerationIdentifier
                       completion:
                           (MTStaticIconSnapshotPrewarmCompletion)completion {
    NSUInteger count = MIN(bundleIdentifiers.count,
                           MTStaticIconSnapshotPrewarmBatchLimit);
    NSMutableSet<NSString *> *resolvedIdentifiers = [NSMutableSet set];
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.prewarmBatches,
        1, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.prewarmIdentifiers,
        count, memory_order_relaxed);
    MTGeneration *generation = self.kernel.currentSnapshot.generation;
    NSString *generationIdentifier = generation.generationIdentifier;
    if (![generationIdentifier
            isEqualToString:expectedGenerationIdentifier]) {
        dispatch_async(self.decodeQueue, ^{
            completion([NSSet set]);
        });
        return;
    }
    for (NSUInteger index = 0; index < count; index++) {
        NSString *bundleIdentifier = bundleIdentifiers[index];
        NSError *calendarError = nil;
        MTCalendarIconConfiguration *calendarConfiguration =
            [self.calendarResolver
                configurationForBundleIdentifier:bundleIdentifier
                                       generation:generation
                                            error:&calendarError];
        MTCalendarIconContent *calendarContent = calendarConfiguration == nil
            ? nil : self.calendarContentProvider.currentContent;
        if (calendarError != nil ||
            (calendarConfiguration != nil && calendarContent == nil)) {
            continue;
        }
        MTStaticIconImageContract imageContract = MTStaticIconImageContractMake(
            MTStaticIconVisualProofExpectedPointSize,
            MTStaticIconPrewarmScale());
        NSString *cacheKey = MTStaticIconCacheKey(
            bundleIdentifier, calendarContent, imageContract);
        UIImage *ready = nil;
        uint64_t epoch = 0;
        MTRuntimeAsyncCacheDisposition disposition = [self.cache
            lookupObjectForGenerationIdentifier:generationIdentifier
            key:cacheKey object:&ready epoch:&epoch];
        if (disposition == MTRuntimeAsyncCacheDispositionReady) {
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.prewarmResourceHits,
                1, memory_order_relaxed);
            [resolvedIdentifiers addObject:bundleIdentifier];
            continue;
        }
        if (disposition == MTRuntimeAsyncCacheDispositionFailed) continue;

        NSError *resolutionError = nil;
        NSArray<MTStaticIconSnapshotResolution *> *resolutions = [self.resolver
            resolutionsForBundleIdentifier:bundleIdentifier
            scale:(NSUInteger)MTStaticIconPrewarmScale()
            deviceTrait:MTStaticIconDeviceTrait()
            error:&resolutionError];
        MTStaticIconSnapshotResolution *primaryResolution =
            resolutions.firstObject;
        if (primaryResolution == nil ||
            ![primaryResolution.generationIdentifier
                isEqualToString:expectedGenerationIdentifier]) {
            if (disposition == MTRuntimeAsyncCacheDispositionScheduled &&
                [self.cache claimPendingKey:cacheKey
                    generationIdentifier:generationIdentifier
                    epoch:epoch]) {
                (void)[self.cache completeKey:cacheKey
                    generationIdentifier:generationIdentifier
                    epoch:epoch object:nil cost:0];
            }
            continue;
        }
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.prewarmResourceHits,
            1, memory_order_relaxed);
        [resolvedIdentifiers addObject:bundleIdentifier];
        if (disposition == MTRuntimeAsyncCacheDispositionScheduled) {
            [self scheduleDecodeForResolutions:resolutions
                                     cacheKey:cacheKey
                                        epoch:epoch
                             bundleIdentifier:bundleIdentifier
                    calendarConfiguration:calendarConfiguration
                          calendarContent:calendarContent
                            imageContract:imageContract
                                  notifyReady:NO];
        }
    }
    NSSet<NSString *> *result = [resolvedIdentifiers copy];
    dispatch_async(self.decodeQueue, ^{
        completion(result);
    });
}

@end

static os_unfair_lock MTStaticIconSnapshotModuleLock = OS_UNFAIR_LOCK_INIT;
static MTStaticIconSnapshotModule *MTStaticIconSnapshotModuleInstance;

static void MTStaticIconSnapshotSetError(NSError **error,
                                         NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTStaticIconSnapshotModuleErrorDomain
                                 code:1
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

BOOL MTStaticIconSnapshotConfigure(MTRuntimeKernel *kernel,
                                   BOOL calendarCompositeEnabled,
                                   NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) {
        MTStaticIconSnapshotSetError(error,
            @"Static icon snapshot module requires one Runtime Kernel.");
        return NO;
    }
    os_unfair_lock_lock(&MTStaticIconSnapshotModuleLock);
    if (MTStaticIconSnapshotModuleInstance == nil) {
        MTStaticIconSnapshotModuleInstance =
            [[MTStaticIconSnapshotModule alloc]
                initWithKernel:kernel
                calendarCompositeEnabled:calendarCompositeEnabled];
    }
    BOOL configured = MTStaticIconSnapshotModuleInstance != nil;
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            MTStaticIconSnapshotModuleStateConfigured,
            memory_order_relaxed);
        MTRuntimeABIReportRecordModuleState(
            MTStaticIconSnapshotModuleID,
            MTStaticIconSnapshotModuleStateConfigured, @"Configured");
    }
    os_unfair_lock_unlock(&MTStaticIconSnapshotModuleLock);
    if (!configured) {
        MTStaticIconSnapshotSetError(error,
            @"Static icon snapshot module could not allocate its bounded state.");
    }
    return configured;
}

BOOL MTStaticIconSnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTStaticIconSnapshotModuleLock);
    BOOL prepared = MTStaticIconSnapshotModuleInstance != nil;
    if (prepared) {
        atomic_store_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            MTStaticIconSnapshotModuleStatePrepared,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTStaticIconSnapshotModuleID, MTStaticIconSnapshotModuleStatePrepared, @"Prepared");
    }
    os_unfair_lock_unlock(&MTStaticIconSnapshotModuleLock);
    return prepared;
}

void MTStaticIconSnapshotSetImageReadyHandler(
    MTStaticIconSnapshotImageReadyHandler handler) {
    MTStaticIconSnapshotModuleInstance.imageReadyHandler = handler;
}

id MTStaticIconSnapshotResolve(NSString *bundleIdentifier,
                               id originalResult) {
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return nil;
    }
    MTStaticIconSnapshotModule *module = MTStaticIconSnapshotModuleInstance;
    if (![originalResult isKindOfClass:UIImage.class]) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.lookupCalls,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.unsupportedOriginalMisses,
            1, memory_order_relaxed);
        return nil;
    }
    UIImage *originalImage = originalResult;
    return [module resolveBundleIdentifier:bundleIdentifier
                         originalPointSize:originalImage.size
                                     scale:originalImage.scale
                         contractValidator:
                             MTStaticIconSystemSurfaceImageContractIsSupported];
}

id MTStaticIconSnapshotResolveSystemSurface(NSString *bundleIdentifier,
                                            CGSize pointSize,
                                            CGFloat scale) {
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return nil;
    }
    return [MTStaticIconSnapshotModuleInstance
        resolveBundleIdentifier:bundleIdentifier
             originalPointSize:pointSize
                         scale:scale
             contractValidator:
                 MTStaticIconSystemSurfaceImageContractIsSupported];
}

id MTStaticIconSnapshotResolveReady(NSString *bundleIdentifier,
                                    CGSize pointSize,
                                    CGFloat scale) {
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return nil;
    }
    return [MTStaticIconSnapshotModuleInstance
        readyImageForBundleIdentifier:bundleIdentifier
        pointSize:pointSize
        scale:scale];
}

id MTStaticIconSnapshotResolveSecondarySurfaceImage(
    NSString *bundleIdentifier,
    id originalResult,
    CGSize *pointSizeOut,
    CGFloat *scaleOut) {
    if (pointSizeOut != NULL) *pointSizeOut = CGSizeZero;
    if (scaleOut != NULL) *scaleOut = 0;
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return nil;
    }
    id<MTStaticIconImageLike> source = originalResult;
    CGFloat scale = source.scale;
    CGImageRef image = source.CGImage;
    CGSize pointSize = image == NULL || scale <= 0 ? CGSizeZero :
        CGSizeMake((CGFloat)CGImageGetWidth(image) / scale,
                   (CGFloat)CGImageGetHeight(image) / scale);
    id resolved = [MTStaticIconSnapshotModuleInstance
        resolveBundleIdentifier:bundleIdentifier
             originalPointSize:pointSize
                         scale:scale
             contractValidator:
                 MTStaticIconShareSheetImageContractIsSupported];
    if (resolved != nil) {
        if (pointSizeOut != NULL) *pointSizeOut = pointSize;
        if (scaleOut != NULL) *scaleOut = scale;
    }
    return resolved;
}

void MTStaticIconSnapshotPrewarmBundleIdentifiers(
    NSArray<NSString *> *bundleIdentifiers,
    NSString *expectedGenerationIdentifier,
    MTStaticIconSnapshotPrewarmCompletion completion) {
    NSCParameterAssert(completion != nil);
    MTStaticIconSnapshotModule *module = MTStaticIconSnapshotModuleInstance;
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
            MTStaticIconSnapshotModuleStatePrepared ||
        module == nil || bundleIdentifiers.count == 0 ||
        expectedGenerationIdentifier.length == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            completion([NSSet set]);
        });
        return;
    }
    [module prewarmBundleIdentifiers:bundleIdentifiers
        expectedGenerationIdentifier:expectedGenerationIdentifier
                           completion:completion];
}
