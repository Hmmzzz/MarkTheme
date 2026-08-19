#import "MTSafeImageDecoder.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <stdlib.h>

#import "MTDigest.h"
#import "MTImportSession.h"
#import "MTSafeImageInspector.h"
#import "MTSafeImageValidationInternal.h"

NSString *const MTSafeImageDecoderErrorDomain =
    @"com.hmmzzz.marktheme.safe-image-decoder";
NSString *const MTSafeImagePixelFormatRGBA8PremultipliedLast =
    @"rgba8-premultiplied-last-top-left";
NSString *const MTSafeImageColorSpaceSRGB = @"srgb";

@interface MTSafeImageDecodeResult ()

- (instancetype)initWithInspection:(MTSafeImageInspection *)inspection
                 thumbnailPixelData:(NSData *)thumbnailPixelData
                thumbnailPixelWidth:(uint32_t)thumbnailPixelWidth
               thumbnailPixelHeight:(uint32_t)thumbnailPixelHeight
               thumbnailBytesPerRow:(NSUInteger)thumbnailBytesPerRow
     fullResolutionDecodedByteCount:(uint64_t)fullResolutionDecodedByteCount
                        pixelFormat:(NSString *)pixelFormat
                     colorSpaceName:(NSString *)colorSpaceName
               thumbnailPixelSHA256:(NSString *)thumbnailPixelSHA256
                        downsampled:(BOOL)downsampled;

@end

@implementation MTSafeImageDecodeLimits

+ (instancetype)defaultLimits {
    return [[self alloc]
        initWithMaximumFullResolutionDimensionPixels:4096
                  maximumFullResolutionPixelCount:16ULL * 1024ULL * 1024ULL
                maximumFullResolutionDecodedBytes:64ULL * 1024ULL * 1024ULL
                 maximumThumbnailDimensionPixels:512
                         maximumThumbnailBytes:1ULL * 1024ULL * 1024ULL];
}

- (instancetype)
    initWithMaximumFullResolutionDimensionPixels:
        (uint32_t)maximumFullResolutionDimensionPixels
                  maximumFullResolutionPixelCount:
                      (uint64_t)maximumFullResolutionPixelCount
                maximumFullResolutionDecodedBytes:
                    (uint64_t)maximumFullResolutionDecodedBytes
                 maximumThumbnailDimensionPixels:
                     (uint32_t)maximumThumbnailDimensionPixels
                         maximumThumbnailBytes:
                             (uint64_t)maximumThumbnailBytes {
    NSParameterAssert(maximumFullResolutionDimensionPixels > 0);
    NSParameterAssert(maximumFullResolutionPixelCount > 0);
    NSParameterAssert(maximumFullResolutionPixelCount <= UINT64_MAX / 4ULL);
    NSParameterAssert(maximumFullResolutionDecodedBytes > 0);
    NSParameterAssert(maximumThumbnailDimensionPixels > 0);
    NSParameterAssert(maximumThumbnailBytes > 0);
    self = [super init];
    if (self == nil) return nil;
    _maximumFullResolutionDimensionPixels =
        maximumFullResolutionDimensionPixels;
    _maximumFullResolutionPixelCount = maximumFullResolutionPixelCount;
    _maximumFullResolutionDecodedBytes = maximumFullResolutionDecodedBytes;
    _maximumThumbnailDimensionPixels = maximumThumbnailDimensionPixels;
    _maximumThumbnailBytes = maximumThumbnailBytes;
    return self;
}

@end


@implementation MTSafeImageDecodeResult

- (instancetype)initWithInspection:(MTSafeImageInspection *)inspection
                 thumbnailPixelData:(NSData *)thumbnailPixelData
                thumbnailPixelWidth:(uint32_t)thumbnailPixelWidth
               thumbnailPixelHeight:(uint32_t)thumbnailPixelHeight
               thumbnailBytesPerRow:(NSUInteger)thumbnailBytesPerRow
     fullResolutionDecodedByteCount:(uint64_t)fullResolutionDecodedByteCount
                        pixelFormat:(NSString *)pixelFormat
                     colorSpaceName:(NSString *)colorSpaceName
               thumbnailPixelSHA256:(NSString *)thumbnailPixelSHA256
                        downsampled:(BOOL)downsampled {
    self = [super init];
    if (self == nil) return nil;
    _inspection = inspection;
    _thumbnailPixelData = [thumbnailPixelData copy];
    _thumbnailPixelWidth = thumbnailPixelWidth;
    _thumbnailPixelHeight = thumbnailPixelHeight;
    _thumbnailBytesPerRow = thumbnailBytesPerRow;
    _fullResolutionDecodedByteCount = fullResolutionDecodedByteCount;
    _pixelFormat = [pixelFormat copy];
    _colorSpaceName = [colorSpaceName copy];
    _thumbnailPixelSHA256 = [thumbnailPixelSHA256 copy];
    _downsampled = downsampled;
    return self;
}

