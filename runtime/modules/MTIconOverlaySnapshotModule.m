#import "MTIconOverlaySnapshotModule.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTGenerationDescriptor.h"
#import "MTIconOverlayContract.h"
#import "MTIconMaskCompositor.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStaticIconVisualProofContract.h"
#import "MTSpringBoardDecorationSnapshotResolver.h"
#import "MTRuntimeABIReport.h"

NSString *const MTIconOverlaySnapshotModuleID = @"icon-overlay.snapshot";

static const NSUInteger MTIconOverlayMaximumReadyCount = 64;
static const NSUInteger MTIconOverlayMaximumReadyCost = 16 * 1024 * 1024;
static const NSUInteger MTIconOverlayMaximumContractCount = 8;

MTIconOverlaySnapshotObservation MTRuntimeIconOverlaySnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTIconOverlaySnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .overlayResourceHits = ATOMIC_VAR_INIT(0),
    .decodeSuccesses = ATOMIC_VAR_INIT(0),
    .decodeFailures = ATOMIC_VAR_INIT(0),
    .resolutionCalls = ATOMIC_VAR_INIT(0),
    .unsupportedCandidateMisses = ATOMIC_VAR_INIT(0),
    .alreadyProcessedHits = ATOMIC_VAR_INIT(0),
    .cacheHits = ATOMIC_VAR_INIT(0),
    .compositions = ATOMIC_VAR_INIT(0),
    .restores = ATOMIC_VAR_INIT(0),
    .memoryPressurePurges = ATOMIC_VAR_INIT(0),
    .cacheEvictions = ATOMIC_VAR_INIT(0),
};

_Static_assert(sizeof(MTIconOverlaySnapshotObservation) == 104,
    "The icon-overlay ModuleRuntime observation layout must remain fixed.");

@interface MTIconOverlayImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong, nullable)
    MTSpringBoardDecorationSnapshotResolution *overlayResolution;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, UIImage *> *overlayImagesByPixelDimension;
@property(nonatomic, strong, nullable) UIImage *primaryOverlayImage;
@end

@implementation MTIconOverlayImageSet
@end

@interface MTIconOverlayAppliedMetadata : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) UIImage *sourceImage;
@end

@implementation MTIconOverlayAppliedMetadata
@end

@interface MTIconOverlaySourceMetadata : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic, weak) UIImage *composedImage;
@end

@implementation MTIconOverlaySourceMetadata
@end

static char MTIconOverlayAppliedMetadataAssociationKey;
static char MTIconOverlaySourceMetadataAssociationKey;

@interface MTIconOverlaySnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong)
    MTSpringBoardDecorationSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong) MTRuntimeObjectCache<UIImage *> *cache;
@property(nonatomic, strong) dispatch_source_t memoryPressureSource;
@property(nonatomic, assign) BOOL systemSurfaceContractsEnabled;
@property(atomic, strong, nullable) MTIconOverlayImageSet *currentImageSet;
@property(atomic, assign) uint64_t requestedEpoch;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
     systemSurfaceContractsEnabled:(BOOL)systemSurfaceContractsEnabled;
- (void)reload;
- (nullable UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                               candidateImage:(nullable UIImage *)candidate;
- (nullable UIImage *)readyImageForBundleIdentifier:
    (NSString *)bundleIdentifier
                                    candidateImage:(nullable UIImage *)candidate;
@end

@implementation MTIconOverlaySnapshotModule

- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
     systemSurfaceContractsEnabled:(BOOL)systemSurfaceContractsEnabled {
    self = [super init];
    if (self == nil) return nil;
    _kernel = kernel;
    _systemSurfaceContractsEnabled = systemSurfaceContractsEnabled;
    _resolver = [[MTSpringBoardDecorationSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return kernel.currentSnapshot;
        }];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    _cache = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTIconOverlayMaximumReadyCount
        maximumCost:MTIconOverlayMaximumReadyCost];
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
        MTIconOverlaySnapshotModule *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.cache removeAllObjects];
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.memoryPressurePurges,
            1, memory_order_relaxed);
    });
    dispatch_resume(_memoryPressureSource);
    return self;
}

