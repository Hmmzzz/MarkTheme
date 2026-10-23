#import "MTPreferencesGraphicIconRenderer.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <math.h>
#include <string.h>

#import "MTUIResourceSnapshotModule.h"
#import "MTRuntimeABIReport.h"
#import "adapters/MTPreferencesGraphicIconContract.h"
#import "adapters/MTRuntimeImageABI.h"

static NSString *const MTAdapterID = @"preferences.graphic-icon-image";
static const char *const MTFoundationPath =
    "/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation";
static const char *const MTServicesPath =
    "/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static Class MTImageClass;
static Class MTCacheImageClass;
static Class MTDescriptorClass;
static Method MTImageInitializer;
static char MTReplacementMarker;

typedef double (*MTScaleGetter)(id, SEL);
typedef CGSize (*MTSizeGetter)(id, SEL);
typedef BOOL (*MTBoolGetter)(id, SEL);
typedef void (*MTBoolSetter)(id, SEL, BOOL);
typedef CGImageRef (*MTCGImageGetter)(id, SEL);
typedef id (*MTImageInitializerFunction)(
    __attribute__((ns_consumed)) id, SEL, CGImageRef, double, CGSize, BOOL, CGSize)
    __attribute__((ns_returns_retained));

typedef struct MTGraphicImageGeometry {
    CGSize pixelSize;
    CGSize minimumSize;
    CGSize iconSize;
    double scale;
    BOOL largest;
} MTGraphicImageGeometry;

static Method MTImageMethod(Class cls, const char *name,
                             const char *encoding, const char *path) {
    if (!MTRuntimeClassMatchesImagePath(cls, path)) return NULL;
    Method method = class_getInstanceMethod(cls, sel_registerName(name));
    const char *actual = method == NULL ? NULL : method_getTypeEncoding(method);
    return actual != NULL && strcmp(actual, encoding) == 0 &&
        MTRuntimeImplementationResolves(method_getImplementation(method))
        ? method : NULL;
}

static BOOL MTImageGeometry(id image, MTGraphicImageGeometry *geometry) {
    Class cls = object_getClass(image);
    Method scale = MTImageMethod(cls, "scale", "d16@0:8", MTFoundationPath);
    Method pixels = MTImageMethod(cls, "pixelSize", "{CGSize=dd}16@0:8",
        MTFoundationPath);
    Method minimum = MTImageMethod(cls, "minimumSize", "{CGSize=dd}16@0:8",
        MTFoundationPath);
    Method icon = MTImageMethod(cls, "iconSize", "{CGSize=dd}16@0:8",
        MTFoundationPath);
    Method largest = MTImageMethod(cls, "largest", "B16@0:8", MTFoundationPath);
    if (scale == NULL || pixels == NULL || minimum == NULL || icon == NULL ||
        largest == NULL) return NO;
    geometry->scale = ((MTScaleGetter)method_getImplementation(scale))(
        image, method_getName(scale));
    geometry->pixelSize = ((MTSizeGetter)method_getImplementation(pixels))(
        image, method_getName(pixels));
    geometry->minimumSize = ((MTSizeGetter)method_getImplementation(minimum))(
        image, method_getName(minimum));
    geometry->iconSize = ((MTSizeGetter)method_getImplementation(icon))(
        image, method_getName(icon));
    geometry->largest = ((MTBoolGetter)method_getImplementation(largest))(
        image, method_getName(largest));
    double scaleValue = geometry->scale;
    CGSize pixelSize = geometry->pixelSize;
    CGSize minimumSize = geometry->minimumSize;
    CGSize iconSize = geometry->iconSize;
    return isfinite(scaleValue) && scaleValue >= 1 && scaleValue <= 3 &&
        floor(scaleValue) == scaleValue &&
        isfinite(pixelSize.width) && isfinite(pixelSize.height) &&
        pixelSize.width >= 1 && pixelSize.height >= 1 &&
        pixelSize.width <= 4096 && pixelSize.height <= 4096 &&
        floor(pixelSize.width) == pixelSize.width &&
        floor(pixelSize.height) == pixelSize.height &&
        isfinite(minimumSize.width) && isfinite(minimumSize.height) &&
        minimumSize.width >= 0 && minimumSize.height >= 0 &&
        isfinite(iconSize.width) && isfinite(iconSize.height) &&
        iconSize.width >= minimumSize.width &&
        iconSize.height >= minimumSize.height &&
        fabs(iconSize.width * scaleValue - pixelSize.width) < 0.001 &&
        fabs(iconSize.height * scaleValue - pixelSize.height) < 0.001;
}

