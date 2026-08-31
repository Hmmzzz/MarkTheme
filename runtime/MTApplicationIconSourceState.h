#import <Foundation/Foundation.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

// Used only by SpringBoard's return-home carrier animation. The display
// Runtime snapshot is immutable for the lifetime of the process.
FOUNDATION_EXPORT BOOL MTApplicationIconSnapshotAffectsBundleIdentifier(
    MTRuntimeSnapshot *snapshot,
    NSString *bundleIdentifier);

NS_ASSUME_NONNULL_END
