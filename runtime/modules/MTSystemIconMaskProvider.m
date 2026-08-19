#import "MTSystemIconMaskProvider.h"

#import <dispatch/dispatch.h>
#import <objc/runtime.h>

#if !MT_HOST_TESTING
#import <UIKit/UIKit.h>
#endif

#import "adapters/MTRuntimeImageABI.h"
#import "MTStaticIconVisualProofContract.h"

#include <string.h>

NSString *const MTSystemIconMaskProviderExpectedImageUUID =
    @"8B774C6D-D367-30BA-B31B-6F7A7344EDFD";

static const NSUInteger MTSystemIconMaskMaximumContractCount = 8;
static const char *const MTIconServicesImagePath =
    "/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static const uint8_t MTIconServicesExpectedImageUUIDBytes[16] = {
    0x8b, 0x77, 0x4c, 0x6d, 0xd3, 0x67, 0x30, 0xba,
    0xb3, 0x1b, 0x6f, 0x7a, 0x73, 0x44, 0xed, 0xfd,
};
static const char *const MTShapeResourceClassName =
    "ISShapeCompositorResource";
static const char *const MTContinuousShapeClassName =
    "ISContinuousRoundedRect";
static const char *const MTShapeSelectorName =
    "continuousRoundedRectShape";
static const char *const MTShapeSelectorTypeEncoding = "@16@0:8";
static const char *const MTImageSelectorName = "imageForSize:scale:";
static const char *const MTImageSelectorTypeEncoding =
    "@40@0:8{CGSize=dd}16d32";
#if !MT_HOST_TESTING
static const char *const MTConcreteImageClassName = "IFConcreteImage";
static const char *const MTCGImageSelectorName = "CGImage";
static const char *const MTCGImageSelectorTypeEncoding =
    "^{CGImage=}16@0:8";
#endif

typedef id (*MTShapeResourceFunction)(id, SEL);
typedef id (*MTShapeImageFunction)(id, SEL, CGSize, double);
#if !MT_HOST_TESTING
typedef CGImageRef (*MTCGImageFunction)(id, SEL);
#endif

static BOOL MTSystemIconMaskMethodMatches(Method method,
                                          const char *typeEncoding) {
    if (method == NULL || typeEncoding == NULL) return NO;
    const char *actual = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    return actual != NULL && strcmp(actual, typeEncoding) == 0 &&
        MTRuntimeImplementationMatchesImage(
            implementation, MTIconServicesImagePath,
            MTIconServicesExpectedImageUUIDBytes);
}

static id MTSystemIconMaskRender(CGSize pointSize, CGFloat scale) {
    // This function is reached only from a real, original-first icon request.
    // objc_getClass is intentionally allowed to miss: the provider never
    // loads IconServices and therefore cannot extend bootstrap loading.
    Class resourceClass = objc_getClass(MTShapeResourceClassName);
    if (!MTRuntimeClassMatchesImagePath(
            resourceClass, MTIconServicesImagePath)) {
        return nil;
    }
    SEL shapeSelector = sel_registerName(MTShapeSelectorName);
    Method shapeMethod = class_getClassMethod(
        resourceClass, shapeSelector);
    if (!MTSystemIconMaskMethodMatches(
            shapeMethod, MTShapeSelectorTypeEncoding)) {
        return nil;
    }
    id shape = ((MTShapeResourceFunction)method_getImplementation(
        shapeMethod))(resourceClass, shapeSelector);
    Class shapeClass = shape == nil ? Nil : object_getClass(shape);
    if (shapeClass == Nil ||
        strcmp(class_getName(shapeClass), MTContinuousShapeClassName) != 0 ||
        !MTRuntimeClassMatchesImagePath(
            shapeClass, MTIconServicesImagePath)) {
        return nil;
    }
    SEL imageSelector = sel_registerName(MTImageSelectorName);
    // Resolve the actual ISContinuousRoundedRect override. Its abstract base
    // implementation is not a valid renderer.
    Method imageMethod = class_getInstanceMethod(
        shapeClass, imageSelector);
    if (!MTSystemIconMaskMethodMatches(
            imageMethod, MTImageSelectorTypeEncoding)) {
        return nil;
    }
    return ((MTShapeImageFunction)method_getImplementation(imageMethod))(
        shape, imageSelector, pointSize, (double)scale);
}

