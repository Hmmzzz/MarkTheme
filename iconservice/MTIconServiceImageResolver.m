#import "MTIconServiceImageResolver.h"

#import <dlfcn.h>
#import <objc/runtime.h>

#include <math.h>
#include <string.h>

#import "MTGenerationDescriptor.h"
#import "MTGenerationReader.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconMaskContract.h"
#import "MTIconOverlayContract.h"
#import "MTRuntimePublishedImageLoader.h"
#import "MTRuntimeObjectCache.h"
#import "MTRuntimeSnapshot.h"
#import "modules/MTIconMaskCompositor.h"
#import "modules/MTSpringBoardDecorationSnapshotResolver.h"
#import "modules/MTStaticIconSnapshotResolver.h"

NSString *const MTIconServiceImageResolverErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-image-resolver";

MTIconServiceImageResolverObservation
    MTRuntimeIconServiceImageResolverObservation = {
        .schemaVersion = 2,
};

static const NSUInteger MTIconServiceMaximumCachedImageCount = 256;
static const NSUInteger MTIconServiceMaximumCachedImageCost =
    32 * 1024 * 1024;
static NSString *const MTIconServiceCalendarModuleID = @"icons.calendar";
static NSString *const MTIconServiceCalendarBundleIdentifier =
    @"com.apple.mobilecal";
static NSString *const MTIconServiceClockModuleID = @"icons.clock";
static NSString *const MTIconServiceClockBundleIdentifier =
    @"com.apple.mobiletimer";
static const char *const MTIconServicesPath =
    "/System/Library/PrivateFrameworks/IconServices.framework/IconServices";

typedef id (*MTObjectMethod)(id, SEL);
typedef id (*MTShapeImageMethod)(id, SEL, CGSize, double);
typedef CGImageRef (*MTCGImageMethod)(id, SEL);

// A cached entry carries either a composed replacement or the proven fact that
// this exact request resolves to the stock appearance. Unthemed applications
// are the common case, so recording that outcome keeps them from re-running
// the full resolver and decode path on every icon request.
@interface MTIconServiceCGImageBox : NSObject
@property(nonatomic, assign, readonly) CGImageRef image;
@property(nonatomic, assign, readonly, getter=isStock) BOOL stock;
- (instancetype)initWithImage:(CGImageRef)image;
+ (instancetype)stockBox;
@end

@implementation MTIconServiceCGImageBox

- (instancetype)initWithImage:(CGImageRef)image {
    if (image == NULL) return nil;
    self = [super init];
    if (self == nil) return nil;
    _image = CGImageRetain(image);
    return self;
}

- (instancetype)initStock {
    self = [super init];
    if (self == nil) return nil;
    _stock = YES;
    return self;
}

+ (instancetype)stockBox {
    return [[self alloc] initStock];
}

- (void)dealloc {
    if (_image != NULL) CGImageRelease(_image);
}

@end

