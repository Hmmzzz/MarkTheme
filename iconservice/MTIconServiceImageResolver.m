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
#import "MTRuntimeSnapshot.h"
#import "modules/MTIconMaskCompositor.h"
#import "modules/MTSpringBoardDecorationSnapshotResolver.h"
#import "modules/MTStaticIconSnapshotResolver.h"

NSString *const MTIconServiceImageResolverErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-image-resolver";

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

@interface MTIconServiceCGImageBox : NSObject
@property(nonatomic, assign, readonly) CGImageRef image;
- (instancetype)initWithImage:(CGImageRef)image;
@end

@implementation MTIconServiceCGImageBox

- (instancetype)initWithImage:(CGImageRef)image {
    if (image == NULL) return nil;
    self = [super init];
    if (self == nil) return nil;
    _image = CGImageRetain(image);
    return self;
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

static CGImageRef MTIconServiceCopySystemMask(CGSize pointSize,
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

@interface MTIconServiceImageResolver ()
@property(nonatomic, copy) MTIconServiceSnapshotProvider snapshotProvider;
@property(nonatomic, strong) MTRuntimePublishedImageLoader *imageLoader;
@property(nonatomic, strong)
    NSCache<NSString *, MTIconServiceCGImageBox *> *cache;
@property(nonatomic, copy, nullable) NSString *sourceFingerprint;
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
    _cache = [[NSCache alloc] init];
    _cache.countLimit = MTIconServiceMaximumCachedImageCount;
    _cache.totalCostLimit = MTIconServiceMaximumCachedImageCost;
    _dynamicCategoryPolicy = dynamicCategoryPolicy;
    return _imageLoader == nil || _cache == nil ? nil : self;
}

- (BOOL)updateSourceFingerprint:(NSString *)sourceFingerprint {
    if (![sourceFingerprint isKindOfClass:NSString.class] ||
        ![sourceFingerprint hasPrefix:@"mtfs1-"] ||
        sourceFingerprint.length != 70) {
        return NO;
    }
    @synchronized (self) {
        if ([self.sourceFingerprint isEqualToString:sourceFingerprint]) {
            return YES;
        }
        [self.cache removeAllObjects];
        self.sourceFingerprint = sourceFingerprint;
    }
    return YES;
}

- (MTRuntimeDecodedImage *)decodeResolution:
    (MTSpringBoardDecorationSnapshotResolution *)resolution
                              pixelWidth:(uint32_t)pixelWidth
                             pixelHeight:(uint32_t)pixelHeight {
    if (resolution == nil) return nil;
    return [self.imageLoader
        loadImageForGeneration:resolution.generation
                      resource:resolution.resource
              targetPixelWidth:pixelWidth
             targetPixelHeight:pixelHeight
                  resizePolicy:
                      MTRuntimePublishedImageResizePolicyBoundedScaleToFill
                         error:NULL];
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
    MTRuntimeSnapshot *snapshot = self.snapshotProvider();
    MTGeneration *generation = snapshot.generation;
    if (!snapshot.isReady || generation == nil) return NULL;
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
    NSString *sourceFingerprint = nil;
    @synchronized (self) {
        sourceFingerprint = self.sourceFingerprint;
    }
    if (sourceFingerprint.length == 0) return NULL;
    NSString *cacheKey = [NSString stringWithFormat:
        @"%@|%@|%ux%u@%.0f|%@", sourceFingerprint,
        bundleIdentifier, pixelWidth, pixelHeight, scale, stockImageDigest];
    MTIconServiceCGImageBox *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) return CGImageRetain(cached.image);

    MTStaticIconSnapshotResolver *staticResolver =
        [[MTStaticIconSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return snapshot;
            }];
    MTSpringBoardDecorationSnapshotResolver *decorationResolver =
        [[MTSpringBoardDecorationSnapshotResolver alloc]
            initWithSnapshotProvider:^MTRuntimeSnapshot *{
                return snapshot;
            }];
    NSArray<MTStaticIconSnapshotResolution *> *staticResolutions =
        preservesDynamicStockSource ? @[] :
        [staticResolver resolutionsForBundleIdentifier:bundleIdentifier
                                                 scale:(NSUInteger)scale
                                           deviceTrait:@"iphone"
                                                 error:NULL];
    MTRuntimeDecodedImage *staticImage = [self
        decodeStaticResolutions:staticResolutions
                    pixelWidth:pixelWidth
                   pixelHeight:pixelHeight];

    MTGenerationDescriptor *descriptor = generation.descriptor;
    NSDictionary *maskConfigurationDictionary =
        descriptor.moduleConfigurations[MTIconMaskModuleID];
    BOOL customMaskEnabled =
        [descriptor.moduleIDs containsObject:MTIconMaskModuleID] &&
        [[MTIconMaskConfiguration alloc]
            initWithDictionary:maskConfigurationDictionary
            error:NULL] != nil;
    MTSpringBoardDecorationSnapshotResolution *maskResolution =
        customMaskEnabled ? [decorationResolver
            resolutionForKind:MTSpringBoardDecorationKindIconMask
            error:NULL] : nil;
    MTRuntimeDecodedImage *customMask = [self
        decodeResolution:maskResolution
             pixelWidth:pixelWidth
            pixelHeight:pixelHeight];
    BOOL usesCustomMask = customMask != nil;

    BOOL overlayEnabled =
        [descriptor.moduleIDs containsObject:MTIconOverlayModuleID];
    MTSpringBoardDecorationSnapshotResolution *overlayResolution =
        overlayEnabled ? [decorationResolver
            resolutionForKind:MTSpringBoardDecorationKindIconOverlay
            error:NULL] : nil;
    MTRuntimeDecodedImage *overlay = [self
        decodeResolution:overlayResolution
             pixelWidth:pixelWidth
            pixelHeight:pixelHeight];

    BOOL changesPixels = staticImage != nil || usesCustomMask || overlay != nil;
    if (!changesPixels) return NULL;
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
            iconPointSize, scale, pixelWidth);
        if (mask == NULL) {
            CGImageRelease(current);
            return NULL;
        }
    }
    if (mask != NULL) {
        CGImageRef masked = MTIconMaskCreateImage(current, mask);
        CGImageRelease(mask);
        CGImageRelease(current);
        if (masked == NULL) return NULL;
        current = masked;
    }
    if (overlay != nil) {
        CGImageRef overlaid = MTIconOverlayCreateImage(
            current, overlay.image);
        if (overlaid != NULL) {
            CGImageRelease(current);
            current = overlaid;
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
    NSUInteger cost = (NSUInteger)pixelWidth * (NSUInteger)pixelHeight * 4;
    if (box != nil && cost <= MTIconServiceMaximumCachedImageCost) {
        [self.cache setObject:box forKey:cacheKey cost:cost];
    }
    return current;
}

@end
