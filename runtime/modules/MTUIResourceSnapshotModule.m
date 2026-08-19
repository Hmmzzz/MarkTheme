#import "MTUIResourceSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTRuntimeAsyncObjectCache.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTUIResourceSnapshotResolver.h"

NSString *const MTUIResourceSnapshotModuleID = @"ui-resources.snapshot";
NSString *const MTUIResourceSnapshotModuleErrorDomain =
    @"com.hmmzzz.marktheme.ui-resource-snapshot-module";

static const NSUInteger MTUIResourceMaximumReadyCount = 128;
static const NSUInteger MTUIResourceMaximumReadyCost = 16 * 1024 * 1024;
static const NSUInteger MTUIResourceMaximumPendingCount = 16;
static const NSUInteger MTUIResourceMaximumFailureCount = 128;

MTUIResourceSnapshotObservation MTRuntimeUIResourceSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTUIResourceSnapshotModuleStateDormant),
    .lookupCalls = ATOMIC_VAR_INIT(0),
    .snapshotMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .replacementResults = ATOMIC_VAR_INIT(0),
    .memoryPressurePurges = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTUIResourceSnapshotObservation) == 72,
    "The UI resource observation layout must remain fixed.");

typedef struct MTUIResourceImageContract {
    CGSize pointSize;
    CGFloat scale;
    UIEdgeInsets alignmentRectInsets;
    UIImageRenderingMode renderingMode;
    NSUInteger semanticScale;
    uint32_t pixelWidth;
    uint32_t pixelHeight;
} MTUIResourceImageContract;

static void MTUIResourceCollectAttachedViewControllers(
    UIViewController *controller,
    NSHashTable<UIViewController *> *visited,
    NSMutableArray<UIViewController *> *result) {
    if (controller == nil || [visited containsObject:controller]) return;
    [visited addObject:controller];
    if (controller.viewIfLoaded.window != nil) [result addObject:controller];
    MTUIResourceCollectAttachedViewControllers(
        controller.presentedViewController, visited, result);
    for (UIViewController *child in controller.childViewControllers) {
        MTUIResourceCollectAttachedViewControllers(child, visited, result);
    }
}

@interface MTUIResourceSnapshotModule : NSObject
@property(nonatomic, strong) MTUIResourceSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeAsyncObjectCache<UIImage *> *cache;
@property(nonatomic, strong) dispatch_source_t memoryPressureSource;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel;
- (UIImage *_Nullable)resolveSurface:(NSString *)surface
                        resourceName:(NSString *)resourceName
                       originalImage:(UIImage *_Nullable)originalImage;
@end

@implementation MTUIResourceSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel {
    self = [super init];
    if (self == nil) return nil;
    _resolver = [[MTUIResourceSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return kernel.currentSnapshot;
        }];
    _imageLoader = [[MTRuntimePublishedImageLoader alloc]
        initWithMaximumEncodedByteCount:8ULL * 1024ULL * 1024ULL
        maximumDecodedByteCount:4ULL * 1024ULL * 1024ULL];
    _cache = [[MTRuntimeAsyncObjectCache alloc]
        initWithMaximumReadyCount:MTUIResourceMaximumReadyCount
        maximumReadyCost:MTUIResourceMaximumReadyCost
        maximumPendingCount:MTUIResourceMaximumPendingCount
        maximumFailureCount:MTUIResourceMaximumFailureCount];
    _memoryPressureSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (_resolver == nil || _imageLoader == nil || _cache == nil ||
        _memoryPressureSource == nil) {
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_memoryPressureSource, ^{
        MTUIResourceSnapshotModule *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.cache purgeReadyObjectsAndCancelPending];
        atomic_fetch_add_explicit(
            &MTRuntimeUIResourceSnapshotObservation.memoryPressurePurges,
            1, memory_order_relaxed);
    });
    dispatch_resume(_memoryPressureSource);
    return self;
}

static BOOL MTUIResourceContractForImage(
    UIImage *image,
    UIImageRenderingMode renderingMode,
    MTUIResourceImageContract *contract) {
    if (![image isKindOfClass:UIImage.class] ||
        !isfinite(image.size.width) || !isfinite(image.size.height) ||
        !isfinite(image.scale) || image.size.width <= 0 ||
        image.size.height <= 0 || image.scale < 1 || image.scale > 3) {
        return NO;
    }
    double width = image.size.width * image.scale;
    double height = image.size.height * image.scale;
    double roundedScale = round(image.scale);
    if (!isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
        width > 4096 || height > 4096 ||
        fabs(image.scale - roundedScale) > 0.001) {
        return NO;
    }
    uint32_t roundedWidth = (uint32_t)llround(width);
    uint32_t roundedHeight = (uint32_t)llround(height);
    if (roundedWidth == 0 || roundedHeight == 0) return NO;
    contract->pointSize = image.size;
    contract->scale = image.scale;
    contract->alignmentRectInsets = image.alignmentRectInsets;
    contract->renderingMode = renderingMode;
    contract->semanticScale = (NSUInteger)roundedScale;
    contract->pixelWidth = roundedWidth;
    contract->pixelHeight = roundedHeight;
    return YES;
}

