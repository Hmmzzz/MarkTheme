#import <Foundation/Foundation.h>

#import "MTAuditedSource.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint16_t, MTAuditedZIPCompressionMethod) {
    MTAuditedZIPCompressionMethodStored = 0,
    MTAuditedZIPCompressionMethodDeflate = 8,
};

// Internal random-access primitive for one entry from an already preflighted
// and fully audited ZIP. The caller owns the descriptor and must verify its
// source identity before and after this call.
FOUNDATION_EXPORT BOOL MTAuditedZIPStreamEntry(
    int descriptor,
    NSString *relativePath,
    MTAuditedZIPCompressionMethod compressionMethod,
    uint32_t expectedCRC32,
    uint64_t compressedByteCount,
    uint64_t expandedByteCount,
    uint64_t compressedDataOffset,
    NSString *expectedSHA256,
    uint64_t maximumByteCount,
    MTImportCancellationToken *_Nullable cancellationToken,
    MTAuditedSourceByteConsumer byteConsumer,
    NSError **error);

NS_ASSUME_NONNULL_END
