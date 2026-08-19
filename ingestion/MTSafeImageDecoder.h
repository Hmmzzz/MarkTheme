#import <Foundation/Foundation.h>

@class MTImportCancellationToken;
@class MTSafeImageInspection;
@class MTSafeImageLimits;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSafeImageDecoderErrorDomain;
FOUNDATION_EXPORT NSString *const MTSafeImagePixelFormatRGBA8PremultipliedLast;
FOUNDATION_EXPORT NSString *const MTSafeImageColorSpaceSRGB;

typedef NS_ENUM(NSInteger, MTSafeImageDecoderErrorCode) {
    MTSafeImageDecoderErrorInvalidRequest = 1,
    MTSafeImageDecoderErrorSourceRejected = 2,
    MTSafeImageDecoderErrorLimitExceeded = 3,
    MTSafeImageDecoderErrorCancelled = 4,
    MTSafeImageDecoderErrorValidation = 5,
    MTSafeImageDecoderErrorDecode = 6,
    MTSafeImageDecoderErrorRender = 7,
};

// Decode ceilings are deliberately tighter than the metadata-admission
// limits. A file may be inspectable without being safe to decode or preview.
@interface MTSafeImageDecodeLimits : NSObject

@property(nonatomic, assign, readonly)
    uint32_t maximumFullResolutionDimensionPixels;
@property(nonatomic, assign, readonly)
    uint64_t maximumFullResolutionPixelCount;
@property(nonatomic, assign, readonly)
    uint64_t maximumFullResolutionDecodedBytes;
@property(nonatomic, assign, readonly)
    uint32_t maximumThumbnailDimensionPixels;
@property(nonatomic, assign, readonly) uint64_t maximumThumbnailBytes;

+ (instancetype)defaultLimits;
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
                             (uint64_t)maximumThumbnailBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Immutable normalized preview output. Full-resolution pixels are decoded and
// validated synchronously, then released. Only the bounded thumbnail buffer
// survives. Rows are top-to-bottom RGBA8 in sRGB with premultiplied alpha.
@interface MTSafeImageDecodeResult : NSObject

@property(nonatomic, strong, readonly) MTSafeImageInspection *inspection;
@property(nonatomic, copy, readonly) NSData *thumbnailPixelData;
@property(nonatomic, assign, readonly) uint32_t thumbnailPixelWidth;
@property(nonatomic, assign, readonly) uint32_t thumbnailPixelHeight;
@property(nonatomic, assign, readonly) NSUInteger thumbnailBytesPerRow;
@property(nonatomic, assign, readonly) uint64_t fullResolutionDecodedByteCount;
@property(nonatomic, copy, readonly) NSString *pixelFormat;
@property(nonatomic, copy, readonly) NSString *colorSpaceName;
@property(nonatomic, copy, readonly) NSString *thumbnailPixelSHA256;
@property(nonatomic, assign, readonly, getter=isDownsampled) BOOL downsampled;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTSafeImageDecoder : NSObject

@property(nonatomic, strong, readonly) MTSafeImageLimits *inspectionLimits;
@property(nonatomic, strong, readonly) MTSafeImageDecodeLimits *decodeLimits;

+ (instancetype)defaultDecoder;
- (instancetype)initWithInspectionLimits:(MTSafeImageLimits *)inspectionLimits
                             decodeLimits:(MTSafeImageDecodeLimits *)decodeLimits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The maximum thumbnail dimension is caller-selected but cannot exceed the
// decoder policy. Semantic @2x/@3x scale remains importer metadata; this API
// only emits deterministic pixel dimensions and bytes.
- (nullable MTSafeImageDecodeResult *)
    decodeOwnedPNGFileAtURL:(NSURL *)fileURL
          thumbnailMaximumDimension:(uint32_t)thumbnailMaximumDimension
                  cancellationToken:
                      (nullable MTImportCancellationToken *)cancellationToken
                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
