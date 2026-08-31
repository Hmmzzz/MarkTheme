#import "MTRuntimePublishedImageLoader.h"

#import <ImageIO/ImageIO.h>

#import "MTGenerationReader.h"

NSString *const MTRuntimePublishedImageLoaderErrorDomain =
    @"com.hmmzzz.marktheme.runtime-published-image-loader";

static const uint64_t MTRuntimePublishedImageMaximumSourcePixelCount =
    16ULL * 1024ULL * 1024ULL;
static const uint32_t MTRuntimePublishedImageMaximumSourceDimension = 4096;

static BOOL MTRuntimePublishedImageTargetFitsBudget(
    uint32_t pixelWidth,
    uint32_t pixelHeight,
    uint64_t maximumDecodedByteCount) {
    if (pixelWidth == 0 || pixelHeight == 0) return NO;
    uint64_t pixelCount =
        (uint64_t)pixelWidth * (uint64_t)pixelHeight;
    return pixelCount <= UINT64_MAX / 4 &&
        pixelCount * 4 <= maximumDecodedByteCount;
}

static void MTRuntimePublishedImageLoaderSetError(
    NSError **error,
    MTRuntimePublishedImageLoaderErrorCode code,
    NSString *description,
    NSError * _Nullable underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError
        errorWithDomain:MTRuntimePublishedImageLoaderErrorDomain
                   code:code
               userInfo:userInfo];
}

@interface MTRuntimeDecodedImage ()
- (instancetype)initWithImage:(CGImageRef)image
                   pixelWidth:(uint32_t)pixelWidth
                  pixelHeight:(uint32_t)pixelHeight
              decodedByteCost:(NSUInteger)decodedByteCost
                 residentCost:(NSUInteger)residentCost;
@end

@interface MTRuntimePublishedImageLoader ()
- (nullable MTRuntimeDecodedImage *)
    mt_loadImageForGeneration:(MTGeneration *)generation
                     resource:(MTGenerationResource *)resource
             targetPixelWidth:(uint32_t)targetPixelWidth
            targetPixelHeight:(uint32_t)targetPixelHeight
                 resizePolicy:
                     (MTRuntimePublishedImageResizePolicy)resizePolicy
     preserveSourceDimensions:(BOOL)preserveSourceDimensions
                        error:(NSError **)error;
@end

@implementation MTRuntimeDecodedImage

- (instancetype)initWithImage:(CGImageRef)image
                   pixelWidth:(uint32_t)pixelWidth
                  pixelHeight:(uint32_t)pixelHeight
              decodedByteCost:(NSUInteger)decodedByteCost
                 residentCost:(NSUInteger)residentCost {
    NSParameterAssert(image != NULL);
    self = [super init];
    if (self == nil) return nil;
    _image = CGImageRetain(image);
    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    _decodedByteCost = decodedByteCost;
    _residentCost = residentCost;
    return self;
}

- (void)dealloc {
    if (_image != NULL) CGImageRelease(_image);
}

@end

@implementation MTRuntimePublishedImageLoader

+ (instancetype)staticIconLoader {
    return [[self alloc]
        initWithMaximumEncodedByteCount:32ULL * 1024ULL * 1024ULL
        maximumDecodedByteCount:4ULL * 1024ULL * 1024ULL];
}

- (instancetype)initWithMaximumEncodedByteCount:
    (uint64_t)maximumEncodedByteCount
                    maximumDecodedByteCount:
                        (uint64_t)maximumDecodedByteCount {
    NSParameterAssert(maximumEncodedByteCount > 0);
    NSParameterAssert(maximumDecodedByteCount > 0);
    self = [super init];
    if (self == nil) return nil;
    _maximumEncodedByteCount = maximumEncodedByteCount;
    _maximumDecodedByteCount = maximumDecodedByteCount;
    return self;
}

- (MTRuntimeDecodedImage *)
    loadImageForGeneration:(MTGeneration *)generation
                  resource:(MTGenerationResource *)resource
          targetPixelWidth:(uint32_t)targetPixelWidth
         targetPixelHeight:(uint32_t)targetPixelHeight
                     error:(NSError **)error {
    return [self loadImageForGeneration:generation
                               resource:resource
                       targetPixelWidth:targetPixelWidth
                      targetPixelHeight:targetPixelHeight
                           resizePolicy:
                               MTRuntimePublishedImageResizePolicyExactOrDownsample
                                  error:error];
}