@end

static NSError *MTImageDecoderError(
    MTSafeImageDecoderErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary
        dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:MTSafeImageDecoderErrorDomain
                               code:code
                           userInfo:userInfo];
}

static id _Nullable MTImageDecoderFail(
    NSError **error,
    MTSafeImageDecoderErrorCode code,
    NSString *description,
    NSError *_Nullable underlying) {
    if (error != NULL) {
        *error = MTImageDecoderError(code, description, underlying);
    }
    return nil;
}

static NSError *MTImageDecoderMapValidationError(NSError *underlying) {
    if ([underlying.domain isEqualToString:MTSafeImageDecoderErrorDomain]) {
        return underlying;
    }
    MTSafeImageDecoderErrorCode code = MTSafeImageDecoderErrorValidation;
    if ([underlying.domain
            isEqualToString:MTSafeImageInspectorErrorDomain]) {
        switch ((MTSafeImageInspectorErrorCode)underlying.code) {
            case MTSafeImageInspectorErrorInvalidRequest:
                code = MTSafeImageDecoderErrorInvalidRequest;
                break;
            case MTSafeImageInspectorErrorUnsafeSource:
            case MTSafeImageInspectorErrorSourceChanged:
            case MTSafeImageInspectorErrorIO:
                code = MTSafeImageDecoderErrorSourceRejected;
                break;
            case MTSafeImageInspectorErrorLimitExceeded:
                code = MTSafeImageDecoderErrorLimitExceeded;
                break;
            case MTSafeImageInspectorErrorCancelled:
                code = MTSafeImageDecoderErrorCancelled;
                break;
            case MTSafeImageInspectorErrorUnsupportedFormat:
            case MTSafeImageInspectorErrorCorruptData:
            case MTSafeImageInspectorErrorAnimatedImage:
            case MTSafeImageInspectorErrorImageIO:
                code = MTSafeImageDecoderErrorValidation;
                break;
            case MTSafeImageInspectorErrorCorruptPixelData:
                code = MTSafeImageDecoderErrorDecode;
                break;
        }
    }
    return MTImageDecoderError(code,
        @"The staged image did not pass the decode boundary.", underlying);
}

static BOOL MTImageHasAlpha(CGImageRef image) {
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(image);
    return alphaInfo == kCGImageAlphaPremultipliedLast ||
        alphaInfo == kCGImageAlphaPremultipliedFirst ||
        alphaInfo == kCGImageAlphaLast ||
        alphaInfo == kCGImageAlphaFirst ||
        alphaInfo == kCGImageAlphaOnly;
}

static BOOL MTImageCalculateThumbnailDimensions(
    uint32_t sourceWidth,
    uint32_t sourceHeight,
    uint32_t maximumDimension,
    uint32_t *outputWidth,
    uint32_t *outputHeight) {
    uint32_t sourceMaximum = MAX(sourceWidth, sourceHeight);
    if (sourceMaximum <= maximumDimension) {
        *outputWidth = sourceWidth;
        *outputHeight = sourceHeight;
        return YES;
    }
    if (sourceWidth >= sourceHeight) {
        *outputWidth = maximumDimension;
        uint64_t scaled = (uint64_t)sourceHeight * maximumDimension +
            sourceWidth / 2U;
        *outputHeight = (uint32_t)MAX(1ULL, scaled / sourceWidth);
    } else {
        *outputHeight = maximumDimension;
        uint64_t scaled = (uint64_t)sourceWidth * maximumDimension +
            sourceHeight / 2U;
        *outputWidth = (uint32_t)MAX(1ULL, scaled / sourceHeight);
    }
    return *outputWidth > 0 && *outputHeight > 0;
}

