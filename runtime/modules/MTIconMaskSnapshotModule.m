#import "MTIconMaskSnapshotModule.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "MTGenerationReader.h"
#import "MTGenerationDescriptor.h"
#import "MTIconMaskContract.h"
#import "MTIconMaskCompositor.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTStaticIconVisualProofContract.h"
#import "MTSystemIconMaskProvider.h"
#import "MTSpringBoardDecorationSnapshotResolver.h"
#import "MTRuntimeABIReport.h"

NSString *const MTIconMaskSnapshotModuleID = @"icon-mask.snapshot";

static const NSUInteger MTIconMaskMaximumReadyCount = 128;
static const NSUInteger MTIconMaskMaximumReadyCost = 16 * 1024 * 1024;
static const NSUInteger MTIconMaskMaximumContractCount = 8;

typedef NS_ENUM(uint32_t, MTIconMaskPublishedMode) {
    MTIconMaskPublishedModeDisabled = 0,
    MTIconMaskPublishedModeSystem = 1,
    MTIconMaskPublishedModeCustom = 2,
};

static _Atomic(uint32_t) MTIconMaskMode =
    ATOMIC_VAR_INIT(MTIconMaskPublishedModeDisabled);

MTIconMaskSnapshotObservation MTRuntimeIconMaskSnapshotObservation = {
    .schemaVersion = 1,
    .state = ATOMIC_VAR_INIT(MTIconMaskSnapshotModuleStateDormant),
    .reloads = ATOMIC_VAR_INIT(0),
    .maskResourceHits = ATOMIC_VAR_INIT(0),
    .patternResourceHits = ATOMIC_VAR_INIT(0),
    .patternDigestMatches = ATOMIC_VAR_INIT(0),
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

_Static_assert(sizeof(MTIconMaskSnapshotObservation) == 120,
    "The icon-mask ModuleRuntime observation layout must remain fixed.");

@interface MTIconMaskImageSet : NSObject
@property(nonatomic, copy) NSString *generationIdentifier;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, assign) BOOL usesSystemMask;
@property(nonatomic, strong, nullable)
    MTSpringBoardDecorationSnapshotResolution *maskResolution;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, UIImage *> *maskImagesByPixelDimension;
@property(nonatomic, strong, nullable) UIImage *primaryMaskImage;
@end

@implementation MTIconMaskImageSet
@end

static MTIconMaskImageSet *MTIconMaskSystemImageSet(
    NSString *generationIdentifier) {
    if (generationIdentifier.length == 0) return nil;
    MTIconMaskImageSet *imageSet = [[MTIconMaskImageSet alloc] init];
    imageSet.generationIdentifier = generationIdentifier;
    imageSet.token = [NSString stringWithFormat:@"%@|%@",
        generationIdentifier, MTIconMaskVariantSystem];
    imageSet.usesSystemMask = YES;
    return imageSet;
}

@interface MTIconMaskAppliedMetadata : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) UIImage *sourceImage;
@end

@implementation MTIconMaskAppliedMetadata
@end

@interface MTIconMaskSourceMetadata : NSObject
@property(nonatomic, copy) NSString *token;
@property(nonatomic, weak) UIImage *composedImage;
@end

@implementation MTIconMaskSourceMetadata
@end

static char MTIconMaskAppliedMetadataAssociationKey;
static char MTIconMaskSourceMetadataAssociationKey;
static _Atomic(uint32_t) MTIconMaskMayRequireCleanup = ATOMIC_VAR_INIT(0);