- (nullable UIImage *)decodeOverlayResolution:
    (MTSpringBoardDecorationSnapshotResolution *)resolution
                                 pixelDimension:(uint32_t)pixelDimension {
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:pixelDimension
             targetPixelHeight:pixelDimension
                         error:NULL];
    UIImage *image = decoded == nil ? nil : [[UIImage alloc]
        initWithCGImage:decoded.image
        scale:MTStaticIconVisualProofExpectedScale
        orientation:UIImageOrientationUp];
    BOOL supported = self.systemSurfaceContractsEnabled
        ? MTStaticIconSystemSurfaceImageContractIsSupported(
            image.size, image.scale)
        : MTStaticIconVisualProofImageContractIsSupported(
            image.size, image.scale);
    if (!supported ||
        image.imageOrientation != UIImageOrientationUp) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return image;
}

- (void)publishImageSet:(nullable MTIconOverlayImageSet *)imageSet
                   epoch:(uint64_t)epoch
    generationIdentifier:(nullable NSString *)generationIdentifier {
    if (self.requestedEpoch != epoch) return;
    NSString *active = self.kernel.currentSnapshot
        .state.activeGenerationIdentifier;
    if (generationIdentifier != nil &&
        ![active isEqualToString:generationIdentifier]) {
        return;
    }
    [self.cache removeAllObjects];
    self.currentImageSet = imageSet;
    atomic_store_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.state,
        imageSet == nil ? MTIconOverlaySnapshotModuleStateConfigured
                        : MTIconOverlaySnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTIconOverlaySnapshotModuleID,
        imageSet == nil ? MTIconOverlaySnapshotModuleStateConfigured
                        : MTIconOverlaySnapshotModuleStateReady,
        imageSet == nil ? @"Configured" : @"Ready");
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.reloads,
        1, memory_order_relaxed);
    uint64_t epoch = 0;
    @synchronized (self) {
        epoch = self.requestedEpoch + 1;
        self.requestedEpoch = epoch;
    }
    MTRuntimeSnapshot *snapshot = self.kernel.currentSnapshot;
    if (!snapshot.isReady) {
        [self publishImageSet:nil epoch:epoch generationIdentifier:nil];
        return;
    }

    MTGeneration *generation = snapshot.generation;
    MTGenerationDescriptor *descriptor = generation.descriptor;
    // The overlay activates on authored artwork alone, so presence of the
    // module in the Generation is the whole switch. There is no system
    // fallback: a miss simply leaves the icon exactly as produced.
    if (![descriptor.moduleIDs containsObject:MTIconOverlayModuleID]) {
        [self publishImageSet:nil
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }

    NSError *overlayError = nil;
    MTSpringBoardDecorationSnapshotResolution *overlay = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindIconOverlay
                     error:&overlayError];
    if (overlay == nil || overlayError != nil) {
        [self publishImageSet:nil
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.overlayResourceHits,
        1, memory_order_relaxed);

    UIImage *primaryOverlayImage = [self decodeOverlayResolution:overlay
                                                  pixelDimension:180];
    if (primaryOverlayImage == nil) {
        [self publishImageSet:nil
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }
    MTIconOverlayImageSet *imageSet = [[MTIconOverlayImageSet alloc] init];
    imageSet.generationIdentifier = overlay.generationIdentifier;
    imageSet.token = [NSString stringWithFormat:@"%@|%@",
        overlay.generationIdentifier, overlay.resource.contentSHA256];
    imageSet.overlayResolution = overlay;
    imageSet.overlayImagesByPixelDimension = [NSMutableDictionary dictionary];
    imageSet.primaryOverlayImage = primaryOverlayImage;
    imageSet.overlayImagesByPixelDimension[@180] = primaryOverlayImage;
    if (self.systemSurfaceContractsEnabled) {
        // The capability-probed secondary surfaces use 16pt, 29pt, 40pt, and
        // 60pt @3x application icons. Predecode those finite contracts once; an
        // uncommon in-range size is still decoded once on its proven call
        // boundary and retained in this same bounded process-local set.
        UIImage *smallOverlayImage = [self decodeOverlayResolution:overlay
                                                    pixelDimension:48];
        UIImage *shareMoreOverlayImage = [self decodeOverlayResolution:overlay
                                                        pixelDimension:87];
        UIImage *spotlightOverlayImage = [self decodeOverlayResolution:overlay
                                                        pixelDimension:120];
        if (smallOverlayImage != nil) {
            imageSet.overlayImagesByPixelDimension[@48] = smallOverlayImage;
        }
        if (shareMoreOverlayImage != nil) {
            imageSet.overlayImagesByPixelDimension[@87] =
                shareMoreOverlayImage;
        }
        if (spotlightOverlayImage != nil) {
            imageSet.overlayImagesByPixelDimension[@120] =
                spotlightOverlayImage;
        }
    }
    [self publishImageSet:imageSet
                    epoch:epoch
     generationIdentifier:overlay.generationIdentifier];
}

- (nullable UIImage *)overlayImageForImageSet:(MTIconOverlayImageSet *)imageSet
                                   sourceImage:(UIImage *)source {
    if (imageSet.overlayResolution == nil ||
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            source.size, source.scale)) {
        return nil;
    }
    CGImageRef sourceCGImage = source.CGImage;
    size_t pixelWidth = sourceCGImage == NULL ? 0 :
        CGImageGetWidth(sourceCGImage);
    size_t pixelHeight = sourceCGImage == NULL ? 0 :
        CGImageGetHeight(sourceCGImage);
    if (pixelWidth == 0 || pixelWidth != pixelHeight ||
        pixelWidth > UINT32_MAX) {
        return nil;
    }
    NSNumber *key = @(pixelWidth);
    @synchronized (imageSet) {
        UIImage *overlayImage = imageSet.overlayImagesByPixelDimension[key];
        if (overlayImage != nil) return overlayImage;
        if (imageSet.overlayImagesByPixelDimension.count >=
            MTIconOverlayMaximumContractCount) {
            return nil;
        }
        overlayImage = [self
            decodeOverlayResolution:imageSet.overlayResolution
                     pixelDimension:(uint32_t)pixelWidth];
        if (overlayImage != nil) {
            imageSet.overlayImagesByPixelDimension[key] = overlayImage;
        }
        return overlayImage;
    }
}

