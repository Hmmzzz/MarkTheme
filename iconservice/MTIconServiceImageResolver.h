#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceImageResolverErrorDomain;

typedef MTRuntimeSnapshot * _Nonnull (^MTIconServiceSnapshotProvider)(void);

// Process-local counters for the composite cache. A miss that resolves to the
// stock appearance is the common case for unthemed applications, so it is
// recorded and cached exactly like a composed hit.
typedef struct MTIconServiceImageResolverObservation {
    uint32_t schemaVersion;
    _Atomic(uint64_t) lookupCalls;
    _Atomic(uint64_t) compositeHits;
    _Atomic(uint64_t) stockHits;
    _Atomic(uint64_t) compositeStores;
    _Atomic(uint64_t) stockStores;
    _Atomic(uint64_t) systemMaskHits;
    _Atomic(uint64_t) systemMaskRenders;
} MTIconServiceImageResolverObservation;

FOUNDATION_EXPORT MTIconServiceImageResolverObservation
    MTRuntimeIconServiceImageResolverObservation;

typedef NS_ENUM(NSUInteger, MTIconServiceDynamicCategoryPolicy) {
    // The persistent IconServices source must never freeze Calendar or Clock.
    MTIconServiceDynamicCategoryPolicyExclude = 0,
    // A secondary semantic cache may retain Apple's current dynamic pixels
    // while applying only the active custom mask and/or overlay.
    MTIconServiceDynamicCategoryPolicyPreserveStockSource = 1,
};

@interface MTIconServiceImageResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTIconServiceSnapshotProvider)snapshotProvider;
- (instancetype)initWithSnapshotProvider:
    (MTIconServiceSnapshotProvider)snapshotProvider
                dynamicCategoryPolicy:
                    (MTIconServiceDynamicCategoryPolicy)dynamicCategoryPolicy
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
