#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"
#import "MTImportLimits.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSafeZIPArchiveReaderErrorDomain;

typedef NS_ENUM(NSInteger, MTSafeZIPArchiveReaderErrorCode) {
    MTSafeZIPArchiveReaderErrorInvalidInput = 1,
    MTSafeZIPArchiveReaderErrorUnsupportedFeature = 2,
    MTSafeZIPArchiveReaderErrorUnsafePath = 3,
    MTSafeZIPArchiveReaderErrorUnsupportedNode = 4,
    MTSafeZIPArchiveReaderErrorLimitExceeded = 5,
    MTSafeZIPArchiveReaderErrorCanonicalCollision = 6,
    MTSafeZIPArchiveReaderErrorNestedArchive = 7,
    MTSafeZIPArchiveReaderErrorCancelled = 8,
    MTSafeZIPArchiveReaderErrorCorruptArchive = 9,
    MTSafeZIPArchiveReaderErrorIO = 10,
};

// Result of a complete two-pass audit. No archive-controlled pathname is ever
// materialized. Expanded bytes are streamed only through prefix/hash sinks.
@interface MTSafeZIPArchiveScan : NSObject <MTAuditedSource>

@property(nonatomic, strong, readonly) MTSourceInventory *inventory;
@property(nonatomic, assign, readonly) NSUInteger archiveEntryCount;
@property(nonatomic, assign, readonly) uint64_t totalCompressedBytes;

@end

@interface MTSafeZIPArchiveReader : NSObject

@property(nonatomic, strong, readonly) MTImportLimits *limits;

- (instancetype)initWithLimits:(MTImportLimits *)limits
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The caller should pass MTImportSession.payloadURL. The reader nevertheless
// opens with O_NOFOLLOW and verifies identity before/after both audit passes.
- (nullable MTSafeZIPArchiveScan *)
    scanArchiveAtURL:(NSURL *)archiveURL
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
