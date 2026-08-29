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

// Publishes the digest of only application-icon source modules. Unrelated
// Generation changes retain warm composites; a relevant change atomically
// advances the cache namespace and purges the old one.
- (BOOL)updateSourceFingerprint:(NSString *)sourceFingerprint;

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
