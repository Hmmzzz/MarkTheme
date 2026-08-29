#import "MTIconServiceABI.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>

#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import "MTStaticIconConfiguration.h"

NSString *const MTIconServiceABIErrorDomain =
    @"com.hmmzzz.marktheme.icon-service-abi";

static NSString *const MTIconServiceExpectedExecutablePath =
    @"/System/Library/CoreServices/iconservicesagent";
static NSString *const MTIconServiceExpectedServiceName =
    @"com.apple.iconservices.iconservicesagent";
static NSString *const MTIconServiceExpectedIconServicesPath =
    @"/System/Library/PrivateFrameworks/IconServices.framework/IconServices";
static NSString *const MTIconServiceExpectedIconServicesUUID =
    @"8B774C6D-D367-30BA-B31B-6F7A7344EDFD";
static NSString *const MTIconServiceExpectedIconFoundationPath =
    @"/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation";
static NSString *const MTIconServiceExpectedIconFoundationUUID =
    @"5FA9A56A-94F2-39B1-8468-DD04574428E3";
static const char *const MTIconServiceExpectedOSBuild = "21D61";

static const char *const MTGenerationClassName = "ISGenerationRequest";
static const char *const MTGenerationSelectorName =
    "generateImageReturningRecordIdentifiers:";
static const char *const MTGenerationTypeEncoding = "@24@0:8^@16";
static const char *const MTBundleIconClassName = "ISBundleIdentifierIcon";
static const char *const MTDescriptorClassName = "ISImageDescriptor";
static const char *const MTCacheImageClassName = "IFCacheImage";
static const char *const MTCacheImageInitializerName =
    "initWithCGImage:scale:minimumSize:placeholder:iconSize:";
static const char *const MTCacheImageInitializerTypeEncoding =
    "@68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52";
static const char *const MTImageClassName = "IFImage";
static const char *const MTImageDataInitializerName =
    "initWithData:uuid:validationToken:";
static const char *const MTImageDataInitializerTypeEncoding =
    "@40@0:8@16@24@32";

typedef id (*MTObjectGetterFunction)(id, SEL);
typedef CGSize (*MTSizeGetterFunction)(id, SEL);
typedef double (*MTDoubleGetterFunction)(id, SEL);
typedef BOOL (*MTBoolGetterFunction)(id, SEL);
typedef CGImageRef (*MTCGImageGetterFunction)(id, SEL);
typedef void (*MTBoolSetterFunction)(id, SEL, BOOL);
// These IMPs implement Objective-C init-family methods. ARC requires the
// function type used for a direct IMP call to preserve init's consumed
// receiver and retained result conventions; a mismatch is undefined behavior
// and can over-release private IconFoundation objects after this call returns.
typedef id (*MTCacheImageInitializerFunction)(
    __attribute__((ns_consumed)) id,
    SEL, CGImageRef, double, CGSize, BOOL, CGSize)
    __attribute__((ns_returns_retained));
typedef id (*MTImageDataInitializerFunction)(
    __attribute__((ns_consumed)) id, SEL, id, id, id)
    __attribute__((ns_returns_retained));

static void MTIconServiceABISetError(NSError **error,
                                     NSInteger code,
                                     NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTIconServiceABIErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

static NSString *MTIconServiceExecutablePath(void) {
    uint32_t byteCount = 0;
    if (_NSGetExecutablePath(NULL, &byteCount) == 0 || byteCount == 0 ||
        byteCount > PATH_MAX) {
        return nil;
    }
    char *buffer = calloc(byteCount, 1);
    if (buffer == NULL) return nil;
    NSString *path = nil;
    if (_NSGetExecutablePath(buffer, &byteCount) == 0) {
        path = [NSString stringWithUTF8String:buffer];
    }
    free(buffer);
    return path.stringByStandardizingPath;
}

static NSString *MTIconServiceLoadedImageUUID(NSString *expectedPath) {
    for (uint32_t imageIndex = 0; imageIndex < _dyld_image_count();
         imageIndex += 1) {
        const char *imageName = _dyld_get_image_name(imageIndex);
        if (imageName == NULL ||
            ![[NSString stringWithUTF8String:imageName]
                isEqualToString:expectedPath]) {
            continue;
        }
        const struct mach_header *header = _dyld_get_image_header(imageIndex);
        if (header == NULL || header->magic != MH_MAGIC_64) return nil;
        const struct mach_header_64 *header64 =
            (const struct mach_header_64 *)header;
        const uint8_t *cursor = (const uint8_t *)(header64 + 1);
        for (uint32_t commandIndex = 0;
             commandIndex < header64->ncmds;
             commandIndex += 1) {
            const struct load_command *command =
                (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command)) return nil;
            if (command->cmd == LC_UUID &&
                command->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *UUIDCommand =
                    (const struct uuid_command *)command;
                NSUUID *UUID = [[NSUUID alloc]
                    initWithUUIDBytes:UUIDCommand->uuid];
                return UUID.UUIDString.uppercaseString;
            }
            cursor += command->cmdsize;
        }
    }
    return nil;
}

