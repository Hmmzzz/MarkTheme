#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTGenerationIndexErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTGenerationIndexFormatVersion;
FOUNDATION_EXPORT NSUInteger const MTGenerationIndexMaximumRecordCount;
FOUNDATION_EXPORT uint64_t const MTGenerationIndexMaximumByteCount;

typedef NS_ENUM(NSInteger, MTGenerationIndexErrorCode) {
    MTGenerationIndexErrorInvalidRecord = 1,
    MTGenerationIndexErrorLimitExceeded = 2,
    MTGenerationIndexErrorMalformedData = 3,
    MTGenerationIndexErrorUnsupportedVersion = 4,
};

// Immutable logical record. The resource key is the exact MTResourceKey
// canonical string; the digest names the immutable generation asset.
@interface MTGenerationIndexRecord : NSObject

@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, copy, readonly) NSString *contentSHA256;
@property(nonatomic, assign, readonly) uint64_t assetByteCount;

- (nullable instancetype)initWithCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                      contentSHA256:(NSString *)contentSHA256
                                      assetByteCount:(uint64_t)assetByteCount
                                               error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

// Validates the complete fixed-layout byte format once, then performs lookup
// directly against the immutable bytes with binary search. It intentionally
// does not build a resource-key dictionary.
@interface MTGenerationIndex : NSObject

@property(nonatomic, copy, readonly) NSData *encodedData;
@property(nonatomic, assign, readonly) NSUInteger recordCount;

+ (nullable NSData *)encodedDataWithRecords:
    (NSArray<MTGenerationIndexRecord *> *)records
                                      error:(NSError **)error;

- (nullable instancetype)initWithEncodedData:(NSData *)encodedData
                                        error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (nullable MTGenerationIndexRecord *)recordAtIndex:(NSUInteger)index;

// A valid canonical miss returns nil without setting error. A malformed query
// is rejected so callers cannot create an alternate key encoding.
- (nullable MTGenerationIndexRecord *)recordForCanonicalResourceKey:
    (NSString *)canonicalResourceKey
                                                               error:
    (NSError **)error;

// Performs one lower-bound lookup directly against the validated encoded key
// table without constructing record objects. Runtime preflight uses a
// component-boundary prefix to determine whether a themed subject can resolve
// before constructing every scale/variant candidate. A valid miss returns NO
// without setting error.
- (BOOL)containsRecordWithCanonicalResourceKeyPrefix:(NSString *)prefix
                                                error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
