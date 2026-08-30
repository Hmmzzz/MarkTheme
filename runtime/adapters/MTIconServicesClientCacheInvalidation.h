#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, MTIconServicesClientCacheInvalidationOutcome) {
    MTIconServicesClientCacheInvalidationOutcomeNotLoaded = 0,
    MTIconServicesClientCacheInvalidationOutcomeVerified = 1,
    MTIconServicesClientCacheInvalidationOutcomeClassABIRejected = 2,
    MTIconServicesClientCacheInvalidationOutcomeMethodABIRejected = 3,
    MTIconServicesClientCacheInvalidationOutcomeIvarABIRejected = 4,
    MTIconServicesClientCacheInvalidationOutcomeManagerRejected = 5,
    MTIconServicesClientCacheInvalidationOutcomeRegistryRejected = 6,
    MTIconServicesClientCacheInvalidationOutcomeImageCacheRejected = 7,
};

typedef struct MTIconServicesClientCacheInvalidationResult {
    MTIconServicesClientCacheInvalidationOutcome outcome;
    uint32_t abiChecks;
    BOOL iconServicesLoaded;
    NSUInteger registeredIcons;
    NSUInteger registryEntriesRemoved;
    NSUInteger concreteIcons;
    NSUInteger imageCachesCleared;
    NSUInteger descriptorBagsCleared;
} MTIconServicesClientCacheInvalidationResult;

// Invalidates only IconServices' process-local weak icon registry and the
// descriptor bags retained by its live ISConcreteIcon instances. The service
// StoreIndex is cleared separately by iconservicesagent before Runtime receives
// a generation notification; this step prevents a client factory from reusing
// an ISIcon whose in-memory ISImageCache still contains the previous pixels.
//
// If IconServices has not been loaded in this process, there cannot be a live
// client cache and the operation succeeds with iconServicesLoaded == NO.
FOUNDATION_EXPORT BOOL MTIconServicesInvalidateClientImageCaches(
    MTIconServicesClientCacheInvalidationResult *_Nullable result);

NS_ASSUME_NONNULL_END