static BOOL MTIconServiceMethodMatches(Method method,
                                       const char *encoding,
                                       NSString *imagePath) {
    if (method == NULL || encoding == NULL || imagePath.length == 0) return NO;
    const char *actual = method_getTypeEncoding(method);
    IMP implementation = method_getImplementation(method);
    Dl_info info = {0};
    return actual != NULL && strcmp(actual, encoding) == 0 &&
        implementation != NULL &&
        dladdr((const void *)implementation, &info) != 0 &&
        info.dli_fname != NULL &&
        [[NSString stringWithUTF8String:info.dli_fname]
            isEqualToString:imagePath];
}

static Method MTIconServiceExactMethod(id object,
                                       const char *selectorName,
                                       const char *encoding,
                                       NSString *imagePath) {
    if (object == nil || selectorName == NULL || encoding == NULL) return NULL;
    Method method = class_getInstanceMethod(
        object_getClass(object), sel_registerName(selectorName));
    return MTIconServiceMethodMatches(method, encoding, imagePath)
        ? method : NULL;
}

static id MTIconServiceObjectGetter(id object,
                                    const char *selectorName,
                                    NSString *imagePath) {
    Method method = MTIconServiceExactMethod(
        object, selectorName, "@16@0:8", imagePath);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    return implementation == NULL ? nil :
        ((MTObjectGetterFunction)implementation)(object, method_getName(method));
}

static BOOL MTIconServiceSizeGetter(id object,
                                    const char *selectorName,
                                    NSString *imagePath,
                                    CGSize *valueOut) {
    if (valueOut == NULL) return NO;
    Method method = MTIconServiceExactMethod(
        object, selectorName, "{CGSize=dd}16@0:8", imagePath);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    if (implementation == NULL) return NO;
    CGSize value = ((MTSizeGetterFunction)implementation)(
        object, method_getName(method));
    if (!isfinite(value.width) || !isfinite(value.height)) return NO;
    *valueOut = value;
    return YES;
}

static BOOL MTIconServiceDoubleGetter(id object,
                                      const char *selectorName,
                                      NSString *imagePath,
                                      double *valueOut) {
    if (valueOut == NULL) return NO;
    Method method = MTIconServiceExactMethod(
        object, selectorName, "d16@0:8", imagePath);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    if (implementation == NULL) return NO;
    double value = ((MTDoubleGetterFunction)implementation)(
        object, method_getName(method));
    if (!isfinite(value)) return NO;
    *valueOut = value;
    return YES;
}

static BOOL MTIconServiceBoolGetter(id object,
                                    const char *selectorName,
                                    NSString *imagePath,
                                    BOOL *valueOut) {
    if (valueOut == NULL) return NO;
    Method method = MTIconServiceExactMethod(
        object, selectorName, "B16@0:8", imagePath);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    if (implementation == NULL) return NO;
    *valueOut = ((MTBoolGetterFunction)implementation)(
        object, method_getName(method));
    return YES;
}

@interface MTIconServiceRequestContext ()
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, strong, readwrite) NSUUID *iconDigest;
@property(nonatomic, strong, readwrite) NSUUID *descriptorDigest;
@property(nonatomic, assign, readwrite) CGSize pointSize;
@property(nonatomic, assign, readwrite) double scale;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                               iconDigest:(NSUUID *)iconDigest
                         descriptorDigest:(NSUUID *)descriptorDigest
                                pointSize:(CGSize)pointSize
                                    scale:(double)scale;
@end

@implementation MTIconServiceRequestContext

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                               iconDigest:(NSUUID *)iconDigest
                         descriptorDigest:(NSUUID *)descriptorDigest
                                pointSize:(CGSize)pointSize
                                    scale:(double)scale {
    self = [super init];
    if (self == nil) return nil;
    _bundleIdentifier = [bundleIdentifier copy];
    _iconDigest = iconDigest;
    _descriptorDigest = descriptorDigest;
    _pointSize = pointSize;
    _scale = scale;
    return self;
}

