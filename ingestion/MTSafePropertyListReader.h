#import <Foundation/Foundation.h>

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSafePropertyListReaderErrorDomain;

typedef NS_ENUM(NSInteger, MTSafePropertyListReaderErrorCode) {
    MTSafePropertyListReaderErrorInvalidInput = 1,
    MTSafePropertyListReaderErrorLimitExceeded = 2,
    MTSafePropertyListReaderErrorMalformed = 3,
    MTSafePropertyListReaderErrorUnsupportedFormat = 4,
    MTSafePropertyListReaderErrorInvalidRoot = 5,
    MTSafePropertyListReaderErrorUnsupportedObject = 6,
    MTSafePropertyListReaderErrorCanonicalCollision = 7,
    MTSafePropertyListReaderErrorCancelled = 8,
};

// Format-specific limits layered below MTImportLimits. The earlier source or
// archive stage may be stricter, but this reader never widens its decision.
@interface MTSafePropertyListLimits : NSObject

@property(nonatomic, assign, readonly) NSUInteger maximumInputBytes;
@property(nonatomic, assign, readonly) NSUInteger maximumDepth;
@property(nonatomic, assign, readonly) NSUInteger maximumNodes;
@property(nonatomic, assign, readonly) NSUInteger maximumCollectionEntries;
@property(nonatomic, assign, readonly) NSUInteger maximumKeyUTF8Bytes;
@property(nonatomic, assign, readonly) NSUInteger maximumStringUTF8Bytes;
@property(nonatomic, assign, readonly) NSUInteger maximumDataBytes;
@property(nonatomic, assign, readonly) NSUInteger maximumAggregateScalarBytes;

+ (instancetype)defaultLimits;
- (instancetype)initWithMaximumInputBytes:(NSUInteger)maximumInputBytes
                             maximumDepth:(NSUInteger)maximumDepth
                             maximumNodes:(NSUInteger)maximumNodes
                 maximumCollectionEntries:(NSUInteger)maximumCollectionEntries
                       maximumKeyUTF8Bytes:(NSUInteger)maximumKeyUTF8Bytes
                    maximumStringUTF8Bytes:(NSUInteger)maximumStringUTF8Bytes
                            maximumDataBytes:(NSUInteger)maximumDataBytes
                 maximumAggregateScalarBytes:
                     (NSUInteger)maximumAggregateScalarBytes
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

// Immutable, normalized result. Dictionary keys and strings are NFC; mutable
// input collections/data never escape this boundary.
@interface MTSafePropertyListDocument : NSObject

@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *rootDictionary;
@property(nonatomic, assign, readonly) NSPropertyListFormat format;
@property(nonatomic, assign, readonly) NSUInteger nodeCount;
@property(nonatomic, assign, readonly) NSUInteger maximumObservedDepth;
@property(nonatomic, assign, readonly) NSUInteger aggregateScalarBytes;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTSafePropertyListReader : NSObject

@property(nonatomic, strong, readonly) MTSafePropertyListLimits *limits;

- (instancetype)initWithLimits:(MTSafePropertyListLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Only XML and binary property lists with a dictionary root are accepted.
// Cancellation is checked before/after Foundation parsing and during the
// bounded normalization walk; Foundation's individual parse call is atomic.
- (nullable MTSafePropertyListDocument *)
    readPropertyListData:(NSData *)data
       cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