BOOL MTPreferencesGraphicIconRendererPrepare(void) {
    Class imageClass = objc_getClass("IFImage");
    Class cacheImageClass = objc_getClass("IFCacheImage");
    Class descriptorClass = objc_getClass("ISImageDescriptor");
    const char *initializerName =
        "initWithCGImage:scale:minimumSize:placeholder:iconSize:";
    const char *initializerEncoding =
        "@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52";
    Method initializer = MTImageMethod(cacheImageClass, initializerName,
        initializerEncoding, MTFoundationPath);
    Method cgImage = MTImageMethod(imageClass, "cgImage",
        "^{CGImage=}16@0:8", MTFoundationPath);
    Method placeholder = MTImageMethod(imageClass, "placeholder",
        "B16@0:8", MTFoundationPath);
    Method scale = MTImageMethod(descriptorClass, "scale", "d16@0:8", MTServicesPath);
    MTRuntimeABIReportProbeMethodType(MTAdapterID,
        @"IFCacheImage.initWithCGImage:scale:minimumSize:placeholder:iconSize:",
        initializer, initializerEncoding);
    MTRuntimeABIReportProbeMethodType(MTAdapterID, @"IFImage.cgImage",
        cgImage, "^{CGImage=}16@0:8");
    MTRuntimeABIReportProbeMethodType(MTAdapterID, @"IFImage.placeholder",
        placeholder, "B16@0:8");
    MTRuntimeABIReportProbeMethodType(MTAdapterID, @"ISImageDescriptor.scale",
        scale, "d16@0:8");
    if (![cacheImageClass isSubclassOfClass:imageClass] ||
        initializer == NULL || cgImage == NULL || placeholder == NULL ||
        scale == NULL || !MTUIResourceSnapshotPrepare()) return NO;
    MTImageClass = imageClass;
    MTCacheImageClass = cacheImageClass;
    MTDescriptorClass = descriptorClass;
    MTImageInitializer = initializer;
    return YES;
}

id MTPreferencesGraphicIconRendererResolve(
    NSString *type, id originalImage, id descriptor) {
    if (!MTPreferencesGraphicIconTypeIsSupported(type) || MTImageClass == Nil ||
        ![originalImage isKindOfClass:MTImageClass] ||
        object_getClass(descriptor) != MTDescriptorClass ||
        objc_getAssociatedObject(originalImage, &MTReplacementMarker) != nil) {
        return nil;
    }
    Method cgImageMethod = MTImageMethod(object_getClass(originalImage),
        "cgImage", "^{CGImage=}16@0:8", MTFoundationPath);
    Method placeholderMethod = MTImageMethod(object_getClass(originalImage),
        "placeholder", "B16@0:8", MTFoundationPath);
    Method scaleMethod = MTImageMethod(MTDescriptorClass,
        "scale", "d16@0:8", MTServicesPath);
    if (cgImageMethod == NULL || placeholderMethod == NULL || scaleMethod == NULL ||
        ((MTBoolGetter)method_getImplementation(placeholderMethod))(
            originalImage, method_getName(placeholderMethod))) return nil;
    double scale = ((MTScaleGetter)method_getImplementation(scaleMethod))(
        descriptor, method_getName(scaleMethod));
    MTGraphicImageGeometry geometry = {0};
    if (!MTImageGeometry(originalImage, &geometry) ||
        !isfinite(scale) || scale != geometry.scale) return nil;
    CGImageRef pixels = ((MTCGImageGetter)method_getImplementation(cgImageMethod))(
        originalImage, method_getName(cgImageMethod));
    if (pixels == NULL) return nil;
    size_t width = CGImageGetWidth(pixels);
    size_t height = CGImageGetHeight(pixels);
    if (width != geometry.pixelSize.width ||
        height != geometry.pixelSize.height) return nil;
    UIImage *original = [[UIImage imageWithCGImage:pixels scale:scale
        orientation:UIImageOrientationUp]
        imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    id result = MTUIResourceSnapshotResolve(type, original);
    if (![result isKindOfClass:UIImage.class]) return nil;
    UIImage *replacement = result;
    CGImageRef replacementPixels = replacement.CGImage;
    if (replacementPixels == NULL || replacement.scale != scale ||
        CGImageGetWidth(replacementPixels) != width ||
        CGImageGetHeight(replacementPixels) != height) return nil;
    id image = ((MTImageInitializerFunction)method_getImplementation(MTImageInitializer))(
        [MTCacheImageClass alloc], method_getName(MTImageInitializer),
        replacementPixels, scale, geometry.minimumSize, NO, geometry.iconSize);
    Method largestSetter = MTImageMethod(object_getClass(image), "setLargest:",
        "v20@0:8B16", MTFoundationPath);
    if (image == nil || largestSetter == NULL) return nil;
    ((MTBoolSetter)method_getImplementation(largestSetter))(
        image, method_getName(largestSetter), geometry.largest);
    MTGraphicImageGeometry createdGeometry = {0};
    if (!MTImageGeometry(image, &createdGeometry) ||
        createdGeometry.scale != geometry.scale ||
        !CGSizeEqualToSize(createdGeometry.pixelSize, geometry.pixelSize) ||
        !CGSizeEqualToSize(createdGeometry.minimumSize, geometry.minimumSize) ||
        !CGSizeEqualToSize(createdGeometry.iconSize, geometry.iconSize) ||
        createdGeometry.largest != geometry.largest) return nil;
    if (image != nil) {
        // Sync imageForDescriptor: can be used by the original asynchronous
        // method. Tag only our new client image, never Apple's source/cache.
        objc_setAssociatedObject(image, &MTReplacementMarker, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return image;
}