static void MTIconMaskBindComposition(UIImage *composed,
                                      UIImage *source,
                                      NSString *token) {
    if (composed == nil || source == nil || token.length == 0) return;
    MTIconMaskAppliedMetadata *metadata =
        [[MTIconMaskAppliedMetadata alloc] init];
    metadata.token = token;
    metadata.sourceImage = source;
    objc_setAssociatedObject(composed,
        &MTIconMaskAppliedMetadataAssociationKey, metadata,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MTIconMaskSourceMetadata *sourceMetadata =
        [[MTIconMaskSourceMetadata alloc] init];
    sourceMetadata.token = token;
    sourceMetadata.composedImage = composed;
    objc_setAssociatedObject(source,
        &MTIconMaskSourceMetadataAssociationKey, sourceMetadata,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_store_explicit(
        &MTIconMaskMayRequireCleanup, 1, memory_order_relaxed);
}

@interface MTIconMaskSnapshotModule : NSObject
@property(nonatomic, weak) MTRuntimeKernel *kernel;
@property(nonatomic, strong)
    MTSpringBoardDecorationSnapshotResolver *resolver;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong) MTRuntimeObjectCache<UIImage *> *cache;
@property(nonatomic, strong) dispatch_source_t memoryPressureSource;
@property(nonatomic, assign) BOOL systemSurfaceContractsEnabled;
@property(atomic, strong, nullable) MTIconMaskImageSet *currentImageSet;
@property(atomic, assign) uint64_t requestedEpoch;
- (instancetype)initWithKernel:(MTRuntimeKernel *)kernel
     systemSurfaceContractsEnabled:(BOOL)systemSurfaceContractsEnabled;
- (void)purgeForMemoryPressure;
- (void)reload;
- (nullable UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                               candidateImage:(nullable UIImage *)candidate
                               systemMaskImage:(nullable UIImage *)systemMask;
- (nullable UIImage *)readyImageForBundleIdentifier:
    (NSString *)bundleIdentifier
                                    candidateImage:(nullable UIImage *)candidate;
@end

@implementation MTIconMaskSnapshotModule

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
        initWithMaximumCount:MTIconMaskMaximumReadyCount
        maximumCost:MTIconMaskMaximumReadyCost];
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
        MTIconMaskSnapshotModule *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf purgeForMemoryPressure];
        atomic_fetch_add_explicit(
            &MTRuntimeIconMaskSnapshotObservation.memoryPressurePurges,
            1, memory_order_relaxed);
    });
    dispatch_resume(_memoryPressureSource);
    return self;
}

- (void)purgeForMemoryPressure {
    [self.cache removeAllObjects];
    MTIconMaskImageSet *imageSet = self.currentImageSet;
    if (imageSet.usesSystemMask || imageSet.primaryMaskImage == nil) return;
    @synchronized (imageSet) {
        [imageSet.maskImagesByPixelDimension removeAllObjects];
        imageSet.maskImagesByPixelDimension[@180] =
            imageSet.primaryMaskImage;
    }
}

- (nullable UIImage *)decodeMaskResolution:
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
            &MTRuntimeIconMaskSnapshotObservation.decodeFailures,
            1, memory_order_relaxed);
        return nil;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.decodeSuccesses,
        1, memory_order_relaxed);
    return image;
}

- (void)publishImageSet:(nullable MTIconMaskImageSet *)imageSet
                   epoch:(uint64_t)epoch
    generationIdentifier:(nullable NSString *)generationIdentifier {
    if (self.requestedEpoch != epoch) return;
    NSString *active = self.kernel.currentSnapshot
        .state.activeGenerationIdentifier;
    if (generationIdentifier != nil &&
        ![active isEqualToString:generationIdentifier]) {
        return;
    }
    // Close the scalar hot-path gate before replacing the retained object.
    // Readers either finish against the previous immutable set or miss this
    // short publication window and are refreshed for the accepted Generation.
    atomic_store_explicit(
        &MTIconMaskMode, MTIconMaskPublishedModeDisabled,
        memory_order_release);
    [self.cache removeAllObjects];
    self.currentImageSet = imageSet;
    MTIconMaskPublishedMode mode = imageSet == nil
        ? MTIconMaskPublishedModeDisabled
        : (imageSet.usesSystemMask
            ? MTIconMaskPublishedModeSystem
            : MTIconMaskPublishedModeCustom);
    atomic_store_explicit(&MTIconMaskMode, mode, memory_order_release);
    atomic_store_explicit(
        &MTRuntimeIconMaskSnapshotObservation.state,
        imageSet == nil ? MTIconMaskSnapshotModuleStateConfigured
                        : MTIconMaskSnapshotModuleStateReady,
        memory_order_release);
    MTRuntimeABIReportRecordModuleState(
        MTIconMaskSnapshotModuleID,
        imageSet == nil ? MTIconMaskSnapshotModuleStateConfigured
                        : MTIconMaskSnapshotModuleStateReady,
        imageSet == nil ? @"Configured" : @"Ready");
}

