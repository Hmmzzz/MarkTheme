#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTRuntimeSnapshot;
@class MTRuntimeState;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeSnapshotLoaderErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimeSnapshotLoaderErrorCode) {
    MTRuntimeSnapshotLoaderErrorLoadFailed = 1,
    MTRuntimeSnapshotLoaderErrorStateChanged = 2,
};

@protocol MTRuntimeSnapshotLoading <NSObject>
- (nullable MTRuntimeSnapshot *)loadSnapshotWithError:(NSError **)error;
@end

// Read-only Runtime data plane. It owns no writer/controller dependency and
// performs no hook or process injection.
@interface MTRuntimeSnapshotLoader : NSObject <MTRuntimeSnapshotLoading>

@property(nonatomic, copy, readonly) NSURL *runtimeRootURL;

+ (nullable instancetype)defaultLoaderWithError:(NSError **)error;
- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Enabled state is read again after full Generation validation. A concurrent
// state change rejects the stale candidate rather than publishing it.
- (nullable MTRuntimeSnapshot *)loadSnapshotWithError:(NSError **)error;

// Disabled is a valid state: nil is returned without an error. If requested,
// state receives the exact state snapshot used for the decision.
- (nullable MTGeneration *)loadActiveGenerationWithState:
    (MTRuntimeState * _Nullable * _Nullable)state
                                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
