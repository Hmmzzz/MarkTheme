#import <Foundation/Foundation.h>

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSafeImageInspectorErrorDomain;

typedef NS_ENUM(NSInteger, MTSafeImageInspectorErrorCode) {
    MTSafeImageInspectorErrorInvalidRequest = 1,
    MTSafeImageInspectorErrorUnsafeSource = 2,
    MTSafeImageInspectorErrorLimitExceeded = 3,
    MTSafeImageInspectorErrorCancelled = 4,
    MTSafeImageInspectorErrorSourceChanged = 5,
    MTSafeImageInspectorErrorUnsupportedFormat = 6,
    MTSafeImageInspectorErrorCorruptData = 7,
    MTSafeImageInspectorErrorAnimatedImage = 8,
    MTSafeImageInspectorErrorImageIO = 9,
    MTSafeImageInspectorErrorIO = 10,
    MTSafeImageInspectorErrorCorruptPixelData = 11,
};

// Image-specific ceilings applied after the shared source/archive policy.
// Callers may tighten these values, but asset adoption must not widen them.
@interface MTSafeImageLimits : NSObject

@property(nonatomic, assign, readonly) uint64_t maximumEncodedBytes;
@property(nonatomic, assign, readonly) uint32_t maximumDimensionPixels;
@property(nonatomic, assign, readonly) uint64_t maximumPixelCount;
@property(nonatomic, assign, readonly) uint64_t maximumDecodedBytes;
@property(nonatomic, assign, readonly) NSUInteger maximumChunkCount;
@property(nonatomic, assign, readonly) uint64_t maximumAncillaryBytes;

+ (instancetype)defaultLimits;
- (instancetype)initWithMaximumEncodedBytes:(uint64_t)maximumEncodedBytes
                     maximumDimensionPixels:(uint32_t)maximumDimensionPixels
                          maximumPixelCount:(uint64_t)maximumPixelCount
                        maximumDecodedBytes:(uint64_t)maximumDecodedBytes
                           maximumChunkCount:(NSUInteger)maximumChunkCount
                      maximumAncillaryBytes:(uint64_t)maximumAncillaryBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Immutable, data-only inspection result. No CGImage, UIImage, decoded pixel
// buffer, source URL, or source bytes escape this boundary.
@interface MTSafeImageInspection : NSObject

@property(nonatomic, copy, readonly) NSString *typeIdentifier;
@property(nonatomic, assign, readonly) uint64_t encodedByteCount;
@property(nonatomic, assign, readonly) uint32_t pixelWidth;
@property(nonatomic, assign, readonly) uint32_t pixelHeight;
@property(nonatomic, assign, readonly) uint64_t pixelCount;
@property(nonatomic, assign, readonly) uint64_t decodedByteEstimate;
@property(nonatomic, assign, readonly) NSUInteger frameCount;
@property(nonatomic, assign, readonly) BOOL hasAlpha;
@property(nonatomic, assign, readonly) NSUInteger orientation;
@property(nonatomic, assign, readonly) uint8_t bitDepth;
@property(nonatomic, assign, readonly) uint8_t colorType;
@property(nonatomic, assign, readonly, getter=isInterlaced) BOOL interlaced;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTSafeImageInspector : NSObject

@property(nonatomic, strong, readonly) MTSafeImageLimits *limits;

+ (instancetype)defaultInspector;
- (instancetype)initWithLimits:(MTSafeImageLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Inspects one app-owned staging file. The final path is opened O_NOFOLLOW;
// the file must be regular, single-link, non-executable, non-shared-writable,
// owned by the current process, and unchanged for the complete inspection.
//
// M1-B intentionally admits only static, <= 8-bit PNG. PNG structure and CRC
// are validated before ImageIO sees the descriptor; ImageIO is then used only
// for non-caching metadata/property cross-checks. Pixel decode is a later,
// separately budgeted stage.
- (nullable MTSafeImageInspection *)
    inspectOwnedPNGFileAtURL:(NSURL *)fileURL
          cancellationToken:
              (nullable MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
