#import "MTStaticIconSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <os/lock.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTCalendarIconContent.h"
#import "MTCalendarIconRenderer.h"
#import "MTCalendarIconSnapshotResolver.h"
#import "MTClockIconsModule.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimeWorkCoordinator.h"
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
static const NSUInteger MTStaticIconMaximumPendingCount = 32;
static const uint64_t MTStaticIconDecodeWaitNanoseconds =
    120 * NSEC_PER_MSEC;
static NSString *const MTStaticIconCapabilityID = @"icons.static";
static _Atomic(uint32_t) MTStaticIconResourcesAvailable = ATOMIC_VAR_INIT(0);

typedef BOOL (*MTStaticIconImageContractValidator)(CGSize, CGFloat);

typedef struct MTStaticIconImageContract {
    CGSize pointSize;
    NSUInteger scale;
    NSUInteger pixelWidth;
    NSUInteger pixelHeight;
} MTStaticIconImageContract;

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
    .schemaVersion = 4,
    .state = ATOMIC_VAR_INIT(MTStaticIconSnapshotModuleStateDormant),
    .lookupCalls = ATOMIC_VAR_INIT(0),
    .unsupportedOriginalMisses = ATOMIC_VAR_INIT(0),
    .snapshotMisses = ATOMIC_VAR_INIT(0),
    .resourceHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .decodeAttempts = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .memoryPressurePurges = ATOMIC_VAR_INIT(0),
    .cacheEvictions = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTStaticIconSnapshotObservation) == 88,
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
@property(nonatomic, strong) MTRuntimeSnapshot *snapshot;
@property(nonatomic, strong) MTStaticIconSnapshotResolver *resolver;
@property(nonatomic, strong, nullable)
    MTCalendarIconSnapshotResolver *calendarResolver;
@property(nonatomic, strong, nullable)
    MTCalendarIconContentProvider *calendarContentProvider;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    MTRuntimeObjectCache<UIImage *> *cache;
@property(nonatomic, strong) MTRuntimeWorkCoordinator *workCoordinator;
@property(nonatomic, strong) dispatch_source_t memoryPressureSource;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
       calendarCompositeEnabled:(BOOL)calendarCompositeEnabled;
- (id _Nullable)resolveBundleIdentifier:(NSString *)bundleIdentifier
                      originalPointSize:(CGSize)originalPointSize
                                  scale:(CGFloat)scale
                      contractValidator:
                          (MTStaticIconImageContractValidator)contractValidator
                calendarContentOverride:
                          (MTCalendarIconContent *_Nullable)calendarContentOverride;
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
@end

@implementation MTStaticIconSnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
       calendarCompositeEnabled:(BOOL)calendarCompositeEnabled {
    self = [super init];
    if (self == nil) return nil;
    _snapshot = kernel.currentSnapshot;
    MTRuntimeSnapshot *capturedSnapshot = _snapshot;
    _resolver = [[MTStaticIconSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return capturedSnapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    if (calendarCompositeEnabled) {
        _calendarResolver = [[MTCalendarIconSnapshotResolver alloc] init];
        _calendarContentProvider =
            [[MTCalendarIconContentProvider alloc] init];
    }
    _cache = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTStaticIconMaximumReadyCount
        maximumCost:MTStaticIconMaximumReadyCost];
    _workCoordinator = [[MTRuntimeWorkCoordinator alloc]
        initWithMaximumPendingCount:MTStaticIconMaximumPendingCount];
    _memoryPressureSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    if (_resolver == nil || _imageLoader == nil || _cache == nil ||
        _workCoordinator == nil || _memoryPressureSource == nil) {
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
        [strongSelf.cache removeAllObjects];
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.memoryPressurePurges,
            1, memory_order_relaxed);
    });
    dispatch_resume(_memoryPressureSource);
    BOOL resourcesAvailable = _snapshot.isReady &&
        [_snapshot.generation.descriptor.moduleIDs
            containsObject:MTStaticIconCapabilityID];
    atomic_store_explicit(&MTStaticIconResourcesAvailable,
                          resourcesAvailable ? 1 : 0,
                          memory_order_release);
    return self;
}