static void MTIconServiceResolverSetError(NSError **error,
                                          NSInteger code,
                                          NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTIconServiceImageResolverErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

static BOOL MTIconServiceMethodMatches(Method method,
                                       const char *encoding) {
    if (method == NULL || encoding == NULL) return NO;
    const char *actual = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    Dl_info info = {0};
    return actual != NULL && strcmp(actual, encoding) == 0 &&
        implementation != NULL &&
        dladdr((const void *)implementation, &info) != 0 &&
        info.dli_fname != NULL && strcmp(info.dli_fname, MTIconServicesPath) == 0;
}

static CGImageRef MTIconServiceCopySystemMaskUncached(CGSize pointSize,
                                               double scale,
                                               uint32_t pixelDimension) {
    Class resourceClass = objc_getClass("ISShapeCompositorResource");
    if (resourceClass == Nil) return NULL;
    SEL shapeSelector = sel_registerName("continuousRoundedRectShape");
    Method shapeMethod = class_getClassMethod(resourceClass, shapeSelector);
    if (!MTIconServiceMethodMatches(shapeMethod, "@16@0:8")) return NULL;
    id shape = ((MTObjectMethod)method_getImplementation(shapeMethod))(
        resourceClass, shapeSelector);
    Class shapeClass = shape == nil ? Nil : object_getClass(shape);
    if (shapeClass == Nil ||
        strcmp(class_getName(shapeClass), "ISContinuousRoundedRect") != 0) {
        return NULL;
    }
    SEL imageSelector = sel_registerName("imageForSize:scale:");
    Method imageMethod = class_getInstanceMethod(shapeClass, imageSelector);
    if (!MTIconServiceMethodMatches(
            imageMethod, "@40@0:8{CGSize=dd}16d32")) {
        return NULL;
    }
    id rendered = ((MTShapeImageMethod)method_getImplementation(imageMethod))(
        shape, imageSelector, pointSize, scale);
    if (rendered == nil ||
        strcmp(class_getName(object_getClass(rendered)), "IFConcreteImage") != 0) {
        return NULL;
    }
    SEL CGImageSelector = sel_registerName("CGImage");
    Method CGImageMethod = class_getInstanceMethod(
        object_getClass(rendered), CGImageSelector);
    if (CGImageMethod == NULL ||
        strcmp(method_getTypeEncoding(CGImageMethod),
               "^{CGImage=}16@0:8") != 0) {
        return NULL;
    }
    CGImageRef image = ((MTCGImageMethod)method_getImplementation(
        CGImageMethod))(rendered, CGImageSelector);
    if (image == NULL || CGImageGetWidth(image) != pixelDimension ||
        CGImageGetHeight(image) != pixelDimension ||
        !MTIconMaskHasTransparentCornerPixels(image)) {
        return NULL;
    }
    return CGImageRetain(image);
}

// The system mask is a pure function of its geometry, and validating it costs
// a dladdr image check plus a per-pixel corner scan. Icon geometry comes from
// a small fixed set, so keep proven and rejected geometries in the same bounded
// cache as composites. A hit avoids the ABI checks and pixel scan; eviction
// permits a later bounded retry without retaining masks outside the budget.
static CGImageRef MTIconServiceCopySystemMask(MTRuntimeObjectCache *cache,
                                               CGSize pointSize,
                                               double scale,
                                               uint32_t pixelDimension) {
    NSString *maskKey = [NSString stringWithFormat:@"system-mask|%.4f|%.4f|%.2f|%u",
        pointSize.width, pointSize.height, scale, pixelDimension];
    MTIconServiceCGImageBox *cached = [cache objectForKey:maskKey];
    if (cached != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconServiceImageResolverObservation.systemMaskHits,
            1, memory_order_relaxed);
        return cached.isStock ? NULL : CGImageRetain(cached.image);
    }

    CGImageRef rendered = MTIconServiceCopySystemMaskUncached(
        pointSize, scale, pixelDimension);
    atomic_fetch_add_explicit(
        &MTRuntimeIconServiceImageResolverObservation.systemMaskRenders,
        1, memory_order_relaxed);
    MTIconServiceCGImageBox *box = rendered == NULL
        ? MTIconServiceCGImageBox.stockBox
        : [[MTIconServiceCGImageBox alloc] initWithImage:rendered];
    if (box != nil) {
        NSUInteger cost = rendered == NULL ? 1 :
            CGImageGetBytesPerRow(rendered) * CGImageGetHeight(rendered);
        [cache setObject:box forKey:maskKey cost:MAX(1, cost)];
    }
    return rendered;
}

@interface MTIconServiceGenerationContext : NSObject
@property(nonatomic, strong) MTStaticIconSnapshotResolver *staticResolver;
@property(nonatomic, strong) MTSpringBoardDecorationSnapshotResolver *decorationResolver;
@property(nonatomic, strong) MTIconMaskConfiguration *maskConfiguration;
@property(nonatomic, strong) MTSpringBoardDecorationSnapshotResolution *maskResolution;
@property(nonatomic, strong) MTSpringBoardDecorationSnapshotResolution *overlayResolution;
@end
@implementation MTIconServiceGenerationContext
@end

@interface MTIconServiceImageResolver ()
@property(nonatomic, copy) MTIconServiceSnapshotProvider snapshotProvider;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    NSCache<NSString *, MTIconServiceGenerationContext *> *generationContexts;
// All retained rasters, including decoded shared artwork and system masks,
// compete for the same exact 32 MiB / 256-entry LRU budget.
@property(nonatomic, strong) MTRuntimeObjectCache *cache;
@property(nonatomic, assign)
    MTIconServiceDynamicCategoryPolicy dynamicCategoryPolicy;
@end

@implementation MTIconServiceImageResolver