#if !MT_HOST_TESTING
static UIImage *MTSystemIconMaskUIKitImage(id rendered,
                                           CGSize pointSize,
                                           CGFloat scale) {
    Class renderedClass = rendered == nil ? Nil : object_getClass(rendered);
    if (renderedClass == Nil ||
        strcmp(class_getName(renderedClass), MTConcreteImageClassName) != 0) {
        return nil;
    }
    SEL cgImageSelector = sel_registerName(MTCGImageSelectorName);
    Method cgImageMethod = class_getInstanceMethod(
        renderedClass, cgImageSelector);
    const char *actual = cgImageMethod == NULL ? NULL :
        method_getTypeEncoding(cgImageMethod);
    if (actual == NULL ||
        strcmp(actual, MTCGImageSelectorTypeEncoding) != 0) {
        return nil;
    }
    CGImageRef image = ((MTCGImageFunction)method_getImplementation(
        cgImageMethod))(rendered, cgImageSelector);
    size_t expectedPixelDimension =
        (size_t)(pointSize.width * scale);
    if (image == NULL ||
        CGImageGetWidth(image) != expectedPixelDimension ||
        CGImageGetHeight(image) != expectedPixelDimension) {
        return nil;
    }
    return [[UIImage alloc]
        initWithCGImage:image
        scale:scale
        orientation:UIImageOrientationUp];
}
#endif

typedef id _Nullable (^MTSystemIconMaskRenderer)(
    CGSize pointSize,
    CGFloat scale);

@interface MTSystemIconMaskProvider : NSObject
@property(nonatomic, copy) MTSystemIconMaskRenderer renderer;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, id> *imagesByPixelDimension;
- (instancetype)initWithRenderer:(MTSystemIconMaskRenderer)renderer;
- (nullable id)imageForPointSize:(CGSize)pointSize scale:(CGFloat)scale;
@end

@implementation MTSystemIconMaskProvider

- (instancetype)initWithRenderer:(MTSystemIconMaskRenderer)renderer {
    self = [super init];
    if (self == nil || renderer == nil) return nil;
    _renderer = [renderer copy];
    _imagesByPixelDimension = [NSMutableDictionary dictionary];
    return self;
}

- (nullable id)imageForPointSize:(CGSize)pointSize scale:(CGFloat)scale {
    if (!MTStaticIconSystemSurfaceImageContractIsSupported(
            pointSize, scale)) {
        return nil;
    }
    NSNumber *key = @((NSUInteger)(pointSize.width * scale));
    @synchronized (self) {
        id cached = self.imagesByPixelDimension[key];
        if (cached != nil) return cached;
        if (self.imagesByPixelDimension.count >=
            MTSystemIconMaskMaximumContractCount) {
            return nil;
        }
        id rendered = self.renderer(pointSize, scale);
        if (rendered != nil) {
            self.imagesByPixelDimension[key] = rendered;
        }
        return rendered;
    }
}

@end

id MTSystemIconMaskProviderImage(CGSize pointSize, CGFloat scale) {
    static MTSystemIconMaskProvider *provider;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[MTSystemIconMaskProvider alloc]
            initWithRenderer:^id(CGSize requestedPointSize,
                                 CGFloat requestedScale) {
                id rendered = MTSystemIconMaskRender(
                    requestedPointSize, requestedScale);
#if MT_HOST_TESTING
                return rendered;
#else
                return MTSystemIconMaskUIKitImage(
                    rendered, requestedPointSize, requestedScale);
#endif
            }];
    });
    return [provider imageForPointSize:pointSize scale:scale];
}

#if MT_HOST_TESTING
id MTSystemIconMaskProviderCreateForTesting(
    MTSystemIconMaskTestRenderer renderer) {
    return [[MTSystemIconMaskProvider alloc] initWithRenderer:renderer];
}

id MTSystemIconMaskProviderImageForTesting(id provider,
                                           CGSize pointSize,
                                           CGFloat scale) {
    if (![provider isKindOfClass:MTSystemIconMaskProvider.class]) return nil;
    return [(MTSystemIconMaskProvider *)provider
        imageForPointSize:pointSize scale:scale];
}
#endif
