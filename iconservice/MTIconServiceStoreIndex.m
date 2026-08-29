#import "MTIconServiceStoreIndex.h"

#include <stddef.h>
#include <string.h>

const NSUInteger MTIconServiceStoreIndexValueByteCount = 0x74;

_Static_assert(sizeof(MTIconServiceStoreIndexValue) == 0x74,
    "21D61 StoreIndex values must stay exactly 0x74 bytes");
_Static_assert(offsetof(MTIconServiceStoreIndexValue, lowerSize) == 0x10,
    "StoreIndex lower-size offset changed");
_Static_assert(offsetof(MTIconServiceStoreIndexValue, descriptorDigest) == 0x2c,
    "StoreIndex descriptor-digest offset changed");
_Static_assert(offsetof(MTIconServiceStoreIndexValue, storeUnitUUID) == 0x3c,
    "StoreIndex StoreUnit UUID offset changed");
_Static_assert(offsetof(MTIconServiceStoreIndexValue, tokenDatabaseUUID) == 0x4c,
    "StoreIndex validation-token offset changed");

BOOL MTIconServiceStoreIndexReadValue(
    const void *bytes,
    NSUInteger byteCount,
    MTIconServiceStoreIndexValue *valueOut) {
    if (bytes == NULL || byteCount != MTIconServiceStoreIndexValueByteCount ||
        valueOut == NULL) {
        return NO;
    }
    memcpy(valueOut, bytes, sizeof(*valueOut));
    return YES;
}

BOOL MTIconServiceStoreIndexValueMatches(
    const MTIconServiceStoreIndexValue *value,
    const uint8_t *descriptorDigest,
    const uint8_t *storeUnitUUID) {
    return value != NULL && descriptorDigest != NULL &&
        storeUnitUUID != NULL &&
        memcmp(value->descriptorDigest, descriptorDigest, 16) == 0 &&
        memcmp(value->storeUnitUUID, storeUnitUUID, 16) == 0;
}