- (instancetype)initWithSnapshotProvider:
    (MTIconServiceSnapshotProvider)snapshotProvider {
    return [self initWithSnapshotProvider:snapshotProvider
                    dynamicCategoryPolicy:
                        MTIconServiceDynamicCategoryPolicyExclude];
}

- (instancetype)initWithSnapshotProvider:
    (MTIconServiceSnapshotProvider)snapshotProvider
                dynamicCategoryPolicy:
                    (MTIconServiceDynamicCategoryPolicy)dynamicCategoryPolicy {
    if (snapshotProvider == nil) return nil;
    if (dynamicCategoryPolicy !=
            MTIconServiceDynamicCategoryPolicyExclude &&
        dynamicCategoryPolicy !=
            MTIconServiceDynamicCategoryPolicyPreserveStockSource) {
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _snapshotProvider = [snapshotProvider copy];
    _imageLoader = MTRuntimePublishedImageLoader.staticIconLoader;
    _generationContexts = [[NSCache alloc] init];
    _generationContexts.countLimit = 2;
    _cache = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:MTIconServiceMaximumCachedImageCount
        maximumCost:MTIconServiceMaximumCachedImageCost];
    _dynamicCategoryPolicy = dynamicCategoryPolicy;
    return _imageLoader == nil || _generationContexts == nil ||
        _cache == nil ? nil : self;
}

- (MTIconServiceGenerationContext *)contextForSnapshot:
        (MTRuntimeSnapshot *)snapshot
                                            generationIdentifier:
        (NSString *)generationIdentifier {
    MTIconServiceGenerationContext *context = [self.generationContexts
        objectForKey:generationIdentifier];
    if (context != nil) return context;
    context = [[MTIconServiceGenerationContext alloc] init];
    context.staticResolver = [[MTStaticIconSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{
            return snapshot;
        }];
    context.decorationResolver = [[MTSpringBoardDecorationSnapshotResolver alloc]
        initWithSnapshotProvider:^MTRuntimeSnapshot *{ return snapshot; }];
    MTGenerationDescriptor *descriptor = snapshot.generation.descriptor;
    if ([descriptor.moduleIDs containsObject:MTIconMaskModuleID]) {
        context.maskConfiguration = [[MTIconMaskConfiguration alloc]
            initWithDictionary:descriptor.moduleConfigurations[MTIconMaskModuleID]
            error:NULL];
        if (context.maskConfiguration != nil) {
            context.maskResolution = [context.decorationResolver
                resolutionForKind:MTSpringBoardDecorationKindIconMask error:NULL];
        }
    }
    if ([descriptor.moduleIDs containsObject:MTIconOverlayModuleID]) {
        context.overlayResolution = [context.decorationResolver
            resolutionForKind:MTSpringBoardDecorationKindIconOverlay error:NULL];
    }
    [self.generationContexts setObject:context forKey:generationIdentifier];
    return context;
}

- (BOOL)storeBox:(MTIconServiceCGImageBox *)box
          forKey:(NSString *)cacheKey
            cost:(NSUInteger)cost {
    if (box == nil || cacheKey.length == 0 || cost == 0) return NO;
    return [self.cache setObject:box forKey:cacheKey cost:cost];
}

- (MTRuntimeDecodedImage *)decodeResolution:
    (MTSpringBoardDecorationSnapshotResolution *)resolution
                              pixelWidth:(uint32_t)pixelWidth
                             pixelHeight:(uint32_t)pixelHeight
                            resizePolicy:
    (MTRuntimePublishedImageResizePolicy)resizePolicy {
    if (resolution == nil) return nil;
    NSString *key = [NSString stringWithFormat:@"decoration|%@|%@|%ux%u|%lu",
        resolution.generationIdentifier, resolution.resource.contentSHA256,
        pixelWidth, pixelHeight, (unsigned long)resizePolicy];
    MTRuntimeDecodedImage *cached = [self.cache objectForKey:key];
    if (cached != nil) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconServiceImageResolverObservation.decorationDecodeHits,
            1, memory_order_relaxed);
        return cached;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconServiceImageResolverObservation.decorationDecodes,
        1, memory_order_relaxed);
    MTRuntimeDecodedImage *decoded = [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
                  targetPixelWidth:pixelWidth
                 targetPixelHeight:pixelHeight
                      resizePolicy:resizePolicy
                         error:NULL];
    if (decoded != nil) {
        [self.cache setObject:decoded forKey:key cost:decoded.residentCost];
    }
    return decoded;
}

