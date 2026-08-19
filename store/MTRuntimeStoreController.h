#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTImportCancellationToken;
@class MTRuntimeState;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeStoreErrorDomain;

typedef NS_ENUM(NSInteger, MTRuntimeStoreErrorCode) {
    MTRuntimeStoreErrorInvalidRequest = 1,
    MTRuntimeStoreErrorStorage = 2,
    MTRuntimeStoreErrorBusy = 3,
    MTRuntimeStoreErrorNotFound = 4,
    MTRuntimeStoreErrorVerification = 5,
    MTRuntimeStoreErrorCancelled = 6,
    MTRuntimeStoreErrorInsufficientSpace = 7,
};

@interface MTRuntimePublishResult : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSURL *generationURL;
@property(nonatomic, assign, readonly) BOOL reusedExistingGeneration;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Root-side writer/control facade. The short-lived fixed-operation Helper owns
// this object; Manager and injected Runtime use separate client/read APIs.
@interface MTRuntimeStoreController : NSObject

@property(nonatomic, copy, readonly) NSURL *runtimeRootURL;
@property(nonatomic, assign, readonly)
    uint64_t minimumFreeSpaceReserveBytes;

+ (nullable instancetype)defaultControllerWithError:(NSError **)error;
- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL;
- (instancetype)initWithRuntimeRootURL:(NSURL *)runtimeRootURL
          minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTRuntimePublishResult *)publishGeneration:
    (MTGeneration *)generation
                                               cancellationToken:
    (nullable MTImportCancellationToken *)cancellationToken
                                                        error:(NSError **)error;

- (nullable MTRuntimeState *)currentStateWithError:(NSError **)error;
- (nullable MTRuntimeState *)activateGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                         error:(NSError **)error;
- (nullable MTRuntimeState *)rollbackWithError:(NSError **)error;
- (nullable MTRuntimeState *)disableWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