- (nullable UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                               candidateImage:(nullable UIImage *)candidate {
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.resolutionCalls,
        1, memory_order_relaxed);
    if (candidate == nil || bundleIdentifier.length == 0) return nil;

    MTIconOverlayImageSet *imageSet = self.currentImageSet;
    UIImage *source = candidate;
    BOOL unwrapped = NO;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        MTIconOverlayAppliedMetadata *metadata = objc_getAssociatedObject(
            source, &MTIconOverlayAppliedMetadataAssociationKey);
        if (metadata == nil) break;
        if (imageSet != nil &&
            [metadata.token isEqualToString:imageSet.token]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconOverlaySnapshotObservation.alreadyProcessedHits,
                1, memory_order_relaxed);
            return source;
        }
        if (metadata.sourceImage == nil || metadata.sourceImage == source) {
            return nil;
        }
        source = metadata.sourceImage;
        unwrapped = YES;
    }
    if (imageSet == nil) {
        if (unwrapped) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconOverlaySnapshotObservation.restores,
                1, memory_order_relaxed);
            return source;
        }
        return nil;
    }

    UIImage *overlayImage = [self overlayImageForImageSet:imageSet
                                              sourceImage:source];
    if (overlayImage == nil) return nil;

    MTIconOverlaySourceMetadata *sourceMetadata = objc_getAssociatedObject(
        source, &MTIconOverlaySourceMetadataAssociationKey);
    UIImage *sourceCachedImage = sourceMetadata.composedImage;
    if ([sourceMetadata.token isEqualToString:imageSet.token] &&
        sourceCachedImage != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return sourceCachedImage;
    }

    CGImageRef sourceCGImage = source.CGImage;
    CGImageRef overlayCGImage = overlayImage.CGImage;
    BOOL sourceContractSupported = self.systemSurfaceContractsEnabled
        ? MTStaticIconSystemSurfaceImageContractIsSupported(
            source.size, source.scale)
        : MTStaticIconVisualProofImageContractIsSupported(
            source.size, source.scale);
    BOOL overlayContractSupported = self.systemSurfaceContractsEnabled
        ? MTStaticIconSystemSurfaceImageContractIsSupported(
            overlayImage.size, overlayImage.scale)
        : MTStaticIconVisualProofImageContractIsSupported(
            overlayImage.size, overlayImage.scale);
    size_t expectedPixelDimension = sourceCGImage == NULL ? 0 :
        CGImageGetWidth(sourceCGImage);
    if (sourceCGImage == NULL ||
        overlayCGImage == NULL ||
        source.imageOrientation != UIImageOrientationUp ||
        overlayImage.imageOrientation != UIImageOrientationUp ||
        !sourceContractSupported || !overlayContractSupported ||
        !CGSizeEqualToSize(source.size, overlayImage.size) ||
        source.scale != overlayImage.scale ||
        CGImageGetWidth(sourceCGImage) != expectedPixelDimension ||
        CGImageGetHeight(sourceCGImage) != expectedPixelDimension ||
        CGImageGetWidth(overlayCGImage) != expectedPixelDimension ||
        CGImageGetHeight(overlayCGImage) != expectedPixelDimension) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation
                .unsupportedCandidateMisses,
            1, memory_order_relaxed);
        return nil;
    }

    NSString *cacheKey = [NSString stringWithFormat:
        @"%@|%@|%zux%zu|%p|%p",
        imageSet.token, bundleIdentifier,
        expectedPixelDimension, expectedPixelDimension,
        (__bridge void *)source, (void *)sourceCGImage];
    UIImage *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return cached;
    }

    CGImageRef composedCGImage = MTIconOverlayCreateImage(
        sourceCGImage, overlayCGImage);
    if (composedCGImage == NULL) return nil;
    UIImage *composed = [[UIImage alloc]
        initWithCGImage:composedCGImage
        scale:source.scale
        orientation:UIImageOrientationUp];
    size_t bytesPerRow = CGImageGetBytesPerRow(composedCGImage);
    size_t height = CGImageGetHeight(composedCGImage);
    CGImageRelease(composedCGImage);
    if (composed == nil || height == 0 ||
        bytesPerRow > NSUIntegerMax / height) {
        return nil;
    }
    NSUInteger cost = bytesPerRow * height;
    if (cost == 0 || cost > MTIconOverlayMaximumReadyCost) return nil;

    MTIconOverlayAppliedMetadata *metadata =
        [[MTIconOverlayAppliedMetadata alloc] init];
    metadata.token = imageSet.token;
    metadata.sourceImage = source;
    objc_setAssociatedObject(composed,
        &MTIconOverlayAppliedMetadataAssociationKey, metadata,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MTIconOverlaySourceMetadata *nextSourceMetadata =
        [[MTIconOverlaySourceMetadata alloc] init];
    nextSourceMetadata.token = imageSet.token;
    nextSourceMetadata.composedImage = composed;
    objc_setAssociatedObject(source,
        &MTIconOverlaySourceMetadataAssociationKey, nextSourceMetadata,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.currentImageSet != imageSet) {
        return [self resolveBundleIdentifier:bundleIdentifier
                              candidateImage:source];
    }
    uint64_t evictionsBefore = self.cache.evictionCount;
    (void)[self.cache setObject:composed forKey:cacheKey cost:cost];
    uint64_t evictionsAfter = self.cache.evictionCount;
    if (evictionsAfter > evictionsBefore) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.cacheEvictions,
            evictionsAfter - evictionsBefore, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.compositions,
        1, memory_order_relaxed);
    return composed;
}

