#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeStressFixtureErrorDomain;

// Writes one deterministic, independently validated private Generation store
// for device-only Runtime publication interruption tests. The destination must
// not already exist and is never bundled into a product target.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTRuntimeStressFixtureWrite(NSURL *destinationRootURL,
                            NSError **error);

// Writes the smallest valid 180 px Generation that can exercise the exact
// SpringBoard visual-proof request used by the M3-D device gate.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTRuntimeSnapshotFixtureWrite(NSURL *destinationRootURL,
                              NSError **error);

// Writes two independently validated Generations for the same SpringBoard
// subject with different deterministic pixels. The shared destination models
// a private PublishInbox and never enters a product target.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTRuntimeSnapshotSwapFixtureWrite(NSURL *destinationRootURL,
                                  NSError **error);

// Writes two independently validated fallback Generations. The first has one
// byte/hash-valid static-icon resource that ImageIO must reject; the second is
// a canonical empty Generation whose module list explicitly excludes
// icons.static. Neither fixture is reachable from a product target.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTRuntimeFallbackFixtureWrite(NSURL *destinationRootURL,
                              NSError **error);

// Writes a 500-record Runtime index whose subjects all reference one shared
// deterministic 180 px asset. This keeps the device-transfer fixture small
// while preserving the intended warm-index lookup cardinality.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable
MTRuntimePerformanceFixtureWrite(NSURL *destinationRootURL,
                                 NSError **error);

NS_ASSUME_NONNULL_END
