#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Receives the exact background view Apple is about to install into one
// SBFolderIconImageView. Returning nil or the input keeps the native source.
typedef id _Nullable (*MTFolderNativeBackgroundResolver)(
    id folderImageView,
    id nativeBackgroundView);

// Runs after Apple's setter and receives the background Apple retained. The
// overlay remains a child of the compact SBFolderIconImageView for its entire
// lifetime and therefore participates in the same native zoom carrier.
typedef BOOL (*MTFolderNativeOverlayResolver)(
    id folderImageView,
    id _Nullable installedBackgroundView);
// Mirrors SpringBoard's authoritative compact folder-grid opacity onto the
// separately authored compact overlay.
typedef BOOL (*MTFolderNativeOverlayAlphaSetter)(
    id folderImageView,
    CGFloat alpha);
// Mirrors SpringBoard's authoritative floaty-folder transition progress. The
// module combines this with the independent compact-grid opacity rather than
// letting the two native animation channels overwrite each other.
typedef BOOL (*MTFolderNativeOverlayFloatyFractionSetter)(
    id folderImageView,
    CGFloat fraction);
typedef void (*MTFolderNativeTransitionCallback)(void);

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

// Hooks SpringBoardHome's authoritative folder-background ownership outlet,
// both native opacity channels, and the validated animation-state setter. The
// same retained overlay stays in SBFolderIconImageView and follows Apple's
// exact floaty crossfade fraction, so it moves with the compact icon while
// fading before the opened folder becomes large. Apple continues to own view
// creation and layout. A process restart is the invalidation boundary.
FOUNDATION_EXPORT BOOL MTFolderNativeSourceAdapterSchedule(
    MTFolderNativeBackgroundResolver backgroundResolver,
    MTFolderNativeOverlayResolver overlayResolver,
    MTFolderNativeOverlayAlphaSetter overlayAlphaSetter,
    MTFolderNativeOverlayFloatyFractionSetter
        overlayFloatyFractionSetter,
    MTFolderNativeTransitionCallback transitionWillBegin,
    MTFolderNativeTransitionCallback transitionDidEnd,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