static BOOL MTUIResourceShareContract(
    UIImage *_Nullable originalImage,
    MTUIResourceImageContract *contract) {
    if (originalImage != nil) {
        return MTUIResourceContractForImage(
            originalImage, UIImageRenderingModeAlwaysOriginal, contract);
    }
    CGFloat scale = UIScreen.mainScreen.scale;
    double roundedScale = round(scale);
    if (!isfinite(scale) || scale < 1 || scale > 3 ||
        fabs(scale - roundedScale) > 0.001) {
        return NO;
    }
    contract->pointSize = CGSizeMake(60, 60);
    contract->scale = scale;
    contract->alignmentRectInsets = UIEdgeInsetsZero;
    contract->renderingMode = UIImageRenderingModeAlwaysOriginal;
    contract->semanticScale = (NSUInteger)roundedScale;
    contract->pixelWidth = (uint32_t)llround(60 * scale);
    contract->pixelHeight = (uint32_t)llround(60 * scale);
    return YES;
}

static NSString *MTUIResourceCacheKey(
    MTUIResourceSnapshotResolution *resolution,
    MTUIResourceImageContract contract) {
    return [NSString stringWithFormat:@"%@|%@|%@|%ux%u@%.0f|%ld|%@",
        resolution.generationIdentifier,
        resolution.canonicalResourceKey,
        resolution.resource.contentSHA256,
        contract.pixelWidth, contract.pixelHeight, contract.scale,
        (long)contract.renderingMode,
        NSStringFromUIEdgeInsets(contract.alignmentRectInsets)];
}

- (UIImage *)decodeResolution:(MTUIResourceSnapshotResolution *)resolution
                     contract:(MTUIResourceImageContract)contract
                  residentCost:(NSUInteger *)residentCost {
    if (residentCost != NULL) *residentCost = 0;
    NSError *decodeError = nil;
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
        resource:resolution.resource
        targetPixelWidth:contract.pixelWidth
        targetPixelHeight:contract.pixelHeight
        error:&decodeError];
    if (decoded == nil || decoded.residentCost > MTUIResourceMaximumReadyCost) {
        return nil;
    }
    UIImage *image = [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:contract.scale
        orientation:UIImageOrientationUp];
    image = [image imageWithRenderingMode:contract.renderingMode];
    if (!UIEdgeInsetsEqualToEdgeInsets(
            contract.alignmentRectInsets, UIEdgeInsetsZero)) {
        image = [image imageWithAlignmentRectInsets:
            contract.alignmentRectInsets];
    }
    if (image == nil || !CGSizeEqualToSize(image.size, contract.pointSize) ||
        fabs(image.scale - contract.scale) > 0.001) {
        return nil;
    }
    if (residentCost != NULL) *residentCost = decoded.residentCost;
    return image;
}

