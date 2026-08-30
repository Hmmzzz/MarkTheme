#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Receives the exact background view Apple is about to install into one
// SBFolderIconImageView. Returning nil or the input keeps the native source.
typedef id _Nullable (*MTFolderNativeBackgroundResolver)(
    id folderImageView,
    id nativeBackgroundView);

// Runs after Apple's setter and receives the background that the native owner
// actually retained. It may attach only the theme-defined final overlay.
typedef BOOL (*MTFolderNativeOverlayResolver)(
    id folderImageView,
    id _Nullable installedBackgroundView);

typedef NS_ENUM(uint32_t, MTFolderNativeSourceAdapterState) {
    MTFolderNativeSourceAdapterStateDormant = 0,
    MTFolderNativeSourceAdapterStateScheduled = 1,
    MTFolderNativeSourceAdapterStateInstalled = 2,
    MTFolderNativeSourceAdapterStateRejected = 10,
};

typedef struct MTFolderNativeSourceAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) sourceCalls;
    _Atomic(uint64_t) nativeBackgroundCalls;
    _Atomic(uint64_t) nilBackgroundCalls;
    _Atomic(uint64_t) themedBackgrounds;
    _Atomic(uint64_t) overlayActivations;
    _Atomic(uint64_t) nativeFallbacks;
    _Atomic(uint64_t) contractRejects;
} MTFolderNativeSourceAdapterObservation;

FOUNDATION_EXPORT MTFolderNativeSourceAdapterObservation
    MTRuntimeFolderNativeSourceAdapterObservation;

// Hooks only SpringBoardHome's authoritative folder-background ownership
// outlet. Apple continues to create/configure the source view, own its slot,
// lay out miniature icons, and run every open/close animation. A process
// restart is the invalidation boundary.
FOUNDATION_EXPORT BOOL MTFolderNativeSourceAdapterSchedule(
    MTFolderNativeBackgroundResolver backgroundResolver,
    MTFolderNativeOverlayResolver overlayResolver,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