- (UIImage *)readyImageForBundleIdentifier:(NSString *)bundleIdentifier
                              candidateImage:(UIImage *)candidate {
    atomic_fetch_add_explicit(
        &MTRuntimeIconOverlaySnapshotObservation.resolutionCalls,
        1, memory_order_relaxed);
    if (candidate == nil || bundleIdentifier.length == 0) return nil;

    MTIconOverlayImageSet *imageSet = self.currentImageSet;
    UIImage *source = candidate;
    BOOL unwrapped = NO;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        MTIconOverlayAppliedMetadata *metadata = objc_getAssociatedObject(
            source, &MTIconOverlayAppliedMetadataAssociationKey);
        if (metadata == nil) break;
        if (imageSet != nil &&
            [metadata.token isEqualToString:imageSet.token]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconOverlaySnapshotObservation.alreadyProcessedHits,
                1, memory_order_relaxed);
            return source;
        }
        if (metadata.sourceImage == nil || metadata.sourceImage == source) {
            return nil;
        }
        source = metadata.sourceImage;
        unwrapped = YES;
    }
    if (imageSet == nil) {
        if (unwrapped) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconOverlaySnapshotObservation.restores,
                1, memory_order_relaxed);
        }
        return source;
    }

    MTIconOverlaySourceMetadata *sourceMetadata = objc_getAssociatedObject(
        source, &MTIconOverlaySourceMetadataAssociationKey);
    UIImage *composed = sourceMetadata.composedImage;
    if ([sourceMetadata.token isEqualToString:imageSet.token] &&
        composed != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return composed;
    }
    return nil;
}