- (id)resolveBundleIdentifier:(NSString *)bundleIdentifier
            originalPointSize:(CGSize)originalPointSize
                        scale:(CGFloat)scale
            contractValidator:
                (MTStaticIconImageContractValidator)contractValidator
      calendarContentOverride:
                (MTCalendarIconContent *)calendarContentOverride {
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

    MTGeneration *generation = self.snapshot.generation;
    if (!self.snapshot.isReady || generation == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        return nil;
    }

    NSError *calendarError = nil;
    MTCalendarIconConfiguration *calendarConfiguration =
        calendarContentOverride == nil ? nil : [self.calendarResolver
            configurationForBundleIdentifier:bundleIdentifier
                                   generation:generation
                                        error:&calendarError];
    MTCalendarIconContent *calendarContent = calendarConfiguration == nil
        ? nil : calendarContentOverride;
    if (calendarError != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.snapshotMisses,
            1, memory_order_relaxed);
        return nil;
    }

    NSString *cacheKey = MTStaticIconCacheKey(
        bundleIdentifier, calendarContent, imageContract);
    UIImage *ready = [self.cache objectForKey:cacheKey];
    if (ready != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &MTRuntimeStaticIconSnapshotObservation.resourceHits,
            1, memory_order_relaxed);
        return ready;
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
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeStaticIconSnapshotObservation.resourceHits,
        1, memory_order_relaxed);

    BOOL completed = [self.workCoordinator
        performWorkForKey:cacheKey
        waitNanoseconds:MTStaticIconDecodeWaitNanoseconds
        work:^{
            atomic_fetch_add_explicit(
                &MTRuntimeStaticIconSnapshotObservation.decodeAttempts,
                1, memory_order_relaxed);
            NSUInteger residentCost = 0;
            UIImage *decoded = [self decodeImageForResolutions:resolutions
                bundleIdentifier:bundleIdentifier
                calendarConfiguration:calendarConfiguration
                calendarContent:calendarContent
                imageContract:imageContract
                residentCost:&residentCost];
            uint64_t evictionsBefore = self.cache.evictionCount;
            if (decoded != nil && residentCost > 0) {
                (void)[self.cache setObject:decoded forKey:cacheKey
                                      cost:residentCost];
            }
            atomic_fetch_add_explicit(
                decoded == nil
                    ? &MTRuntimeStaticIconSnapshotObservation.decodeFailures
                    : &MTRuntimeStaticIconSnapshotObservation.decodeSuccesses,
                1, memory_order_relaxed);
            uint64_t evictionsAfter = self.cache.evictionCount;
            if (evictionsAfter > evictionsBefore) {
                atomic_fetch_add_explicit(
                    &MTRuntimeStaticIconSnapshotObservation.cacheEvictions,
                    evictionsAfter - evictionsBefore, memory_order_relaxed);
            }
        }];
    return completed ? [self.cache objectForKey:cacheKey] : nil;
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

id MTStaticIconSnapshotResolveClockSource(CGSize pointSize,
                                          CGFloat scale) {
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return nil;
    }
    if (!atomic_load_explicit(
            &MTStaticIconResourcesAvailable, memory_order_acquire)) return nil;
    return [MTStaticIconSnapshotModuleInstance
        resolveBundleIdentifier:MTClockIconTargetBundleIdentifier
                         originalPointSize:pointSize
                                     scale:scale
                         contractValidator:
                             MTStaticIconSystemSurfaceImageContractIsSupported
                   calendarContentOverride:nil];
}

CGImageRef MTStaticIconSnapshotResolveCalendarSource(
    NSDateComponents *dateComponents,
    NSCalendar *calendar,
    NSInteger format,
    CGSize pointSize,
    CGFloat scale) {
    if (format != 0) return NULL;
    if (atomic_load_explicit(
            &MTRuntimeStaticIconSnapshotObservation.state,
            memory_order_acquire) !=
        MTStaticIconSnapshotModuleStatePrepared) {
        return NULL;
    }
    if (!atomic_load_explicit(
            &MTStaticIconResourcesAvailable, memory_order_acquire) ||
        ![dateComponents isKindOfClass:NSDateComponents.class] ||
        ![calendar isKindOfClass:NSCalendar.class]) {
        return NULL;
    }
    MTCalendarIconContent *content =
        [MTStaticIconSnapshotModuleInstance.calendarContentProvider
            contentForDateComponents:dateComponents
                               calendar:calendar];
    if (content == nil) return NULL;
    UIImage *image = [MTStaticIconSnapshotModuleInstance
        resolveBundleIdentifier:MTCalendarIconTargetBundleIdentifier
             originalPointSize:pointSize
                         scale:scale
             contractValidator:
                 MTStaticIconSystemSurfaceImageContractIsSupported
       calendarContentOverride:content];
    CGImageRef result = image.CGImage;
    return result == NULL ? NULL : CGImageRetain(result);
}
