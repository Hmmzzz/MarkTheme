#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTDigestErrorDomain;

FOUNDATION_EXPORT NSString *MTSHA256HexDigestForData(NSData *data);
FOUNDATION_EXPORT NSString * _Nullable MTSHA256HexDigestForFileDescriptor(
    int fileDescriptor,
    uint64_t maximumBytes,
    uint64_t *_Nullable bytesRead,
    NSError **error);
FOUNDATION_EXPORT BOOL MTStringIsLowercaseSHA256Digest(NSString *value);

NS_ASSUME_NONNULL_END