@end

static os_unfair_lock MTIconOverlaySnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTIconOverlaySnapshotModule *MTIconOverlaySnapshotInstance;

BOOL MTIconOverlaySnapshotConfigure(MTRuntimeKernel *kernel,
                                    BOOL systemSurfaceContractsEnabled,
                                    NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTIconOverlaySnapshotLock);
    if (MTIconOverlaySnapshotInstance == nil) {
        MTIconOverlaySnapshotInstance = [[MTIconOverlaySnapshotModule alloc]
            initWithKernel:kernel
            systemSurfaceContractsEnabled:systemSurfaceContractsEnabled];
    }
    BOOL configured = MTIconOverlaySnapshotInstance != nil;
    os_unfair_lock_unlock(&MTIconOverlaySnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeIconOverlaySnapshotObservation.state,
            MTIconOverlaySnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTIconOverlaySnapshotModuleID,
            MTIconOverlaySnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError errorWithDomain:
            @"com.hmmzzz.marktheme.icon-overlay-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"Icon overlay snapshot module could not initialize."
        }];
    }
    return configured;
}

BOOL MTIconOverlaySnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTIconOverlaySnapshotLock);
    BOOL prepared = MTIconOverlaySnapshotInstance != nil;
    os_unfair_lock_unlock(&MTIconOverlaySnapshotLock);
    return prepared;
}

void MTIconOverlaySnapshotReload(void) {
    [MTIconOverlaySnapshotInstance reload];
}

BOOL MTIconOverlaySnapshotIsReadyForGeneration(
    NSString *generationIdentifier) {
    MTIconOverlayImageSet *imageSet =
        MTIconOverlaySnapshotInstance.currentImageSet;
    return generationIdentifier.length > 0 && imageSet != nil &&
        [imageSet.generationIdentifier isEqualToString:generationIdentifier];
}

BOOL MTIconOverlaySnapshotIsEnabled(void) {
    return MTIconOverlaySnapshotInstance.currentImageSet != nil;
}

id MTIconOverlaySnapshotResolve(NSString *bundleIdentifier,
                                id candidateImage) {
    if (![candidateImage isKindOfClass:UIImage.class]) return nil;
    return [MTIconOverlaySnapshotInstance
        resolveBundleIdentifier:bundleIdentifier
        candidateImage:candidateImage];
}

id MTIconOverlaySnapshotResolveSystemSurface(NSString *bundleIdentifier,
                                             id candidateImage,
                                             CGSize pointSize,
                                             CGFloat scale) {
    if (![candidateImage isKindOfClass:UIImage.class] ||
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            pointSize, scale)) {
        return nil;
    }
    UIImage *candidate = candidateImage;
    if (!CGSizeEqualToSize(candidate.size, pointSize) ||
        candidate.scale != scale || candidate.CGImage == NULL) {
        return nil;
    }
    return [MTIconOverlaySnapshotInstance
        resolveBundleIdentifier:bundleIdentifier
        candidateImage:candidate];
}

id MTIconOverlaySnapshotResolveReady(NSString *bundleIdentifier,
                                     id candidateImage) {
    if (![candidateImage isKindOfClass:UIImage.class]) return nil;
    return [MTIconOverlaySnapshotInstance
        readyImageForBundleIdentifier:bundleIdentifier
        candidateImage:candidateImage];
}
