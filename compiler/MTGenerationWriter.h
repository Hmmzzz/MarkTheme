#import <Foundation/Foundation.h>

@class MTCompiledGeneration;
@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTGenerationWriterErrorDomain;

typedef NS_ENUM(NSInteger, MTGenerationWriterErrorCode) {
    MTGenerationWriterErrorInvalidRequest = 1,
    MTGenerationWriterErrorStorage = 2,
    MTGenerationWriterErrorVerification = 3,
    MTGenerationWriterErrorBusy = 4,
    MTGenerationWriterErrorCancelled = 5,
    MTGenerationWriterErrorLimitExceeded = 6,
    MTGenerationWriterErrorInsufficientSpace = 7,
    MTGenerationWriterErrorRecovery = 8,
};

// Immutable policy for the App-owned compiler store. The logical byte limit
// covers index.mtg, generation.json, and every unique asset. The free-space
// reserve is admission policy rather than a guarantee that later writes work.
@interface MTGenerationWriterConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *rootURL;
@property(nonatomic, assign, readonly) NSUInteger maximumAssetCount;
@property(nonatomic, assign, readonly) uint64_t maximumGenerationByteCount;
@property(nonatomic, assign, readonly) uint64_t minimumFreeSpaceReserveBytes;
@property(nonatomic, assign, readonly) NSUInteger maximumRecoveryNodeCount;

+ (instancetype)defaultConfiguration;

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
    minimumFreeSpaceReserveBytes:(uint64_t)minimumFreeSpaceReserveBytes
        maximumRecoveryNodeCount:(NSUInteger)maximumRecoveryNodeCount
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

// A successful result identifies a complete immutable tree. Asset copy counts
// describe only this invocation and are zero for an idempotently reused tree.
@interface MTGenerationWriteResult : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSURL *generationURL;
@property(nonatomic, assign, readonly) BOOL reusedExistingGeneration;
@property(nonatomic, assign, readonly) NSUInteger clonedAssetCount;
@property(nonatomic, assign, readonly) NSUInteger streamedAssetCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTGenerationWriter : NSObject

@property(nonatomic, strong, readonly)
    MTGenerationWriterConfiguration *configuration;

+ (instancetype)defaultWriter;
- (instancetype)initWithConfiguration:
    (MTGenerationWriterConfiguration *)configuration
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Revalidates the pure compiler output, acquires the store lock, performs
// bounded transaction recovery, and publishes one complete generation tree.
- (nullable MTGenerationWriteResult *)writeCompiledGeneration:
    (MTCompiledGeneration *)compiledGeneration
                                          cancellationToken:
    (nullable MTImportCancellationToken *)cancellationToken
                                                   error:(NSError **)error;

// App startup may call this explicitly. The write path always calls it while
// holding the same exclusive lock before inspecting or creating a generation.
- (BOOL)recoverAbandonedTransactionsWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