static MTSafeImageDecodeResult *_Nullable MTImageDecodeValidatedSource(
    CGImageSourceRef source,
    MTSafeImageInspection *inspection,
    MTSafeImageDecodeLimits *limits,
    uint32_t thumbnailMaximumDimension,
    MTImportCancellationToken *_Nullable cancellationToken,
    NSError **error) {
    if (inspection.orientation != 1) {
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorValidation,
            @"Only canonical top-left PNG orientation is decoded.", nil);
    }
    if (inspection.pixelWidth >
            limits.maximumFullResolutionDimensionPixels ||
        inspection.pixelHeight >
            limits.maximumFullResolutionDimensionPixels ||
        inspection.pixelCount > limits.maximumFullResolutionPixelCount ||
        inspection.decodedByteEstimate >
            limits.maximumFullResolutionDecodedBytes) {
        return MTImageDecoderFail(error,
            MTSafeImageDecoderErrorLimitExceeded,
            @"The full-resolution pixel decode exceeds its independent budget.",
            nil);
    }
    if (cancellationToken.isCancelled) {
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorCancelled,
            @"Image decode was cancelled before full-resolution validation.",
            nil);
    }

    NSDictionary *decodeOptions = @{
        (__bridge NSString *)kCGImageSourceShouldCache : @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately : @YES,
        (__bridge NSString *)kCGImageSourceShouldAllowFloat : @NO,
    };
    CGImageRef decodedImage = CGImageSourceCreateImageAtIndex(
        source, 0, (__bridge CFDictionaryRef)decodeOptions);
    if (decodedImage == NULL) {
        if (cancellationToken.isCancelled) {
            return MTImageDecoderFail(error,
                MTSafeImageDecoderErrorCancelled,
                @"Image decode was cancelled while ImageIO read pixels.", nil);
        }
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorDecode,
            @"ImageIO could not decode the complete PNG pixel stream.", nil);
    }

    size_t decodedWidth = CGImageGetWidth(decodedImage);
    size_t decodedHeight = CGImageGetHeight(decodedImage);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(decodedImage);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(decodedImage);
    size_t bytesPerRow = CGImageGetBytesPerRow(decodedImage);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(decodedImage);
    CGColorSpaceRef sourceColorSpace = CGImageGetColorSpace(decodedImage);
    CGColorSpaceModel colorModel = sourceColorSpace == NULL
        ? kCGColorSpaceModelUnknown
        : CGColorSpaceGetModel(sourceColorSpace);
    BOOL acceptedColorModel = colorModel == kCGColorSpaceModelRGB ||
        colorModel == kCGColorSpaceModelMonochrome ||
        colorModel == kCGColorSpaceModelIndexed;
    BOOL alphaMatches = MTImageHasAlpha(decodedImage) == inspection.hasAlpha;
    BOOL validDecodedShape =
        decodedWidth == inspection.pixelWidth &&
        decodedHeight == inspection.pixelHeight &&
        bitsPerComponent > 0 && bitsPerComponent <= 8 &&
        bitsPerPixel > 0 && bitsPerPixel <= 32 &&
        bytesPerRow > 0 &&
        (bitmapInfo & kCGBitmapFloatComponents) == 0 &&
        acceptedColorModel && alphaMatches;
    uint64_t decodedByteCount = 0;
    if (validDecodedShape &&
        decodedHeight <= UINT64_MAX / (uint64_t)bytesPerRow) {
        decodedByteCount = (uint64_t)bytesPerRow * decodedHeight;
    } else {
        validDecodedShape = NO;
    }
    BOOL statusesAreComplete =
        CGImageSourceGetStatus(source) == kCGImageStatusComplete &&
        CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete;
    if (!validDecodedShape || !statusesAreComplete) {
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorDecode,
            @"The decoded PNG shape, color model, alpha, or status is invalid.",
            nil);
    }
    if (decodedByteCount > limits.maximumFullResolutionDecodedBytes) {
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error,
            MTSafeImageDecoderErrorLimitExceeded,
            @"ImageIO's decoded row layout exceeds the full-resolution budget.",
            nil);
    }
    if (cancellationToken.isCancelled) {
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorCancelled,
            @"Image decode was cancelled after full-resolution validation.",
            nil);
    }

    uint32_t thumbnailWidth = 0;
    uint32_t thumbnailHeight = 0;
    if (!MTImageCalculateThumbnailDimensions(inspection.pixelWidth,
            inspection.pixelHeight, thumbnailMaximumDimension,
            &thumbnailWidth, &thumbnailHeight)) {
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorRender,
            @"Unable to calculate bounded thumbnail dimensions.", nil);
    }
    uint64_t thumbnailBytesPerRow = (uint64_t)thumbnailWidth * 4ULL;
    uint64_t thumbnailByteCount =
        thumbnailBytesPerRow * thumbnailHeight;
    if (thumbnailBytesPerRow > NSUIntegerMax ||
        thumbnailByteCount > NSUIntegerMax ||
        thumbnailByteCount > limits.maximumThumbnailBytes) {
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error,
            MTSafeImageDecoderErrorLimitExceeded,
            @"The normalized thumbnail exceeds its independent byte budget.",
            nil);
    }

    void *pixelBuffer = calloc(1, (size_t)thumbnailByteCount);
    CGColorSpaceRef outputColorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = pixelBuffer == NULL || outputColorSpace == NULL
        ? NULL
        : CGBitmapContextCreate(pixelBuffer, thumbnailWidth, thumbnailHeight,
            8, (size_t)thumbnailBytesPerRow, outputColorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context == NULL) {
        if (outputColorSpace != NULL) CGColorSpaceRelease(outputColorSpace);
        free(pixelBuffer);
        CGImageRelease(decodedImage);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorRender,
            @"Unable to allocate the bounded sRGB thumbnail surface.", nil);
    }

    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context,
        CGRectMake(0, 0, thumbnailWidth, thumbnailHeight), decodedImage);
    CGContextRelease(context);
    CGColorSpaceRelease(outputColorSpace);
    CGImageRelease(decodedImage);

    if (cancellationToken.isCancelled) {
        free(pixelBuffer);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorCancelled,
            @"Image decode was cancelled after thumbnail rendering.", nil);
    }
    if (CGImageSourceGetStatus(source) != kCGImageStatusComplete ||
        CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) {
        free(pixelBuffer);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorDecode,
            @"The PNG became incomplete while rendering its pixels.", nil);
    }

    NSData *thumbnailData = [NSData
        dataWithBytesNoCopy:pixelBuffer
                     length:(NSUInteger)thumbnailByteCount
               freeWhenDone:YES];
    if (thumbnailData == nil) {
        free(pixelBuffer);
        return MTImageDecoderFail(error, MTSafeImageDecoderErrorRender,
            @"Unable to own the normalized thumbnail buffer.", nil);
    }
    NSString *pixelDigest = MTSHA256HexDigestForData(thumbnailData);
    return [[MTSafeImageDecodeResult alloc]
        initWithInspection:inspection
        thumbnailPixelData:thumbnailData
        thumbnailPixelWidth:thumbnailWidth
        thumbnailPixelHeight:thumbnailHeight
        thumbnailBytesPerRow:(NSUInteger)thumbnailBytesPerRow
        fullResolutionDecodedByteCount:decodedByteCount
        pixelFormat:MTSafeImagePixelFormatRGBA8PremultipliedLast
        colorSpaceName:MTSafeImageColorSpaceSRGB
        thumbnailPixelSHA256:pixelDigest
        downsampled:thumbnailWidth != inspection.pixelWidth ||
            thumbnailHeight != inspection.pixelHeight];
}

