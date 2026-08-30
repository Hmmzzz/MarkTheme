#import "MTRuntimeDiagnosticsProtocol.h"

NSString *const MTRuntimeDiagnosticsCollectionRequestNotificationName =
    @"com.hmmzzz.marktheme.diagnostics.collection-request";

const NSUInteger MTRuntimeDiagnosticsMaximumDatagramByteCount = 60 * 1024;
const uint32_t MTRuntimeDiagnosticsMaximumSessionSeconds = 5 * 60;

static const uint64_t MTRuntimeDiagnosticsPortMask = UINT64_C(0xffff);
static const uint64_t MTRuntimeDiagnosticsTwentyFourBitMask =
    UINT64_C(0xffffff);

uint64_t MTRuntimeDiagnosticsCollectionRequestWord(
    uint16_t port,
    uint32_t nonce,
    uint64_t expirationUnixTime) {
    if (port == 0 || nonce == 0 ||
        nonce > MTRuntimeDiagnosticsTwentyFourBitMask ||
        expirationUnixTime == 0) {
        return 0;
    }
    uint64_t expiry = expirationUnixTime &
        MTRuntimeDiagnosticsTwentyFourBitMask;
    if (expiry == 0) return 0;
    return (expiry << 40) | ((uint64_t)nonce << 16) | (uint64_t)port;
}

BOOL MTRuntimeDiagnosticsDecodeCollectionRequestWord(
    uint64_t word,
    uint64_t currentUnixTime,
    MTRuntimeDiagnosticsCollectionRequest *requestOut) {
    if (requestOut != NULL) {
        *requestOut = (MTRuntimeDiagnosticsCollectionRequest){0};
    }
    if (word == 0) return NO;
    uint16_t port = (uint16_t)(word & MTRuntimeDiagnosticsPortMask);
    uint32_t nonce = (uint32_t)((word >> 16) &
        MTRuntimeDiagnosticsTwentyFourBitMask);
    uint32_t expiry = (uint32_t)((word >> 40) &
        MTRuntimeDiagnosticsTwentyFourBitMask);
    uint32_t now = (uint32_t)(currentUnixTime &
        MTRuntimeDiagnosticsTwentyFourBitMask);
    uint32_t remaining = (expiry - now) &
        (uint32_t)MTRuntimeDiagnosticsTwentyFourBitMask;
    if (port == 0 || nonce == 0 || remaining == 0 ||
        remaining > MTRuntimeDiagnosticsMaximumSessionSeconds) {
        return NO;
    }
    if (requestOut != NULL) {
        requestOut->port = port;
        requestOut->nonce = nonce;
        requestOut->expirationUnixTime = currentUnixTime + remaining;
    }
    return YES;
}
