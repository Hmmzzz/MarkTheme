#import <Foundation/Foundation.h>

@class MTGenerationDescriptor;
@class MTGenerationIndex;
@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTGenerationReaderErrorDomain;

typedef NS_ENUM(NSInteger, MTGenerationReaderErrorCode) {
    MTGenerationReaderErrorInvalidRequest = 1,
    MTGenerationReaderErrorNotFound = 2,
    MTGenerationReaderErrorStorage = 3,
    MTGenerationReaderErrorVerification = 4,
    MTGenerationReaderErrorCancelled = 5,
    MTGenerationReaderErrorLimitExceeded = 6,
};

typedef NS_ENUM(NSUInteger, MTGenerationReaderOwnershipProfile) {
    // App/Helper-owned unpublished compiler or PublishInbox tree.
    MTGenerationReaderOwnershipProfilePrivate = 1,
    // Root-owned Runtime tree shared read-only with injected processes.
    MTGenerationReaderOwnershipProfilePublished = 2,
};

// Read-only admission policy for one private compiler root or root-owned
// published Runtime root. The byte limit covers the complete Generation.
@interface MTGenerationReaderConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *rootURL;
@property(nonatomic, assign, readonly) NSUInteger maximumAssetCount;
@property(nonatomic, assign, readonly) uint64_t maximumGenerationByteCount;
@property(nonatomic, assign, readonly)
    MTGenerationReaderOwnershipProfile ownershipProfile;

+ (instancetype)defaultConfiguration;

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
                ownershipProfile:
                    (MTGenerationReaderOwnershipProfile)ownershipProfile
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

// One lookup result from the validated immutable index. assetURL is a
// generation-relative locator that was fully verified during this read; a
// future injected Runtime consumer must still open it without following
// links rather than treating NSURL as an authorization token.
@interface MTGenerationResource : NSObject

@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;
@property(nonatomic, copy, readonly) NSURL *assetURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end


// Immutable, independently validated view of one complete final tree. The
// index retains its encoded bytes and performs direct binary-search lookup;
// this object does not construct a resource dictionary.
@interface MTGeneration : NSObject

@property(nonatomic, strong, readonly) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readonly) MTGenerationIndex *index;
@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSURL *generationURL;

// A valid canonical miss returns nil without setting error.
- (nullable MTGenerationResource *)resourceForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                               error:
    (NSError **)error;

// Reopens one indexed asset relative to the directory descriptor retained by
// this validated Generation, verifies exact metadata/bytes/digest, and returns
// an immutable copy. The caller supplies its narrower per-resource budget.
- (nullable NSData *)verifiedAssetDataForResource:
    (MTGenerationResource *)resource
                              maximumByteCount:(uint64_t)maximumByteCount
                                           error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end


@interface MTGenerationReader : NSObject

@property(nonatomic, strong, readonly)
    MTGenerationReaderConfiguration *configuration;

+ (instancetype)defaultReader;
- (instancetype)initWithConfiguration:
    (MTGenerationReaderConfiguration *)configuration
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Opens an already-published final tree read-only. It never creates, repairs,
// removes, locks, publishes, activates, or writes any store node.
- (nullable MTGeneration *)readGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                       cancellationToken:
    (nullable MTImportCancellationToken *)cancellationToken
                                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
