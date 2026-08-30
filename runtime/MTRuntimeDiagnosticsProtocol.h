#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Runtime hosts cannot write the Manager's private Diagnostics directory:
// sandbox policy is stronger than Unix ownership and mode bits. The App owns
// one time-bounded loopback collector and advertises its port through this
// Darwin notification state. Runtime reports include the nonce so the App can
// reject delayed or unrelated local datagrams before persisting them.
FOUNDATION_EXPORT NSString *const
    MTRuntimeDiagnosticsCollectionRequestNotificationName;

FOUNDATION_EXPORT const NSUInteger
    MTRuntimeDiagnosticsMaximumDatagramByteCount;
FOUNDATION_EXPORT const uint32_t
    MTRuntimeDiagnosticsMaximumSessionSeconds;

typedef struct {
    uint16_t port;
    uint32_t nonce;
    uint64_t expirationUnixTime;
} MTRuntimeDiagnosticsCollectionRequest;

// The notify state is one uint64: 24-bit wrapped expiry, 24-bit random nonce,
// and 16-bit loopback UDP port. Zero is always an inactive request.
FOUNDATION_EXPORT uint64_t MTRuntimeDiagnosticsCollectionRequestWord(
    uint16_t port,
    uint32_t nonce,
    uint64_t expirationUnixTime);

FOUNDATION_EXPORT BOOL MTRuntimeDiagnosticsDecodeCollectionRequestWord(
    uint64_t word,
    uint64_t currentUnixTime,
    MTRuntimeDiagnosticsCollectionRequest *requestOut);

NS_ASSUME_NONNULL_END
