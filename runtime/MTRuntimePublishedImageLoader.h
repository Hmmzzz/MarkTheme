#import <Foundation/Foundation.h>

#import <CoreGraphics/CoreGraphics.h>

@class MTGeneration;
@class MTGenerationResource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimePublishedImageLoaderErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimePublishedImageLoaderErrorCode) {
    MTRuntimePublishedImageLoaderErrorInvalidRequest = 1,
    MTRuntimePublishedImageLoaderErrorResourceRejected = 2,
    MTRuntimePublishedImageLoaderErrorLimitExceeded = 3,
    MTRuntimePublishedImageLoaderErrorUnsupportedImage = 4,
    MTRuntimePublishedImageLoaderErrorDecode = 5,
};

typedef NS_ENUM(NSUInteger, MTRuntimePublishedImageResizePolicy) {
    MTRuntimePublishedImageResizePolicyExactOrDownsample = 0,
    // Legacy SnowBoard Clock faces commonly ship only the 2x 120px canvas.
    // This policy admits exactly 2x -> 3x at the same aspect ratio; it is not
    // a general image-upscaling escape hatch.
    MTRuntimePublishedImageResizePolicyLegacyTwoToThreeUpscale = 1,
    // SnowBoard-compatible application/UI source normalization. The caller's
    // target is already bounded by its surface contract and decode budget, so
    // a smaller or differently sized authored PNG may be rendered into that
    // exact canvas without admitting an unbounded allocation.
    MTRuntimePublishedImageResizePolicyBoundedScaleToFill = 2,
};

@interface MTRuntimeDecodedImage : NSObject

@property(nonatomic, assign, readonly) CGImageRef image;
@property(nonatomic, assign, readonly) uint32_t pixelWidth;
@property(nonatomic, assign, readonly) uint32_t pixelHeight;
@property(nonatomic, assign, readonly) NSUInteger decodedByteCost;
@property(nonatomic, assign, readonly) NSUInteger residentCost;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end


// Synchronous immutable-asset verifier/decoder. ModuleRuntime must call this
// only on its background decode queue; the ProcessAdapter never imports it.
// Exact-size PNGs decode directly. Larger same-aspect PNGs use ImageIO's
// bounded thumbnail path; a legacy square canvas whose encoded edges differ
// by one pixel is downsampled and center-cropped. Neither path allocates the
// full source raster in the injected process.
@interface MTRuntimePublishedImageLoader : NSObject

@property(nonatomic, assign, readonly) uint64_t maximumEncodedByteCount;
@property(nonatomic, assign, readonly) uint64_t maximumDecodedByteCount;

+ (instancetype)staticIconLoader;
- (instancetype)initWithMaximumEncodedByteCount:
    (uint64_t)maximumEncodedByteCount
                    maximumDecodedByteCount:
                        (uint64_t)maximumDecodedByteCount
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTRuntimeDecodedImage *)
    loadImageForGeneration:(MTGeneration *)generation
                  resource:(MTGenerationResource *)resource
          targetPixelWidth:(uint32_t)targetPixelWidth
         targetPixelHeight:(uint32_t)targetPixelHeight
                     error:(NSError **)error;

- (nullable MTRuntimeDecodedImage *)
    loadImageForGeneration:(MTGeneration *)generation
                  resource:(MTGenerationResource *)resource
          targetPixelWidth:(uint32_t)targetPixelWidth
         targetPixelHeight:(uint32_t)targetPixelHeight
              resizePolicy:(MTRuntimePublishedImageResizePolicy)resizePolicy
                     error:(NSError **)error;

// Decodes one bounded single-frame PNG at its authored pixel dimensions.
// This is intended for small legacy canvases whose dimensions are semantic
// (for example a 29x20 status-bar level) and must not be normalized. The same
// encoded/decoded limits and immutable Generation verification still apply.
- (nullable MTRuntimeDecodedImage *)
    loadImagePreservingSourceDimensionsForGeneration:
        (MTGeneration *)generation
                                          resource:
        (MTGenerationResource *)resource
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
