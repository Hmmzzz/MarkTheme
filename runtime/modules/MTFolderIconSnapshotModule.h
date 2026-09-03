#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTFolderIconSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTFolderIconSnapshotModuleState) {
    MTFolderIconSnapshotModuleStateDormant = 0,
    MTFolderIconSnapshotModuleStateConfigured = 1,
    MTFolderIconSnapshotModuleStateReady = 2,
};

typedef struct MTFolderIconSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) baseResourceHits;
    _Atomic(uint64_t) lightResourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) backgroundResolutions;
    _Atomic(uint64_t) backgroundReplacements;
    _Atomic(uint64_t) overlayActivations;
} MTFolderIconSnapshotObservation;

FOUNDATION_EXPORT MTFolderIconSnapshotObservation
    MTRuntimeFolderIconSnapshotObservation;

FOUNDATION_EXPORT BOOL MTFolderIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
FOUNDATION_EXPORT BOOL MTFolderIconSnapshotPrepare(void);

// Bootstrap publishes one immutable two-appearance image set before the
// native SpringBoardHome ownership outlet is hooked. Theme changes rely on
// the product-wide Respring boundary instead of mutating live folder views.
// Replaces only a non-nil native background source. A nil result or the exact
// input tells the ProcessAdapter to keep Apple's view.
FOUNDATION_EXPORT id _Nullable MTFolderIconSnapshotResolveNativeBackground(
    id folderImageView,
    id nativeBackgroundView);

// Synchronizes the separately authored global overlay after Apple's setter.
// It never creates a background for native folder categories that omit one.
// The same retained view always stays attached to the compact Home Screen
// folder image and follows Apple's native zoom carrier.
FOUNDATION_EXPORT BOOL MTFolderIconSnapshotSynchronizeOverlay(
    id folderImageView,
    id _Nullable installedBackgroundView);
FOUNDATION_EXPORT BOOL MTFolderIconSnapshotSetOverlayAlpha(
    id folderImageView,
    CGFloat alpha);
FOUNDATION_EXPORT BOOL MTFolderIconSnapshotSetFloatyCrossfadeFraction(
    id folderImageView,
    CGFloat fraction);

NS_ASSUME_NONNULL_END