- (UIImage *)resolveSurface:(NSString *)surface
                resourceName:(NSString *)resourceName
               originalImage:(UIImage *)originalImage {
    atomic_fetch_add_explicit(
        &MTRuntimeUIResourceSnapshotObservation.lookupCalls,
        1, memory_order_relaxed);
    BOOL shareActivity = [surface isEqualToString:@"share.activity"];
    MTUIResourceImageContract contract = {0};
    BOOL validContract = shareActivity
        ? MTUIResourceShareContract(originalImage, &contract)
        : MTUIResourceContractForImage(
            originalImage, originalImage.renderingMode, &contract);
    if (!validContract) {
        return nil;
    }
    NSError *resolutionError = nil;
    MTUIResourceSnapshotResolution *resolution = shareActivity
        ? [self.resolver resolutionForShareActivityName:resourceName
                                                 scale:contract.semanticScale
                                                 error:&resolutionError]
        : [self.resolver resolutionForPreferencesIconName:resourceName
                                                    scale:contract.semanticScale
                                                    error:&resolutionError];
    if (resolution == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeUIResourceSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeUIResourceSnapshotObservation.resourceHits,
        1, memory_order_relaxed);

    NSString *cacheKey = MTUIResourceCacheKey(resolution, contract);
    UIImage *ready = nil;
    uint64_t epoch = 0;
    MTRuntimeAsyncCacheDisposition disposition = [self.cache
        lookupObjectForGenerationIdentifier:resolution.generationIdentifier
        key:cacheKey object:&ready epoch:&epoch];
    if (disposition == MTRuntimeAsyncCacheDispositionReady) {
        atomic_fetch_add_explicit(
            &MTRuntimeUIResourceSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return ready;
    }
    if (disposition == MTRuntimeAsyncCacheDispositionFailed) return nil;
    if ((disposition == MTRuntimeAsyncCacheDispositionPending ||
         disposition == MTRuntimeAsyncCacheDispositionScheduled) &&
        ![self.cache claimPendingKey:cacheKey
            generationIdentifier:resolution.generationIdentifier
            epoch:epoch]) {
        return [self.cache waitForPendingKey:cacheKey
            generationIdentifier:resolution.generationIdentifier
            epoch:epoch];
    }

    NSUInteger residentCost = 0;
    UIImage *image = [self decodeResolution:resolution
                                   contract:contract
                               residentCost:&residentCost];
    if (disposition != MTRuntimeAsyncCacheDispositionSaturated) {
        BOOL accepted = [self.cache
            completeKey:cacheKey
            generationIdentifier:resolution.generationIdentifier
            epoch:epoch
            object:image
            cost:image == nil ? 0 : residentCost];
        if (!accepted) image = nil;
    } else if (![self.cache.activeGenerationIdentifier
            isEqualToString:resolution.generationIdentifier]) {
        image = nil;
    }
    atomic_fetch_add_explicit(
        image == nil
            ? &MTRuntimeUIResourceSnapshotObservation.decodeFailures
            : &MTRuntimeUIResourceSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    if (image != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeUIResourceSnapshotObservation.replacementResults,
            1, memory_order_relaxed);
    }
    return image;
}

@end

static os_unfair_lock MTUIResourceSnapshotModuleLock = OS_UNFAIR_LOCK_INIT;
static MTUIResourceSnapshotModule *MTUIResourceSnapshotModuleInstance;

static void MTUIResourceSnapshotSetError(NSError **error,
                                         NSString *description) {
    if (error == NULL) return;
    *error = [NSError
        errorWithDomain:MTUIResourceSnapshotModuleErrorDomain
                   code:1
               userInfo:@{ NSLocalizedDescriptionKey : description }];
}

BOOL MTUIResourceSnapshotConfigure(MTRuntimeKernel *kernel,
                                   NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) {
        MTUIResourceSnapshotSetError(error,
            @"UI resource snapshot module requires one Runtime Kernel.");
        return NO;
    }
    os_unfair_lock_lock(&MTUIResourceSnapshotModuleLock);
    if (MTUIResourceSnapshotModuleInstance == nil) {
        MTUIResourceSnapshotModuleInstance =
            [[MTUIResourceSnapshotModule alloc] initWithKernel:kernel];
    }
    BOOL configured = MTUIResourceSnapshotModuleInstance != nil;
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeUIResourceSnapshotObservation.state,
            MTUIResourceSnapshotModuleStateConfigured,
            memory_order_relaxed);
    }
    os_unfair_lock_unlock(&MTUIResourceSnapshotModuleLock);
    if (!configured) {
        MTUIResourceSnapshotSetError(error,
            @"UI resource module could not allocate its bounded cache.");
    }
    return configured;
}

BOOL MTUIResourceSnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTUIResourceSnapshotModuleLock);
    BOOL prepared = MTUIResourceSnapshotModuleInstance != nil;
    if (prepared) {
        atomic_store_explicit(
            &MTRuntimeUIResourceSnapshotObservation.state,
            MTUIResourceSnapshotModuleStatePrepared,
            memory_order_release);
    }
    os_unfair_lock_unlock(&MTUIResourceSnapshotModuleLock);
    return prepared;
}

id MTUIResourceSnapshotResolve(NSString *resourceName,
                               id originalResult) {
    if (atomic_load_explicit(
            &MTRuntimeUIResourceSnapshotObservation.state,
            memory_order_acquire) !=
            MTUIResourceSnapshotModuleStatePrepared ||
        ![resourceName isKindOfClass:NSString.class] ||
        resourceName.length == 0 ||
        ![originalResult isKindOfClass:UIImage.class]) {
        return nil;
    }
    return [MTUIResourceSnapshotModuleInstance
        resolveSurface:@"preferences.icon"
        resourceName:resourceName
        originalImage:(UIImage *)originalResult];
}

id MTUIResourceSnapshotResolveShareActivity(NSString *activityName,
                                            id originalResult) {
    if (atomic_load_explicit(
            &MTRuntimeUIResourceSnapshotObservation.state,
            memory_order_acquire) !=
            MTUIResourceSnapshotModuleStatePrepared ||
        ![activityName isKindOfClass:NSString.class] ||
        activityName.length == 0 ||
        (originalResult != nil &&
         ![originalResult isKindOfClass:UIImage.class])) {
        return nil;
    }
    return [MTUIResourceSnapshotModuleInstance
        resolveSurface:@"share.activity"
        resourceName:activityName
        originalImage:(UIImage *)originalResult];
}

void MTUIResourceSnapshotReload(void) {
    [MTUIResourceSnapshotModuleInstance.cache
        purgeReadyObjectsAndCancelPending];
}

NSArray<id> *MTUIResourceSnapshotAttachedViewControllers(void) {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSHashTable<UIViewController *> *visited = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality |
                             NSPointerFunctionsStrongMemory];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            MTUIResourceCollectAttachedViewControllers(
                window.rootViewController, visited, result);
        }
    }
    return result;
}
