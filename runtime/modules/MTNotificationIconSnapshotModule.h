#import <Foundation/Foundation.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTNotificationIconSnapshotModuleErrorDomain;

// Captures the SpringBoard bootstrap snapshot. Theme and mix changes have a
// mandatory Respring boundary, so notification pixels cannot drift to a new
// Generation before UserNotificationsUIKit and its mapped cache restart.
FOUNDATION_EXPORT BOOL MTNotificationIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT BOOL MTNotificationIconSnapshotPrepare(void);

// Reuses the IconServices application-icon compositor against the exact
// UIImage geometry supplied by UserNotificationsUIKit. A miss returns nil and
// leaves the complete native icon array untouched.
FOUNDATION_EXPORT id _Nullable MTNotificationIconSnapshotResolve(
    NSString *bundleIdentifier,
    id originalImage);

NS_ASSUME_NONNULL_END
