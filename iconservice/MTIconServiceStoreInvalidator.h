#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceStoreInvalidatorErrorDomain;

@class MTIconServiceRequestContext;

typedef struct MTIconServiceStoreInvalidatorObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) capturedServices;
    _Atomic(uint64_t) recordedMappings;
    _Atomic(uint64_t) transactions;
    _Atomic(uint64_t) verifiedTransactions;
    _Atomic(uint64_t) broadFallbacks;
    _Atomic(uint64_t) removedMappings;
} MTIconServiceStoreInvalidatorObservation;

FOUNDATION_EXPORT MTIconServiceStoreInvalidatorObservation
    MTIconServiceStoreInvalidatorRuntimeObservation;

typedef NS_ENUM(NSUInteger, MTIconServiceDigestCoverage) {
    MTIconServiceDigestCoverageIncomplete = 0,
    MTIconServiceDigestCoverageAuthoritative = 1,
};

@interface MTIconServiceStoreInvalidationResult : NSObject

@property(nonatomic, assign, readonly, getter=isVerified) BOOL verified;
@property(nonatomic, assign, readonly) BOOL requiresBroadFallback;
@property(nonatomic, assign, readonly) NSUInteger bundleCount;
@property(nonatomic, assign, readonly) NSUInteger digestCount;
@property(nonatomic, assign, readonly) NSUInteger mappingCount;
@property(nonatomic, assign, readonly) NSUInteger removedValueCount;
@property(nonatomic, copy, readonly) NSString *outcome;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^MTIconServiceStoreInvalidationCompletion)(
    MTIconServiceStoreInvalidationResult *result);

@interface MTIconServiceStoreInvalidator : NSObject

// Installs one service-lifecycle pass-through Hook. It captures the daemon's
// cache owner once at IconCacheService initialization; it does not Hook any
// per-image service request.
- (BOOL)installWithError:(NSError **)error;

- (NSDictionary<NSString *, NSSet<NSUUID *> *> *)observedDigestsByBundle;

// Narrow mutation is impossible unless the caller has independently proven
// that every cache mapping for every requested bundle is present. Each
// recorded mapping is matched by icon digest + descriptor digest + StoreUnit
// UUID; the predicate never removes the rest of that icon-digest family.
// Incomplete coverage performs no mutation and requires the broad fallback.
- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion;

// Canary/device-proof path: removes only completed mappings that match this
// exact semantic request identity. It never implies whole-bundle coverage.
- (void)invalidateObservedMappingsForBundleIdentifier:
    (NSString *)bundleIdentifier
                                             iconDigest:(NSUUID *)iconDigest
                                       descriptorDigest:
    (NSUUID *)descriptorDigest
                                              completion:
    (MTIconServiceStoreInvalidationCompletion)completion;

@end

// Called only after the source adapter has produced a replacement. The source
// request itself is the authoritative mapping identity; StoreIndex mutation
// later resolves and verifies the current StoreUnit UUID on Apple's queue.
FOUNDATION_EXPORT void
MTIconServiceStoreInvalidatorRecordGeneratedContext(
    MTIconServiceRequestContext *_Nullable context);

NS_ASSUME_NONNULL_END