- (void)reload {
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.reloads,
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
    NSDictionary *configurationDictionary =
        descriptor.moduleConfigurations[MTIconMaskModuleID];
    NSNumber *enabled = [configurationDictionary isKindOfClass:NSDictionary.class]
        ? configurationDictionary[@"enabled"] : nil;
    if (![descriptor.moduleIDs containsObject:MTIconMaskModuleID] ||
        ![enabled isKindOfClass:NSNumber.class] || !enabled.boolValue) {
        MTIconMaskImageSet *systemImageSet = MTIconMaskSystemImageSet(
            generation.generationIdentifier);
        [self publishImageSet:systemImageSet
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }

    NSError *maskError = nil;
    MTSpringBoardDecorationSnapshotResolution *mask = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindIconMask
                     error:&maskError];
    if (mask == nil || maskError != nil) {
        MTIconMaskImageSet *systemImageSet = MTIconMaskSystemImageSet(
            generation.generationIdentifier);
        [self publishImageSet:systemImageSet
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.maskResourceHits,
        1, memory_order_relaxed);

    NSError *patternError = nil;
    MTSpringBoardDecorationSnapshotResolution *pattern = [self.resolver
        resolutionForKind:MTSpringBoardDecorationKindIconPattern
                     error:&patternError];
    if (pattern != nil && patternError == nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMaskSnapshotObservation.patternResourceHits,
            1, memory_order_relaxed);
        if ([pattern.resource.contentSHA256
                isEqualToString:mask.resource.contentSHA256]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.patternDigestMatches,
                1, memory_order_relaxed);
        }
    }

    UIImage *primaryMaskImage = [self decodeMaskResolution:mask
                                           pixelDimension:180];
    if (primaryMaskImage == nil) {
        MTIconMaskImageSet *systemImageSet = MTIconMaskSystemImageSet(
            generation.generationIdentifier);
        [self publishImageSet:systemImageSet
                        epoch:epoch
         generationIdentifier:generation.generationIdentifier];
        return;
    }
    MTIconMaskImageSet *imageSet = [[MTIconMaskImageSet alloc] init];
    imageSet.generationIdentifier = mask.generationIdentifier;
    imageSet.token = [NSString stringWithFormat:@"%@|%@",
        mask.generationIdentifier, mask.resource.contentSHA256];
    imageSet.usesSystemMask = NO;
    imageSet.maskResolution = mask;
    imageSet.maskImagesByPixelDimension = [NSMutableDictionary dictionary];
    imageSet.primaryMaskImage = primaryMaskImage;
    imageSet.maskImagesByPixelDimension[@180] = primaryMaskImage;
    // One device-neutral authored mask is shared by every icon. Secondary
    // raster contracts are derived lazily by maskImageForImageSet: and then
    // retained once, avoiding several verified reads and ImageIO decodes in
    // processes that never render those surfaces.
    [self publishImageSet:imageSet
                    epoch:epoch
     generationIdentifier:mask.generationIdentifier];
}

- (nullable UIImage *)maskImageForImageSet:(MTIconMaskImageSet *)imageSet
                               sourceImage:(UIImage *)source {
    if (imageSet.usesSystemMask || imageSet.maskResolution == nil ||
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
        UIImage *maskImage = imageSet.maskImagesByPixelDimension[key];
        if (maskImage != nil) return maskImage;
        if (imageSet.maskImagesByPixelDimension.count >=
            MTIconMaskMaximumContractCount) {
            return nil;
        }
        maskImage = [self decodeMaskResolution:imageSet.maskResolution
                                pixelDimension:(uint32_t)pixelWidth];
        if (maskImage != nil) {
            imageSet.maskImagesByPixelDimension[key] = maskImage;
        }
        return maskImage;
    }
}