@end

BOOL MTIconServiceABIValidateRuntime(Method *generationMethodOut,
                                     NSError **error) {
    if (error != NULL) *error = nil;
    if (generationMethodOut != NULL) *generationMethodOut = NULL;
    char build[32] = {0};
    size_t buildByteCount = sizeof(build);
    const char *serviceName = getenv("XPC_SERVICE_NAME");
    BOOL identityMatches =
        [NSProcessInfo.processInfo.processName
            isEqualToString:@"iconservicesagent"] &&
        [MTIconServiceExecutablePath()
            isEqualToString:MTIconServiceExpectedExecutablePath] &&
        serviceName != NULL &&
        [[NSString stringWithUTF8String:serviceName]
            isEqualToString:MTIconServiceExpectedServiceName] &&
        sysctlbyname("kern.osversion", build, &buildByteCount,
                     NULL, 0) == 0 &&
        strcmp(build, MTIconServiceExpectedOSBuild) == 0;
    if (!identityMatches) {
        MTIconServiceABISetError(error, 1,
            @"Icon service process identity or OS build is unsupported.");
        return NO;
    }
    if (![[MTIconServiceLoadedImageUUID(
            MTIconServiceExpectedIconServicesPath) uppercaseString]
                isEqualToString:MTIconServiceExpectedIconServicesUUID] ||
        ![[MTIconServiceLoadedImageUUID(
            MTIconServiceExpectedIconFoundationPath) uppercaseString]
                isEqualToString:MTIconServiceExpectedIconFoundationUUID]) {
        MTIconServiceABISetError(error, 2,
            @"IconServices or IconFoundation UUID does not match 21D61.");
        return NO;
    }
    Class generationClass = objc_getClass(MTGenerationClassName);
    Method generationMethod = generationClass == Nil ? NULL :
        class_getInstanceMethod(
            generationClass, sel_registerName(MTGenerationSelectorName));
    Class cacheImageClass = objc_getClass(MTCacheImageClassName);
    Method cacheInitializer = cacheImageClass == Nil ? NULL :
        class_getInstanceMethod(
            cacheImageClass, sel_registerName(MTCacheImageInitializerName));
    Class imageClass = objc_getClass(MTImageClassName);
    Method dataInitializer = imageClass == Nil ? NULL :
        class_getInstanceMethod(
            imageClass, sel_registerName(MTImageDataInitializerName));
    if (!MTIconServiceMethodMatches(
            generationMethod, MTGenerationTypeEncoding,
            MTIconServiceExpectedIconServicesPath) ||
        !MTIconServiceMethodMatches(
            cacheInitializer, MTCacheImageInitializerTypeEncoding,
            MTIconServiceExpectedIconFoundationPath) ||
        !MTIconServiceMethodMatches(
            dataInitializer, MTImageDataInitializerTypeEncoding,
            MTIconServiceExpectedIconFoundationPath)) {
        MTIconServiceABISetError(error, 3,
            @"Icon service generation or IFImage construction ABI changed.");
        return NO;
    }
    if (generationMethodOut != NULL) *generationMethodOut = generationMethod;
    return YES;
}

MTIconServiceRequestContext *MTIconServiceABIContextForRequest(
    id request,
    NSError **error) {
    if (error != NULL) *error = nil;
    id icon = MTIconServiceObjectGetter(
        request, "icon", MTIconServiceExpectedIconServicesPath);
    id descriptor = MTIconServiceObjectGetter(
        request, "imageDescriptor", MTIconServiceExpectedIconServicesPath);
    Class expectedIconClass = objc_getClass(MTBundleIconClassName);
    Class expectedDescriptorClass = objc_getClass(MTDescriptorClassName);
    if (icon == nil || descriptor == nil || expectedIconClass == Nil ||
        expectedDescriptorClass == Nil ||
        object_getClass(icon) != expectedIconClass ||
        object_getClass(descriptor) != expectedDescriptorClass) {
        MTIconServiceABISetError(error, 4,
            @"Generation request is not an exact bundle-identifier icon.");
        return nil;
    }
    NSString *bundleIdentifier =
        MTIconServiceObjectGetter(
            icon, "bundleIdentifier", MTIconServiceExpectedIconServicesPath);
    NSUUID *iconDigest = MTIconServiceObjectGetter(
        icon, "digest", MTIconServiceExpectedIconServicesPath);
    NSUUID *descriptorDigest =
        MTIconServiceObjectGetter(
            descriptor, "digest", MTIconServiceExpectedIconServicesPath);
    CGSize pointSize = CGSizeZero;
    double scale = 0;
    if (!MTStaticIconBundleIdentifierIsValid(bundleIdentifier) ||
        ![iconDigest isKindOfClass:NSUUID.class] ||
        ![descriptorDigest isKindOfClass:NSUUID.class] ||
        !MTIconServiceSizeGetter(
            descriptor, "size", MTIconServiceExpectedIconServicesPath,
            &pointSize) ||
        !MTIconServiceDoubleGetter(
            descriptor, "scale", MTIconServiceExpectedIconServicesPath,
            &scale) ||
        pointSize.width != pointSize.height || pointSize.width < 1 ||
        pointSize.width > 400 || scale < 1 || scale > 3 ||
        floor(scale) != scale) {
        MTIconServiceABISetError(error, 5,
            @"Generation request identity or descriptor is unsupported.");
        return nil;
    }
    return [[MTIconServiceRequestContext alloc]
        initWithBundleIdentifier:bundleIdentifier
        iconDigest:iconDigest
        descriptorDigest:descriptorDigest
        pointSize:pointSize
        scale:scale];
}

