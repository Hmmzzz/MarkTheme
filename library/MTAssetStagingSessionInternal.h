#import "MTAssetStagingSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^MTAssetStagingLibraryAdoptionBlock)(
    int objectsDescriptor,
    NSDictionary<NSString *, MTStagedAsset *> *assetsByDigest,
    NSError **error);

// Internal bridge: the Library receives a descriptor to the already verified
// object directory while the session monitor is held. No public arbitrary-path
// adoption API is exposed. A successful block consumes the provisional
// session; a failed block leaves it intact for a bounded retry.
@interface MTAssetStagingSession (MTLibraryAdoption)

- (BOOL)performLockedLibraryAdoptionForRequiredDigests:
            (NSSet<NSString *> *)requiredDigests
    consumer:(MTAssetStagingLibraryAdoptionBlock)consumer
       error:(NSError **)error;

// Import validation may reject one independently staged digest while keeping
// the remaining theme usable. Removal is exact, verified and updates the
// session's adoption set before Review data is created.
- (BOOL)removeStagedAssetWithContentSHA256:(NSString *)contentSHA256
                                     error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