- (nullable UIImage *)resolveBundleIdentifier:(NSString *)bundleIdentifier
                               candidateImage:(nullable UIImage *)candidate
                               systemMaskImage:(nullable UIImage *)systemMask {
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.resolutionCalls,
        1, memory_order_relaxed);
    if (candidate == nil || bundleIdentifier.length == 0) return nil;

    MTIconMaskImageSet *imageSet = self.currentImageSet;
    UIImage *source = candidate;
    BOOL unwrapped = NO;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        MTIconMaskAppliedMetadata *metadata = objc_getAssociatedObject(
            source, &MTIconMaskAppliedMetadataAssociationKey);
        if (metadata == nil) break;
        if (imageSet != nil &&
            [metadata.token isEqualToString:imageSet.token]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.alreadyProcessedHits,
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
                &MTRuntimeIconMaskSnapshotObservation.restores,
                1, memory_order_relaxed);
            return source;
        }
        return nil;
    }

    // Custom-mask composition is fully identified by the immutable image-set
    // token and source object. Return its associated result before boxing the
    // pixel dimension or entering the synchronized decoded-mask dictionary.
    // System masks deliberately retain the original ordering because their
    // live carrier must be present and validated for this call boundary.
    MTIconMaskSourceMetadata *sourceMetadata = nil;
    UIImage *sourceCachedImage = nil;
    if (!imageSet.usesSystemMask) {
        sourceMetadata = objc_getAssociatedObject(
            source, &MTIconMaskSourceMetadataAssociationKey);
        sourceCachedImage = sourceMetadata.composedImage;
        if ([sourceMetadata.token isEqualToString:imageSet.token] &&
            sourceCachedImage != nil) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.cacheHits,
                1, memory_order_relaxed);
            return sourceCachedImage;
        }
    }

    UIImage *maskImage = imageSet.usesSystemMask
        ? systemMask
        : [self maskImageForImageSet:imageSet sourceImage:source];
    if (maskImage == nil ||
        (imageSet.usesSystemMask && source == maskImage)) {
        return nil;
    }

    if (imageSet.usesSystemMask) {
        sourceMetadata = objc_getAssociatedObject(
            source, &MTIconMaskSourceMetadataAssociationKey);
        sourceCachedImage = sourceMetadata.composedImage;
        if ([sourceMetadata.token isEqualToString:imageSet.token] &&
            sourceCachedImage != nil) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.cacheHits,
                1, memory_order_relaxed);
            return sourceCachedImage;
        }
    }

    CGImageRef sourceCGImage = source.CGImage;
    CGImageRef maskCGImage = maskImage.CGImage;
    BOOL sourceContractSupported = self.systemSurfaceContractsEnabled
        ? MTStaticIconSystemSurfaceImageContractIsSupported(
            source.size, source.scale)
        : MTStaticIconVisualProofImageContractIsSupported(
            source.size, source.scale);
    BOOL maskContractSupported = self.systemSurfaceContractsEnabled
        ? MTStaticIconSystemSurfaceImageContractIsSupported(
            maskImage.size, maskImage.scale)
        : MTStaticIconVisualProofImageContractIsSupported(
            maskImage.size, maskImage.scale);
    size_t expectedPixelDimension = sourceCGImage == NULL ? 0 :
        CGImageGetWidth(sourceCGImage);
    if (sourceCGImage == NULL ||
        maskCGImage == NULL ||
        source.imageOrientation != UIImageOrientationUp ||
        maskImage.imageOrientation != UIImageOrientationUp ||
        !sourceContractSupported || !maskContractSupported ||
        !CGSizeEqualToSize(source.size, maskImage.size) ||
        source.scale != maskImage.scale ||
        (imageSet.usesSystemMask &&
         !MTIconMaskHasTransparentCornerPixels(maskCGImage)) ||
        CGImageGetWidth(sourceCGImage) != expectedPixelDimension ||
        CGImageGetHeight(sourceCGImage) != expectedPixelDimension ||
        CGImageGetWidth(maskCGImage) != expectedPixelDimension ||
        CGImageGetHeight(maskCGImage) != expectedPixelDimension) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMaskSnapshotObservation.unsupportedCandidateMisses,
            1, memory_order_relaxed);
        return nil;
    }

    // Native caches may rebuild a UIImage wrapper around the same immutable
    // CGImage. Reuse the composition across those wrappers while retaining
    // scale/orientation in the exact raster contract.
    NSString *cacheKey = [NSString stringWithFormat:
        @"%@|%zux%zu|%.6g|%ld|%p",
        imageSet.token,
        expectedPixelDimension, expectedPixelDimension,
        source.scale, (long)source.imageOrientation,
        (void *)sourceCGImage];
    UIImage *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        MTIconMaskAppliedMetadata *cachedMetadata =
            objc_getAssociatedObject(
                cached, &MTIconMaskAppliedMetadataAssociationKey);
        UIImage *boundResult = cached;
        if (cachedMetadata.sourceImage != source) {
            CGImageRef cachedRaster = cached.CGImage;
            boundResult = cachedRaster == NULL ? nil : [[UIImage alloc]
                initWithCGImage:cachedRaster
                scale:source.scale
                orientation:UIImageOrientationUp];
            MTIconMaskBindComposition(
                boundResult, source, imageSet.token);
        }
        if (boundResult != nil) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.cacheHits,
                1, memory_order_relaxed);
            return boundResult;
        }
    }

    CGImageRef composedCGImage = MTIconMaskCreateImage(
        sourceCGImage, maskCGImage);
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
    if (cost == 0 || cost > MTIconMaskMaximumReadyCost) return nil;

    MTIconMaskBindComposition(composed, source, imageSet.token);
    if (self.currentImageSet != imageSet) {
        return [self resolveBundleIdentifier:bundleIdentifier
                              candidateImage:source
                              systemMaskImage:systemMask];
    }
    uint64_t evictionsBefore = self.cache.evictionCount;
    (void)[self.cache setObject:composed forKey:cacheKey cost:cost];
    uint64_t evictionsAfter = self.cache.evictionCount;
    if (evictionsAfter > evictionsBefore) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMaskSnapshotObservation.cacheEvictions,
            evictionsAfter - evictionsBefore, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.compositions,
        1, memory_order_relaxed);
    return composed;
}

