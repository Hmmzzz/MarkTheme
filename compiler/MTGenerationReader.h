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

typedef NS_ENUM(NSUInteger, MTGenerationReaderValidationPolicy) {
    // Mutable or not-yet-published input. Every asset is hashed while the
    // Generation is admitted and again whenever its bytes are requested.
    MTGenerationReaderValidationPolicyStrict = 1,
    // A root-owned final tree that already passed strict publication. Runtime
    // validates descriptor/index structure, then performs bounded no-follow
    // reads without rescanning or rehashing the complete asset set.
    MTGenerationReaderValidationPolicyTrustedPublished = 2,
};

// Read-only admission policy for one private compiler root or root-owned
// published Runtime root. The byte limit covers the complete Generation.
@interface MTGenerationReaderConfiguration : NSObject

@property(nonatomic, copy, readonly) NSURL *rootURL;
@property(nonatomic, assign, readonly) NSUInteger maximumAssetCount;
@property(nonatomic, assign, readonly) uint64_t maximumGenerationByteCount;
@property(nonatomic, assign, readonly)
    MTGenerationReaderOwnershipProfile ownershipProfile;
@property(nonatomic, assign, readonly)
    MTGenerationReaderValidationPolicy validationPolicy;

+ (instancetype)defaultConfiguration;

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
                ownershipProfile:
                    (MTGenerationReaderOwnershipProfile)ownershipProfile;

- (instancetype)initWithRootURL:(NSURL *)rootURL
              maximumAssetCount:(NSUInteger)maximumAssetCount
      maximumGenerationByteCount:(uint64_t)maximumGenerationByteCount
                ownershipProfile:
                    (MTGenerationReaderOwnershipProfile)ownershipProfile
                validationPolicy:
                    (MTGenerationReaderValidationPolicy)validationPolicy
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

// One lookup result from the validated immutable index. assetURL is a
// generation-relative locator, not an authorization token; asset bytes are
// always opened through the retained no-follow directory descriptor.
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

// Reads one indexed asset relative to the directory descriptor retained by
// this Generation and returns an immutable copy. Strict readers revalidate
// digest/stability; trusted published readers rely on the completed publication
// boundary and retain only bounded no-follow file/type/length checks.
- (nullable NSData *)assetDataForResource:
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
