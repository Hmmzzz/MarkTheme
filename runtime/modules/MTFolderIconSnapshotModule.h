#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

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
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) baseResourceHits;
    _Atomic(uint64_t) lightResourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) viewResolutions;
    _Atomic(uint64_t) replacementViewsCreated;
    _Atomic(uint64_t) originalViewsRestored;
} MTFolderIconSnapshotObservation;

FOUNDATION_EXPORT MTFolderIconSnapshotObservation
    MTRuntimeFolderIconSnapshotObservation;

FOUNDATION_EXPORT BOOL MTFolderIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
// Bootstrap calls this before installing the Folder hook. Later calls run on
// the Kernel reload queue and publish one immutable two-appearance image set.
FOUNDATION_EXPORT void MTFolderIconSnapshotReload(void);
FOUNDATION_EXPORT void MTFolderIconSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);

// UIKit work remains inside the ModuleRuntime. The ProcessAdapter supplies
// opaque objects and either receives its exact input or a replacement view.
FOUNDATION_EXPORT id _Nullable MTFolderIconSnapshotResolveBackgroundView(
    id folderImageView,
    id _Nullable originalBackgroundView,
    BOOL *didReplace);

NS_ASSUME_NONNULL_END