- (UIImage *)readyImageForBundleIdentifier:(NSString *)bundleIdentifier
                              candidateImage:(UIImage *)candidate {
    atomic_fetch_add_explicit(
        &MTRuntimeIconMaskSnapshotObservation.resolutionCalls,
        1, memory_order_relaxed);
    if (candidate == nil || bundleIdentifier.length == 0) return nil;

    MTIconMaskImageSet *imageSet = self.currentImageSet;
    UIImage *source = candidate;
    BOOL unwrapped = NO;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        MTIconMaskAppliedMetadata *metadata = objc_getAssociatedObject(
            source, &MTIconMaskAppliedMetadataAssociationKey);
        if (metadata == nil) break;
        if (imageSet != nil &&
            [metadata.token isEqualToString:imageSet.token]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconMaskSnapshotObservation.alreadyProcessedHits,
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
                &MTRuntimeIconMaskSnapshotObservation.restores,
                1, memory_order_relaxed);
        }
        return source;
    }
    if (imageSet.usesSystemMask) return source;

    MTIconMaskSourceMetadata *sourceMetadata = objc_getAssociatedObject(
        source, &MTIconMaskSourceMetadataAssociationKey);
    UIImage *composed = sourceMetadata.composedImage;
    if ([sourceMetadata.token isEqualToString:imageSet.token] &&
        composed != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconMaskSnapshotObservation.cacheHits,
            1, memory_order_relaxed);
        return composed;
    }
    return nil;
}

@end

static os_unfair_lock MTIconMaskSnapshotLock = OS_UNFAIR_LOCK_INIT;
static MTIconMaskSnapshotModule *MTIconMaskSnapshotInstance;

BOOL MTIconMaskSnapshotConfigure(MTRuntimeKernel *kernel,
                                 BOOL systemSurfaceContractsEnabled,
                                 NSError **error) {
    if (![kernel isKindOfClass:MTRuntimeKernel.class]) return NO;
    os_unfair_lock_lock(&MTIconMaskSnapshotLock);
    if (MTIconMaskSnapshotInstance == nil) {
        MTIconMaskSnapshotInstance = [[MTIconMaskSnapshotModule alloc]
            initWithKernel:kernel
            systemSurfaceContractsEnabled:systemSurfaceContractsEnabled];
    }
    BOOL configured = MTIconMaskSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTIconMaskSnapshotLock);
    if (configured) {
        atomic_store_explicit(
            &MTRuntimeIconMaskSnapshotObservation.state,
            MTIconMaskSnapshotModuleStateConfigured,
            memory_order_release);
        MTRuntimeABIReportRecordModuleState(
            MTIconMaskSnapshotModuleID, MTIconMaskSnapshotModuleStateConfigured, @"Configured");
    } else if (error != NULL) {
        *error = [NSError errorWithDomain:
            @"com.hmmzzz.marktheme.icon-mask-snapshot"
                                     code:1
                                 userInfo:@{
            NSLocalizedDescriptionKey :
                @"Icon mask snapshot module could not initialize."
        }];
    }
    return configured;
}

BOOL MTIconMaskSnapshotPrepare(void) {
    if (![NSThread isMainThread]) return NO;
    os_unfair_lock_lock(&MTIconMaskSnapshotLock);
    BOOL prepared = MTIconMaskSnapshotInstance != nil;
    os_unfair_lock_unlock(&MTIconMaskSnapshotLock);
    return prepared;
}

