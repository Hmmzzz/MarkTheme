#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTFolderBackgroundViewResolver)(
    id folderImageView,
    id _Nullable originalBackgroundView,
    BOOL *didReplace);

typedef NS_ENUM(uint32_t, MTFolderBackgroundImageAdapterState) {
    MTFolderBackgroundImageAdapterStateDormant = 0,
    MTFolderBackgroundImageAdapterStateScheduled = 1,
    MTFolderBackgroundImageAdapterStateInstalled = 2,
    MTFolderBackgroundImageAdapterStateRejected = 10,
};

typedef struct MTFolderBackgroundImageAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) updateCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) resolverCalls;
    _Atomic(uint64_t) replacementResults;
    _Atomic(uint64_t) refreshRequests;
    _Atomic(uint64_t) refreshExecutions;
} MTFolderBackgroundImageAdapterObservation;

FOUNDATION_EXPORT MTFolderBackgroundImageAdapterObservation
    MTRuntimeFolderBackgroundImageAdapterObservation;

FOUNDATION_EXPORT BOOL MTFolderBackgroundImageAdapterSchedule(
    MTFolderBackgroundViewResolver resolver,
    NSError **error);
FOUNDATION_EXPORT void MTFolderBackgroundImageAdapterRefresh(void);

NS_ASSUME_NONNULL_END