@implementation MTSafeImageDecoder

+ (instancetype)defaultDecoder {
    return [[self alloc]
        initWithInspectionLimits:MTSafeImageLimits.defaultLimits
                     decodeLimits:MTSafeImageDecodeLimits.defaultLimits];
}

- (instancetype)initWithInspectionLimits:(MTSafeImageLimits *)inspectionLimits
                             decodeLimits:(MTSafeImageDecodeLimits *)decodeLimits {
    NSParameterAssert(inspectionLimits != nil);
    NSParameterAssert(decodeLimits != nil);
    self = [super init];
    if (self == nil) return nil;
    _inspectionLimits = inspectionLimits;
    _decodeLimits = decodeLimits;
    return self;
}

- (MTSafeImageDecodeResult *)
    decodeOwnedPNGFileAtURL:(NSURL *)fileURL
          thumbnailMaximumDimension:(uint32_t)thumbnailMaximumDimension
                  cancellationToken:
                      (MTImportCancellationToken *)cancellationToken
                               error:(NSError **)error {
    if (error != NULL) *error = nil;
    if (thumbnailMaximumDimension == 0 ||
        thumbnailMaximumDimension >
            self.decodeLimits.maximumThumbnailDimensionPixels) {
        return MTImageDecoderFail(error,
            MTSafeImageDecoderErrorInvalidRequest,
            @"The requested thumbnail dimension is outside decoder policy.",
            nil);
    }

    MTSafeImageLimits *processingLimits = [[MTSafeImageLimits alloc]
        initWithMaximumEncodedBytes:self.inspectionLimits.maximumEncodedBytes
             maximumDimensionPixels:MIN(
                 self.inspectionLimits.maximumDimensionPixels,
                 self.decodeLimits.maximumFullResolutionDimensionPixels)
                  maximumPixelCount:MIN(
                      self.inspectionLimits.maximumPixelCount,
                      self.decodeLimits.maximumFullResolutionPixelCount)
                maximumDecodedBytes:MIN(
                    self.inspectionLimits.maximumDecodedBytes,
                    self.decodeLimits.maximumFullResolutionDecodedBytes)
                   maximumChunkCount:self.inspectionLimits.maximumChunkCount
              maximumAncillaryBytes:
                  self.inspectionLimits.maximumAncillaryBytes];
    NSError *processingError = nil;
    MTSafeImageDecodeResult *result = MTSafeImageProcessOwnedPNGFile(
        fileURL, processingLimits, YES, cancellationToken,
        ^id _Nullable(CGImageSourceRef source,
                       MTSafeImageInspection *inspection,
                       NSError **consumerError) {
            return MTImageDecodeValidatedSource(source, inspection,
                self.decodeLimits, thumbnailMaximumDimension,
                cancellationToken, consumerError);
        }, &processingError);
    if (result == nil && error != NULL) {
        *error = MTImageDecoderMapValidationError(processingError);
    }
    return result;
}

@end
