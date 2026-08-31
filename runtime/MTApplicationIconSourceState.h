#import <Foundation/Foundation.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

// Shared by SpringBoard's return-home carrier and notification source. The
// display Runtime snapshot is immutable for the lifetime of the process, so a
// caller may safely memoize this decision by bundle identifier.
FOUNDATION_EXPORT BOOL MTApplicationIconSnapshotAffectsBundleIdentifier(
    MTRuntimeSnapshot *snapshot,
    NSString *bundleIdentifier);

NS_ASSUME_NONNULL_END
