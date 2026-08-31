#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceStoreInvalidatorErrorDomain;

typedef struct MTIconServiceStoreInvalidatorObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) installed;
    _Atomic(uint64_t) capturedServices;
    _Atomic(uint64_t) transactions;
    _Atomic(uint64_t) verifiedTransactions;
    _Atomic(uint64_t) failedTransactions;
} MTIconServiceStoreInvalidatorObservation;

FOUNDATION_EXPORT MTIconServiceStoreInvalidatorObservation
    MTIconServiceStoreInvalidatorRuntimeObservation;

@interface MTIconServiceStoreInvalidationResult : NSObject

@property(nonatomic, assign, readonly, getter=isVerified) BOOL verified;
@property(nonatomic, copy, readonly) NSString *outcome;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^MTIconServiceStoreInvalidationCompletion)(
    MTIconServiceStoreInvalidationResult *result);
typedef void (^MTIconServiceStoreAvailabilityHandler)(void);

@interface MTIconServiceStoreInvalidator : NSObject

// Transaction readiness is stricter than Hook installation: the daemon's
// concrete IconCacheService must have completed initialization and exposed its
// native cache owner. The bootstrap publishes Ready only after this becomes
// true, closing the cold-service Apply race.
@property(nonatomic, assign, readonly, getter=isServiceAvailable)
    BOOL serviceAvailable;

// Installs two cache-control pass-through Hooks. The first captures the
// daemon's cache owner at IconCacheService initialization. The second observes
// successful return from Apple's exact type-2 ClearCacheOperation so an
// asynchronously scheduled whole-cache transaction can be acknowledged
// without a timing guess. Neither Hook changes an argument, return value,
// cache object, operation, or image.
- (BOOL)installWithError:(NSError **)error;

// Retains one process-lifetime handler and invokes it outside the internal
// lock whenever a live service owner is captured. Setting the handler after a
// capture invokes it immediately.
- (void)setServiceAvailabilityHandler:
    (nullable MTIconServiceStoreAvailabilityHandler)handler;

// Shipping correctness baseline for a global theme-state transition. The
// daemon schedules its native type-2 cache operation and acknowledges only
// after the exact ClearCacheOperation run returns normally. MarkTheme never
// records or mutates StoreIndex mappings, deletes StoreUnit files, or touches
// the LaunchServices registration database.
- (void)invalidateWholeStoreWithCompletion:
    (MTIconServiceStoreInvalidationCompletion)completion;

@end

NS_ASSUME_NONNULL_END