BOOL MTIconServiceABIReadImageGeometry(
    id image,
    MTIconServiceImageGeometry *geometryOut) {
    if (geometryOut == NULL) return NO;
    MTIconServiceImageGeometry geometry = {0};
    if (!MTIconServiceSizeGetter(
            image, "pixelSize", MTIconServiceExpectedIconFoundationPath,
            &geometry.pixelSize) ||
        !MTIconServiceSizeGetter(
            image, "minimumSize", MTIconServiceExpectedIconFoundationPath,
            &geometry.minimumSize) ||
        !MTIconServiceSizeGetter(
            image, "iconSize", MTIconServiceExpectedIconFoundationPath,
            &geometry.iconSize) ||
        !MTIconServiceDoubleGetter(
            image, "scale", MTIconServiceExpectedIconFoundationPath,
            &geometry.scale) ||
        !MTIconServiceBoolGetter(
            image, "placeholder", MTIconServiceExpectedIconFoundationPath,
            &geometry.placeholder) ||
        !MTIconServiceBoolGetter(
            image, "largest", MTIconServiceExpectedIconFoundationPath,
            &geometry.largest)) {
        return NO;
    }
    *geometryOut = geometry;
    return YES;
}

BOOL MTIconServiceImageGeometryIsSupported(
    MTIconServiceImageGeometry geometry) {
    double pixelWidth = geometry.pixelSize.width;
    double pixelHeight = geometry.pixelSize.height;
    return isfinite(pixelWidth) && isfinite(pixelHeight) &&
        isfinite(geometry.minimumSize.width) &&
        isfinite(geometry.minimumSize.height) &&
        isfinite(geometry.iconSize.width) &&
        isfinite(geometry.iconSize.height) && isfinite(geometry.scale) &&
        pixelWidth >= 1 && pixelWidth <= 1200 &&
        pixelWidth == pixelHeight && floor(pixelWidth) == pixelWidth &&
        geometry.scale >= 1 && geometry.scale <= 3 &&
        floor(geometry.scale) == geometry.scale &&
        geometry.minimumSize.width > 0 &&
        geometry.minimumSize.width == geometry.minimumSize.height &&
        geometry.iconSize.width >= geometry.minimumSize.width &&
        geometry.iconSize.width == geometry.iconSize.height &&
        fabs(geometry.iconSize.width * geometry.scale - pixelWidth) < 0.001 &&
        !geometry.placeholder;
}

static BOOL MTIconServiceImageGeometryEqual(
    MTIconServiceImageGeometry left,
    MTIconServiceImageGeometry right) {
    return CGSizeEqualToSize(left.pixelSize, right.pixelSize) &&
        CGSizeEqualToSize(left.minimumSize, right.minimumSize) &&
        CGSizeEqualToSize(left.iconSize, right.iconSize) &&
        left.scale == right.scale &&
        left.placeholder == right.placeholder &&
        left.largest == right.largest;
}

CGImageRef MTIconServiceABICopyImageCGImage(id image) {
    Method method = MTIconServiceExactMethod(
        image, "cgImage", "^{CGImage=}16@0:8",
        MTIconServiceExpectedIconFoundationPath);
    IMP implementation = method == NULL ? NULL : method_getImplementation(method);
    CGImageRef result = implementation == NULL ? NULL :
        ((MTCGImageGetterFunction)implementation)(
            image, method_getName(method));
    return result == NULL ? NULL : CGImageRetain(result);
}

