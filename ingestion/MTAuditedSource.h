#import <Foundation/Foundation.h>

#import "MTSourceInventory.h"

@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTAuditedSourceErrorDomain;

typedef NS_ENUM(NSInteger, MTAuditedSourceErrorCode) {
    MTAuditedSourceErrorInvalidRequest = 1,
    MTAuditedSourceErrorNotInventoried = 2,
    MTAuditedSourceErrorLimitExceeded = 3,
    MTAuditedSourceErrorCancelled = 4,
    MTAuditedSourceErrorSourceChanged = 5,
    MTAuditedSourceErrorCorruptSource = 6,
    MTAuditedSourceErrorIO = 7,
};

// Called synchronously with one bounded chunk at a time. The byte pointer is
// valid only for the duration of the call. Returning YES promises that the
// complete chunk was consumed; returning NO stops the source immediately and
// should provide an error. Bytes are provisional until the enclosing stream
// method succeeds, so consumers must be able to roll back partial output.
typedef BOOL (^MTAuditedSourceByteConsumer)(
    const void *bytes,
    NSUInteger length,
    NSError **error);

// Container-neutral, read-only access to bytes that were already admitted by
// a complete source audit. Implementations must reject paths absent from the
// immutable inventory and must revalidate source identity, exact byte count,
// and SHA-256 before reporting success.
//
// The byte-consumer API is the primitive used for large resources. The NSData
// convenience remains intentionally limited to small, explicitly bounded
// control and metadata files and is implemented through that same primitive.
@protocol MTAuditedSource <NSObject>

@property(nonatomic, strong, readonly) MTSourceInventory *inventory;

- (nullable NSData *)
    readFileDataAtRelativePath:(NSString *)relativePath
              maximumByteCount:(uint64_t)maximumByteCount
             cancellationToken:
                 (nullable MTImportCancellationToken *)cancellationToken
                         error:(NSError **)error;

- (BOOL)streamFileAtRelativePath:(NSString *)relativePath
                maximumByteCount:(uint64_t)maximumByteCount
               cancellationToken:
                   (nullable MTImportCancellationToken *)cancellationToken
                    byteConsumer:(MTAuditedSourceByteConsumer)byteConsumer
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