void MTIconMaskSnapshotReload(void) {
    [MTIconMaskSnapshotInstance reload];
}

BOOL MTIconMaskSnapshotIsReadyForGeneration(
    NSString *generationIdentifier) {
    MTIconMaskImageSet *imageSet =
        MTIconMaskSnapshotInstance.currentImageSet;
    return generationIdentifier.length > 0 && imageSet != nil &&
        [imageSet.generationIdentifier isEqualToString:generationIdentifier];
}

BOOL MTIconMaskSnapshotIsEnabled(void) {
    return atomic_load_explicit(
        &MTIconMaskMode, memory_order_acquire) !=
        MTIconMaskPublishedModeDisabled;
}

BOOL MTIconMaskSnapshotUsesSystemMask(void) {
    return atomic_load_explicit(
        &MTIconMaskMode, memory_order_acquire) ==
        MTIconMaskPublishedModeSystem;
}

static BOOL MTIconMaskSnapshotCandidateRequiresResolution(
    UIImage *candidate) {
    if (atomic_load_explicit(&MTIconMaskMode, memory_order_acquire) !=
        MTIconMaskPublishedModeDisabled) {
        return YES;
    }
    if (!atomic_load_explicit(
            &MTIconMaskMayRequireCleanup, memory_order_relaxed)) {
        return NO;
    }
    return objc_getAssociatedObject(
        candidate, &MTIconMaskAppliedMetadataAssociationKey) != nil;
}

id MTIconMaskSnapshotResolve(NSString *bundleIdentifier,
                             id candidateImage,
                             id systemMaskImage) {
    if (![candidateImage isKindOfClass:UIImage.class] ||
        (systemMaskImage != nil &&
         ![systemMaskImage isKindOfClass:UIImage.class])) {
        return nil;
    }
    if (!MTIconMaskSnapshotCandidateRequiresResolution(candidateImage)) {
        return nil;
    }
    return [MTIconMaskSnapshotInstance
        resolveBundleIdentifier:bundleIdentifier
        candidateImage:candidateImage
        systemMaskImage:systemMaskImage];
}

id MTIconMaskSnapshotResolveSystemSurface(NSString *bundleIdentifier,
                                          id candidateImage,
                                          id systemMaskImage,
                                          CGSize pointSize,
                                          CGFloat scale) {
    if (![candidateImage isKindOfClass:UIImage.class] ||
        !MTStaticIconSystemSurfaceImageContractIsSupported(
            pointSize, scale)) {
        return nil;
    }
    UIImage *candidate = candidateImage;
    if (!MTIconMaskSnapshotCandidateRequiresResolution(candidate)) {
        return nil;
    }
    if (!CGSizeEqualToSize(candidate.size, pointSize) ||
        candidate.scale != scale || candidate.CGImage == NULL) {
        return nil;
    }
    id nativeMask = MTIconMaskSnapshotUsesSystemMask()
        ? MTSystemIconMaskProviderImage(pointSize, scale) : nil;
    UIImage *carrier = [nativeMask isKindOfClass:UIImage.class]
        ? nativeMask : ([systemMaskImage isKindOfClass:UIImage.class]
            ? systemMaskImage : nil);
    if (carrier != nil &&
        (!CGSizeEqualToSize(carrier.size, pointSize) ||
         carrier.scale != scale)) {
        CGImageRef carrierImage = carrier.CGImage;
        size_t expectedPixelDimension =
            (size_t)(pointSize.width * scale);
        if (carrierImage == NULL ||
            CGImageGetWidth(carrierImage) != expectedPixelDimension ||
            CGImageGetHeight(carrierImage) != expectedPixelDimension) {
            carrier = nil;
        } else {
            carrier = [[UIImage alloc]
                initWithCGImage:carrierImage
                scale:scale
                orientation:UIImageOrientationUp];
        }
    }
    return [MTIconMaskSnapshotInstance
        resolveBundleIdentifier:bundleIdentifier
        candidateImage:candidate
        systemMaskImage:carrier];
}

id MTIconMaskSnapshotResolveReady(NSString *bundleIdentifier,
                                  id candidateImage) {
    if (![candidateImage isKindOfClass:UIImage.class]) return nil;
    if (!MTIconMaskSnapshotCandidateRequiresResolution(candidateImage)) {
        return candidateImage;
    }
    return [MTIconMaskSnapshotInstance
        readyImageForBundleIdentifier:bundleIdentifier
        candidateImage:candidateImage];
}