- (MTRuntimeDecodedImage *)decodeStaticResolutions:
    (NSArray<MTStaticIconSnapshotResolution *> *)resolutions
                                      pixelWidth:(uint32_t)pixelWidth
                                     pixelHeight:(uint32_t)pixelHeight {
    for (MTStaticIconSnapshotResolution *resolution in resolutions) {
        MTRuntimeDecodedImage *decoded = [self.imageLoader
            loadImageForGeneration:resolution.generation
                          resource:resolution.resource
                  targetPixelWidth:pixelWidth
                 targetPixelHeight:pixelHeight
                      resizePolicy:
                          MTRuntimePublishedImageResizePolicyBoundedScaleToFill
                             error:NULL];
        if (decoded != nil) return decoded;
    }
    return nil;
}

- (CGImageRef)copyReplacementForBundleIdentifier:
    (NSString *)bundleIdentifier
                                         pointSize:(CGSize)pointSize
                                             scale:(double)scale
                                        pixelWidth:(uint32_t)pixelWidth
                                       pixelHeight:(uint32_t)pixelHeight
                                   stockImageDigest:(NSString *)stockImageDigest
                                      stockCGImage:(CGImageRef)stockCGImage
                                             error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (bundleIdentifier.length == 0 || stockImageDigest.length == 0 ||
        stockCGImage == NULL || pixelWidth == 0 || pixelHeight == 0 ||
        pixelWidth != pixelHeight || pixelWidth > 1200 ||
        CGImageGetWidth(stockCGImage) != pixelWidth ||
        CGImageGetHeight(stockCGImage) != pixelHeight ||
        !isfinite(pointSize.width) || pointSize.width <= 0 ||
        pointSize.width != pointSize.height || !isfinite(scale) ||
        scale < 1 || scale > 3 || floor(scale) != scale) {
        MTIconServiceResolverSetError(error, 1,
            @"Icon service replacement request has invalid geometry.");
        return NULL;
    }
    atomic_fetch_add_explicit(
        &MTRuntimeIconServiceImageResolverObservation.lookupCalls,
        1, memory_order_relaxed);
    // One immutable snapshot supplies both bytes and cache namespace. A live
    // reload may overlap this request, but the result remains under the old
    // Generation ID and can never be served to the new snapshot.
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    NSString *generationIdentifier = generation.generationIdentifier;
    if (!snapshot.isReady || generation == nil ||
        generationIdentifier.length == 0) return NULL;
    // Calendar and Clock are live icon categories, not ordinary cached
    // application artwork. The persistent service source excludes them so it
    // cannot freeze date/hand content. A bounded secondary semantic cache may
    // preserve Apple's already-dynamic stock source and apply only MarkTheme's
    // global mask/overlay; it still never substitutes static artwork here.
    NSArray<NSString *> *moduleIDs = generation.descriptor.moduleIDs;
    BOOL dynamicCalendar =
        [bundleIdentifier
            isEqualToString:MTIconServiceCalendarBundleIdentifier] &&
        [moduleIDs containsObject:MTIconServiceCalendarModuleID];
    BOOL dynamicClock =
        [bundleIdentifier
            isEqualToString:MTIconServiceClockBundleIdentifier] &&
        [moduleIDs containsObject:MTIconServiceClockModuleID];
    BOOL preservesDynamicStockSource =
        (dynamicCalendar || dynamicClock) &&
        self.dynamicCategoryPolicy ==
            MTIconServiceDynamicCategoryPolicyPreserveStockSource;
    if ((dynamicCalendar || dynamicClock) &&
        !preservesDynamicStockSource) {
        return NULL;
    }
    NSString *cacheKey = [NSString stringWithFormat:
        @"%@|%@|%ux%u@%.0f|%@", generationIdentifier,
        bundleIdentifier, pixelWidth, pixelHeight, scale, stockImageDigest];
    MTIconServiceCGImageBox *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        if (cached.isStock) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconServiceImageResolverObservation.stockHits,
                1, memory_order_relaxed);
            return NULL;
        }
        atomic_fetch_add_explicit(
            &MTRuntimeIconServiceImageResolverObservation.compositeHits,
            1, memory_order_relaxed);
        return CGImageRetain(cached.image);
    }

    MTIconServiceGenerationContext *context = [self
        contextForSnapshot:snapshot generationIdentifier:generationIdentifier];
    NSArray<MTStaticIconSnapshotResolution *> *staticResolutions =
        preservesDynamicStockSource ? @[] :
        [context.staticResolver resolutionsForBundleIdentifier:bundleIdentifier
                                                 scale:(NSUInteger)scale
                                           deviceTrait:@"iphone"
                                                 error:NULL];
    MTRuntimeDecodedImage *staticImage = [self
        decodeStaticResolutions:staticResolutions
                    pixelWidth:pixelWidth
                   pixelHeight:pixelHeight];

    MTSpringBoardDecorationSnapshotResolution *maskResolution =
        context.maskResolution;
    MTRuntimeDecodedImage *customMask = [self
        decodeResolution:maskResolution
             pixelWidth:pixelWidth
            pixelHeight:pixelHeight
           resizePolicy:
               MTRuntimePublishedImageResizePolicyBoundedScaleToFill];
    BOOL usesCustomMask = customMask != nil;
    MTSpringBoardDecorationSnapshotResolution *overlayResolution =
        context.overlayResolution;
    MTRuntimeDecodedImage *overlay = [self
        decodeResolution:overlayResolution
             pixelWidth:pixelWidth
            pixelHeight:pixelHeight
           resizePolicy:
               MTRuntimePublishedImageResizePolicyBoundedScaleToFill];

    // No Generation data touches this request, so the stock appearance is the
    // correct and stable answer for this content-addressed Generation.
    // Record it so unthemed applications stop re-running the resolver. Later
    // composition failures stay uncached: those are ABI or raster faults that
    // must be retried, not proven stock outcomes.
    BOOL changesPixels = staticImage != nil || usesCustomMask || overlay != nil;
    if (!changesPixels) {
        if ([self storeBox:MTIconServiceCGImageBox.stockBox
                    forKey:cacheKey
                      cost:1]) {
            atomic_fetch_add_explicit(
                &MTRuntimeIconServiceImageResolverObservation.stockStores,
                1, memory_order_relaxed);
        }
        return NULL;
    }
    CGImageRef current = staticImage == nil
        ? CGImageRetain(stockCGImage)
        : CGImageRetain(staticImage.image);
    if (current == NULL) return NULL;

    CGImageRef mask = NULL;
    if (usesCustomMask) {
        mask = CGImageRetain(customMask.image);
    } else if (staticImage != nil) {
        CGSize iconPointSize = CGSizeMake(
            (double)pixelWidth / scale, (double)pixelHeight / scale);
        mask = MTIconServiceCopySystemMask(
            self.cache, iconPointSize, scale, pixelWidth);
        if (mask == NULL) {
            CGImageRelease(current);
            return NULL;
        }
    }
    if (mask != NULL || overlay != nil) {
        CGImageRef composed = MTIconCompositeCreateImage(
            current, mask, overlay.image);
        // Preserve the previous fail-closed mask rule and best-effort overlay
        // rule when an allocation/overlay contract fails.
        if (composed == NULL && overlay != nil && mask != NULL) {
            composed = MTIconCompositeCreateImage(current, mask, NULL);
        }
        BOOL maskRequired = mask != NULL;
        if (maskRequired) CGImageRelease(mask);
        if (composed != NULL) {
            CGImageRelease(current);
            current = composed;
        } else if (maskRequired) {
            CGImageRelease(current);
            return NULL;
        }
    }
    if (CGImageGetWidth(current) != pixelWidth ||
        CGImageGetHeight(current) != pixelHeight) {
        CGImageRelease(current);
        MTIconServiceResolverSetError(error, 2,
            @"Icon service composition changed the raster contract.");
        return NULL;
    }
    MTIconServiceCGImageBox *box =
        [[MTIconServiceCGImageBox alloc] initWithImage:current];
    NSUInteger cost = CGImageGetBytesPerRow(current) * CGImageGetHeight(current);
    if (cost <= MTIconServiceMaximumCachedImageCost &&
        [self storeBox:box forKey:cacheKey cost:cost]) {
        atomic_fetch_add_explicit(
            &MTRuntimeIconServiceImageResolverObservation.compositeStores,
            1, memory_order_relaxed);
    }
    return current;
}

@end