NSString *MTIconServiceABIImageDigest(id image) {
    id digest = MTIconServiceObjectGetter(
        image, "digest", MTIconServiceExpectedIconFoundationPath);
    return [digest isKindOfClass:NSUUID.class]
        ? [(NSUUID *)digest UUIDString].uppercaseString : nil;
}

id MTIconServiceABICreateReplacementImage(CGImageRef image,
                                          id originalImage,
                                          NSError **error) {
    if (error != NULL) *error = nil;
    MTIconServiceImageGeometry geometry = {0};
    if (image == NULL ||
        !MTIconServiceABIReadImageGeometry(originalImage, &geometry) ||
        !MTIconServiceImageGeometryIsSupported(geometry) ||
        CGImageGetWidth(image) != (size_t)geometry.pixelSize.width ||
        CGImageGetHeight(image) != (size_t)geometry.pixelSize.height) {
        MTIconServiceABISetError(error, 6,
            @"Replacement raster does not match the original IFImage geometry.");
        return nil;
    }

    Class cacheImageClass = objc_getClass(MTCacheImageClassName);
    SEL cacheSelector = sel_registerName(MTCacheImageInitializerName);
    Method cacheMethod = cacheImageClass == Nil ? NULL :
        class_getInstanceMethod(cacheImageClass, cacheSelector);
    Class imageClass = objc_getClass(MTImageClassName);
    SEL dataSelector = sel_registerName(MTImageDataInitializerName);
    Method dataMethod = imageClass == Nil ? NULL :
        class_getInstanceMethod(imageClass, dataSelector);
    if (!MTIconServiceMethodMatches(
            cacheMethod, MTCacheImageInitializerTypeEncoding,
            MTIconServiceExpectedIconFoundationPath) ||
        !MTIconServiceMethodMatches(
            dataMethod, MTImageDataInitializerTypeEncoding,
            MTIconServiceExpectedIconFoundationPath)) {
        MTIconServiceABISetError(error, 7,
            @"IFImage construction ABI failed its call-time gate.");
        return nil;
    }

    id temporary = ((MTCacheImageInitializerFunction)
        method_getImplementation(cacheMethod))(
            [cacheImageClass alloc], cacheSelector, image, geometry.scale,
            geometry.minimumSize, geometry.placeholder, geometry.iconSize);
    id bitmapData = MTIconServiceObjectGetter(
        temporary, "bitmapData", MTIconServiceExpectedIconFoundationPath);
    id originalUUID = MTIconServiceObjectGetter(
        originalImage, "uuid", MTIconServiceExpectedIconFoundationPath);
    id validationToken =
        MTIconServiceObjectGetter(
            originalImage, "validationToken",
            MTIconServiceExpectedIconFoundationPath);
    if (temporary == nil || bitmapData == nil ||
        ![validationToken respondsToSelector:@selector(length)] ||
        [(NSData *)validationToken length] != 40) {
        MTIconServiceABISetError(error, 8,
            @"IFImage serialization or validation token is invalid.");
        return nil;
    }
    id replacement = ((MTImageDataInitializerFunction)
        method_getImplementation(dataMethod))(
            [imageClass alloc], dataSelector,
            bitmapData, originalUUID, validationToken);
    if (replacement == nil) {
        MTIconServiceABISetError(error, 9,
            @"Serialized IFImage could not be rehydrated.");
        return nil;
    }
    Method largestSetter = MTIconServiceExactMethod(
        replacement, "setLargest:", "v20@0:8B16",
        MTIconServiceExpectedIconFoundationPath);
    if (largestSetter == NULL) {
        MTIconServiceABISetError(error, 10,
            @"IFImage largest-flag setter changed.");
        return nil;
    }
    ((MTBoolSetterFunction)method_getImplementation(largestSetter))(
        replacement, method_getName(largestSetter), geometry.largest);

    MTIconServiceImageGeometry replacementGeometry = {0};
    id replacementToken =
        MTIconServiceObjectGetter(
            replacement, "validationToken",
            MTIconServiceExpectedIconFoundationPath);
    if (!MTIconServiceABIReadImageGeometry(
            replacement, &replacementGeometry) ||
        !MTIconServiceImageGeometryEqual(geometry, replacementGeometry) ||
        ![replacementToken isEqual:validationToken]) {
        MTIconServiceABISetError(error, 11,
            @"Rehydrated IFImage did not preserve geometry or token identity.");
        return nil;
    }
    return replacement;
}
