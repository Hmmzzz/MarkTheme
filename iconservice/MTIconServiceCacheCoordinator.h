#import <Foundation/Foundation.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

// Hashes only resources/configuration that can affect the service pixel source.
// Unknown or malformed inputs return nil, requiring conservative invalidation.
FOUNDATION_EXPORT NSString * _Nullable MTIconServicePixelDependencyFingerprint(
    MTRuntimeSnapshot *snapshot, NSError **error);

typedef void (^MTIconServiceCacheInvalidation)(void (^completion)(BOOL verified));
typedef void (^MTIconServiceCacheAcknowledgement)(
    uint64_t sequence, BOOL verified, BOOL skipped);

// Serializes native clears. Consecutive equal pixel dependencies share one
// in-flight operation, and acknowledgement follows successful native completion.
// A failed clear never publishes a completed fingerprint, so a later retry can
// recover. This class performs no device/private API work itself.
@interface MTIconServiceCacheCoordinator : NSObject
- (instancetype)initWithInvalidation:(MTIconServiceCacheInvalidation)invalidation
                      acknowledgement:(MTIconServiceCacheAcknowledgement)acknowledgement;
- (void)acceptFingerprint:(NSString *)fingerprint sequence:(uint64_t)sequence;
@end

NS_ASSUME_NONNULL_END
