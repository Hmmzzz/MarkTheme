#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconServiceStoreInvalidatorErrorDomain;

typedef NS_ENUM(NSUInteger, MTIconServiceDigestCoverage) {
    MTIconServiceDigestCoverageIncomplete = 0,
    MTIconServiceDigestCoverageAuthoritative = 1,
};

@interface MTIconServiceStoreInvalidationResult : NSObject

@property(nonatomic, assign, readonly, getter=isVerified) BOOL verified;
@property(nonatomic, assign, readonly) BOOL requiresBroadFallback;
@property(nonatomic, assign, readonly) NSUInteger bundleCount;
@property(nonatomic, assign, readonly) NSUInteger digestCount;
@property(nonatomic, assign, readonly) NSUInteger removedValueCount;
@property(nonatomic, copy, readonly) NSString *outcome;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

typedef void (^MTIconServiceStoreInvalidationCompletion)(
    MTIconServiceStoreInvalidationResult *result);

@interface MTIconServiceStoreInvalidator : NSObject

// Installs one service-control pass-through Hook. It observes only requests
// that have already completed Apple's generation/registration transaction.
- (BOOL)installWithError:(NSError **)error;

- (NSDictionary<NSString *, NSSet<NSUUID *> *> *)observedDigestsByBundle;

// Narrow mutation is impossible unless the caller has independently proven
// that every semantic icon identity for every requested bundle is present.
// Incomplete coverage performs no mutation and requires the broad fallback.
- (void)invalidateBundleIdentifiers:(NSSet<NSString *> *)bundleIdentifiers
                           coverage:(MTIconServiceDigestCoverage)coverage
                         completion:
    (MTIconServiceStoreInvalidationCompletion)completion;

@end

NS_ASSUME_NONNULL_END