- (MTRuntimeDecodedImage *)
    loadImageForGeneration:(MTGeneration *)generation
                  resource:(MTGenerationResource *)resource
          targetPixelWidth:(uint32_t)targetPixelWidth
         targetPixelHeight:(uint32_t)targetPixelHeight
              resizePolicy:(MTRuntimePublishedImageResizePolicy)resizePolicy
                     error:(NSError **)error {
    return [self mt_loadImageForGeneration:generation
                                  resource:resource
                          targetPixelWidth:targetPixelWidth
                         targetPixelHeight:targetPixelHeight
                              resizePolicy:resizePolicy
                  preserveSourceDimensions:NO
                                     error:error];
}

- (MTRuntimeDecodedImage *)
    loadImagePreservingSourceDimensionsForGeneration:
        (MTGeneration *)generation
                                          resource:
        (MTGenerationResource *)resource
                                             error:(NSError **)error {
    return [self mt_loadImageForGeneration:generation
                                  resource:resource
                          targetPixelWidth:0
                         targetPixelHeight:0
                              resizePolicy:
        MTRuntimePublishedImageResizePolicyExactOrDownsample
                  preserveSourceDimensions:YES
                                     error:error];
}

- (MTRuntimeDecodedImage *)
    mt_loadImageForGeneration:(MTGeneration *)generation
                     resource:(MTGenerationResource *)resource
             targetPixelWidth:(uint32_t)targetPixelWidth
            targetPixelHeight:(uint32_t)targetPixelHeight
                 resizePolicy:
                     (MTRuntimePublishedImageResizePolicy)resizePolicy
     preserveSourceDimensions:(BOOL)preserveSourceDimensions
                        error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (![generation isKindOfClass:MTGeneration.class] ||
        ![resource isKindOfClass:MTGenerationResource.class] ||
        (!preserveSourceDimensions &&
         (targetPixelWidth == 0 || targetPixelHeight == 0)) ||
         (resizePolicy !=
             MTRuntimePublishedImageResizePolicyExactOrDownsample &&
         resizePolicy !=
             MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale &&
         resizePolicy !=
             MTRuntimePublishedImageResizePolicyBoundedScaleToFill)) {
        MTRuntimePublishedImageLoaderSetError(error,
            MTRuntimePublishedImageLoaderErrorInvalidRequest,
            @"Published image decode requires one Generation resource and target dimensions.",
            nil);
        return nil;
    }
    if (!preserveSourceDimensions &&
        !MTRuntimePublishedImageTargetFitsBudget(
            targetPixelWidth, targetPixelHeight,
            self.maximumDecodedByteCount)) {
        MTRuntimePublishedImageLoaderSetError(error,
            MTRuntimePublishedImageLoaderErrorLimitExceeded,
            @"Published image target exceeds the decoded-memory budget.", nil);
        return nil;
    }
    NSError *resourceError = nil;
    NSData *data = [generation
        assetDataForResource:resource
        maximumByteCount:self.maximumEncodedByteCount
        error:&resourceError];
    if (data == nil) {
        MTRuntimePublishedImageLoaderErrorCode code =
            resource.assetByteCount > self.maximumEncodedByteCount
                ? MTRuntimePublishedImageLoaderErrorLimitExceeded
                : MTRuntimePublishedImageLoaderErrorResourceRejected;
        MTRuntimePublishedImageLoaderSetError(error, code,
            @"Published image bytes failed the Runtime Generation boundary.",
            resourceError);
        return nil;
    }

    NSDictionary *sourceOptions = @{
        (__bridge NSString *)kCGImageSourceTypeIdentifierHint : @"public.png",
    };
    CGImageSourceRef source = CGImageSourceCreateWithData(
        (__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)sourceOptions);
    if (source == NULL) {
        MTRuntimePublishedImageLoaderSetError(error,
            MTRuntimePublishedImageLoaderErrorUnsupportedImage,
            @"ImageIO rejected the verified Runtime asset.", nil);
        return nil;
    }

    BOOL sourceIsPNG = CGImageSourceGetType(source) != NULL &&
        [(__bridge NSString *)CGImageSourceGetType(source)
            isEqualToString:@"public.png"];
    BOOL sourceIsComplete = CGImageSourceGetCount(source) == 1 &&
        CGImageSourceGetStatus(source) == kCGImageStatusComplete &&
        CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
    NSDictionary *propertyOptions = @{
        (__bridge NSString *)kCGImageSourceShouldCache : @NO,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @NO,
        (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO,
    };
    NSDictionary *properties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(
            source, 0, (__bridge CFDictionaryRef)propertyOptions));
    NSNumber *width = properties[
        (__bridge NSString *)kCGImagePropertyPixelWidth];
    NSNumber *height = properties[
        (__bridge NSString *)kCGImagePropertyPixelHeight];
    uint64_t sourceWidth = [width isKindOfClass:NSNumber.class]
        ? width.unsignedLongLongValue : 0;
    uint64_t sourceHeight = [height isKindOfClass:NSNumber.class]
        ? height.unsignedLongLongValue : 0;
    BOOL sourceDimensionsAreBounded =
        sourceWidth > 0 && sourceHeight > 0 &&
        sourceWidth <= MTRuntimePublishedImageMaximumSourceDimension &&
        sourceHeight <= MTRuntimePublishedImageMaximumSourceDimension &&
        sourceWidth <= MTRuntimePublishedImageMaximumSourcePixelCount /
            sourceHeight;
    if (preserveSourceDimensions) {
        if (!sourceDimensionsAreBounded || sourceWidth > UINT32_MAX ||
            sourceHeight > UINT32_MAX ||
            !MTRuntimePublishedImageTargetFitsBudget(
                (uint32_t)sourceWidth, (uint32_t)sourceHeight,
                self.maximumDecodedByteCount)) {
            CFRelease(source);
            MTRuntimePublishedImageLoaderSetError(error,
                MTRuntimePublishedImageLoaderErrorLimitExceeded,
                @"Runtime asset dimensions exceed the preserve-source budget.",
                nil);
            return nil;
        }
        targetPixelWidth = (uint32_t)sourceWidth;
        targetPixelHeight = (uint32_t)sourceHeight;
    }
    BOOL exactDimensions = sourceDimensionsAreBounded &&
        sourceWidth == targetPixelWidth &&
        sourceHeight == targetPixelHeight;
    BOOL canDownsample = sourceDimensionsAreBounded &&
        sourceWidth >= targetPixelWidth &&
        sourceHeight >= targetPixelHeight &&
        sourceWidth * targetPixelHeight ==
            sourceHeight * targetPixelWidth;
    BOOL canLegacyTwoToThreeUpscale =
        resizePolicy ==
            MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale &&
        sourceDimensionsAreBounded &&
        sourceWidth < targetPixelWidth &&
        sourceHeight < targetPixelHeight &&
        sourceWidth * targetPixelHeight ==
            sourceHeight * targetPixelWidth &&
        sourceWidth * 3 == (uint64_t)targetPixelWidth * 2 &&
        sourceHeight * 3 == (uint64_t)targetPixelHeight * 2;
    BOOL canBoundedScaleToFill =
        resizePolicy ==
            MTRuntimePublishedImageResizePolicyBoundedScaleToFill &&
        sourceDimensionsAreBounded;
    uint64_t sourceDimensionDelta = sourceWidth > sourceHeight
        ? sourceWidth - sourceHeight : sourceHeight - sourceWidth;
    BOOL canCenterCropNearSquare = sourceDimensionsAreBounded &&
        targetPixelWidth == targetPixelHeight &&
        sourceWidth >= targetPixelWidth &&
        sourceHeight >= targetPixelHeight &&
        sourceDimensionDelta <= 1;
    if (!sourceIsPNG || !sourceIsComplete ||
        (!exactDimensions && !canDownsample && !canCenterCropNearSquare &&
         !canLegacyTwoToThreeUpscale && !canBoundedScaleToFill)) {
        CFRelease(source);
        MTRuntimePublishedImageLoaderSetError(error,
            MTRuntimePublishedImageLoaderErrorUnsupportedImage,
            @"Runtime asset type, frame count, status, or target aspect are unsupported.",
            nil);
        return nil;
    }

    uint32_t thumbnailMaximumDimension = MAX(targetPixelWidth,
                                               targetPixelHeight);
    if (canCenterCropNearSquare && !canDownsample) {
        uint64_t sourceMaximum = MAX(sourceWidth, sourceHeight);
        uint64_t sourceMinimum = MIN(sourceWidth, sourceHeight);
        uint64_t scaledMaximum =
            (sourceMaximum * targetPixelWidth + sourceMinimum - 1) /
            sourceMinimum;
        if (scaledMaximum > UINT32_MAX) {
            CFRelease(source);
            MTRuntimePublishedImageLoaderSetError(error,
                MTRuntimePublishedImageLoaderErrorLimitExceeded,
                @"Near-square Runtime thumbnail dimensions overflowed.", nil);
            return nil;
        }
        thumbnailMaximumDimension = (uint32_t)scaledMaximum;
    }
    BOOL boundedSourceFitsTarget = canBoundedScaleToFill &&
        sourceWidth <= targetPixelWidth && sourceHeight <= targetPixelHeight;
    NSDictionary *decodeOptions = exactDimensions ||
        canLegacyTwoToThreeUpscale || boundedSourceFitsTarget ? @{
        (__bridge NSString *)kCGImageSourceShouldCache : @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO,
    } : @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize :
            @(thumbnailMaximumDimension),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO,
    };
    CGImageRef decodedImage = exactDimensions || canLegacyTwoToThreeUpscale ||
        boundedSourceFitsTarget
        ? CGImageSourceCreateImageAtIndex(
            source, 0, (__bridge CFDictionaryRef)decodeOptions)
        : CGImageSourceCreateThumbnailAtIndex(
            source, 0, (__bridge CFDictionaryRef)decodeOptions);
    CGImageRef image = decodedImage;
    if (decodedImage != NULL && canBoundedScaleToFill && !exactDimensions) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        size_t bytesPerRow = (size_t)targetPixelWidth * 4;
        CGContextRef context = colorSpace == NULL ? NULL :
            CGBitmapContextCreate(NULL, targetPixelWidth, targetPixelHeight,
                8, bytesPerRow, colorSpace,
                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
        if (context != NULL) {
            CGContextSetBlendMode(context, kCGBlendModeCopy);
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context,
                CGRectMake(0, 0, targetPixelWidth, targetPixelHeight),
                decodedImage);
            image = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
        } else {
            image = NULL;
        }
        CGImageRelease(decodedImage);
    } else if (decodedImage != NULL && canLegacyTwoToThreeUpscale) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        size_t bytesPerRow = (size_t)targetPixelWidth * 4;
        CGContextRef context = colorSpace == NULL ? NULL :
            CGBitmapContextCreate(NULL, targetPixelWidth, targetPixelHeight,
                8, bytesPerRow, colorSpace,
                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (colorSpace != NULL) CGColorSpaceRelease(colorSpace);
        if (context != NULL) {
            CGContextSetBlendMode(context, kCGBlendModeCopy);
            CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
            CGContextDrawImage(context,
                CGRectMake(0, 0, targetPixelWidth, targetPixelHeight),
                decodedImage);
            image = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
        } else {
            image = NULL;
        }
        CGImageRelease(decodedImage);
    } else if (decodedImage != NULL && canCenterCropNearSquare &&
        !canDownsample) {
        size_t decodedWidth = CGImageGetWidth(decodedImage);
        size_t decodedHeight = CGImageGetHeight(decodedImage);
        if (decodedWidth >= targetPixelWidth &&
            decodedHeight >= targetPixelHeight) {
            CGRect crop = CGRectMake(
                (CGFloat)((decodedWidth - targetPixelWidth) / 2),
                (CGFloat)((decodedHeight - targetPixelHeight) / 2),
                targetPixelWidth, targetPixelHeight);
            image = CGImageCreateWithImageInRect(decodedImage, crop);
            CGImageRelease(decodedImage);
        }
    }
    BOOL decoded = image != NULL &&
        CGImageGetWidth(image) == targetPixelWidth &&
        CGImageGetHeight(image) == targetPixelHeight &&
        CGImageGetBitsPerComponent(image) > 0 &&
        CGImageGetBitsPerComponent(image) <= 8 &&
        (CGImageGetBitmapInfo(image) & kCGBitmapFloatComponents) == 0 &&
        CGImageSourceGetStatus(source) == kCGImageStatusComplete &&
        CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
    size_t bytesPerRow = decoded ? CGImageGetBytesPerRow(image) : 0;
    uint64_t decodedByteCount = 0;
    if (decoded && bytesPerRow > 0 &&
        targetPixelHeight <= UINT64_MAX / (uint64_t)bytesPerRow) {
        decodedByteCount = (uint64_t)bytesPerRow * targetPixelHeight;
    } else {
        decoded = NO;
    }
    if (!decoded || decodedByteCount > self.maximumDecodedByteCount ||
        decodedByteCount > NSUIntegerMax ||
        data.length > NSUIntegerMax - (NSUInteger)decodedByteCount) {
        if (image != NULL) CGImageRelease(image);
        CFRelease(source);
        MTRuntimePublishedImageLoaderSetError(error,
            decodedByteCount > self.maximumDecodedByteCount
                ? MTRuntimePublishedImageLoaderErrorLimitExceeded
                : MTRuntimePublishedImageLoaderErrorDecode,
            @"Runtime image decode failed or exceeded its decoded-memory budget.",
            nil);
        return nil;
    }
    NSUInteger residentCost =
        data.length + (NSUInteger)decodedByteCount;
    MTRuntimeDecodedImage *result = [[MTRuntimeDecodedImage alloc]
        initWithImage:image
        pixelWidth:targetPixelWidth
        pixelHeight:targetPixelHeight
        decodedByteCost:(NSUInteger)decodedByteCount
        residentCost:residentCost];
    CGImageRelease(image);
    CFRelease(source);
    return result;
}

@end
