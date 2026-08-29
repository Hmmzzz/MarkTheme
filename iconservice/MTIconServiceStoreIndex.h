#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger MTIconServiceStoreIndexValueByteCount;

typedef struct MTIconServiceStoreIndexValue {
    uint8_t iconDigest[16];
    double lowerSize;
    double upperSize;
    double dimension;
    uint32_t scaleDiscriminator;
    uint8_t descriptorDigest[16];
    uint8_t storeUnitUUID[16];
    uint8_t tokenDatabaseUUID[16];
    uint64_t tokenSequence;
    uint8_t tokenResourceUUID[16];
} __attribute__((packed)) MTIconServiceStoreIndexValue;

FOUNDATION_EXPORT BOOL MTIconServiceStoreIndexReadValue(
    const void *_Nullable bytes,
    NSUInteger byteCount,
    MTIconServiceStoreIndexValue *_Nullable valueOut);

FOUNDATION_EXPORT BOOL MTIconServiceStoreIndexValueMatches(
    const MTIconServiceStoreIndexValue *value,
    const uint8_t *_Nonnull descriptorDigest,
    const uint8_t *_Nonnull storeUnitUUID);

NS_ASSUME_NONNULL_END
