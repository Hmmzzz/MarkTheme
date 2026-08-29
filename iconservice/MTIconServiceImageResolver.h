#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceImageResolverErrorDomain;

typedef MTRuntimeSnapshot * _Nonnull (^MTIconServiceSnapshotProvider)(void);

@interface MTIconServiceImageResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTIconServiceSnapshotProvider)snapshotProvider
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)reset;

// Returns a retained exact-size CGImage only when current immutable Generation
// data changes the stock result. A normal theme miss returns NULL with no error.
- (CGImageRef _Nullable)
    copyReplacementForBundleIdentifier:(NSString *)bundleIdentifier
                             pointSize:(CGSize)pointSize
                                 scale:(double)scale
                            pixelWidth:(uint32_t)pixelWidth
                           pixelHeight:(uint32_t)pixelHeight
                       stockImageDigest:(NSString *)stockImageDigest
                        stockCGImage:(CGImageRef)stockCGImage
                                 error:(NSError **)error CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
