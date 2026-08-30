#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (*MTBadgeNativeBackgroundResolver)(
    id badgeView,
    id nativeBackgroundView);

typedef NS_ENUM(uint32_t, MTBadgeNativeSourceAdapterState) {
    MTBadgeNativeSourceAdapterStateDormant = 0,
    MTBadgeNativeSourceAdapterStateScheduled = 1,
    MTBadgeNativeSourceAdapterStateInstalled = 2,
    MTBadgeNativeSourceAdapterStateRejected = 10,
};

typedef struct MTBadgeNativeSourceAdapterObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) installAttempts;
    _Atomic(uint64_t) sourceCalls;
    _Atomic(uint64_t) mainThreadCalls;
    _Atomic(uint64_t) nativeBackgroundCalls;
    _Atomic(uint64_t) themedBackgrounds;
    _Atomic(uint64_t) nativeFallbacks;
    _Atomic(uint64_t) contractRejects;
} MTBadgeNativeSourceAdapterObservation;

FOUNDATION_EXPORT MTBadgeNativeSourceAdapterObservation
    MTRuntimeBadgeNativeSourceAdapterObservation;

// SpringBoardHome creates the persistent SBDarkeningImageView badge carrier
// once in -[SBIconBadgeView init]. The resolver runs exactly once after that
// native construction and leaves text, reuse, animation, sizing, and corner
// behavior entirely under Apple's ownership.
FOUNDATION_EXPORT BOOL MTBadgeNativeSourceAdapterSchedule(
    MTBadgeNativeBackgroundResolver resolver,
    BOOL (*preparation)(void),
    NSError **error);

NS_ASSUME_NONNULL_END
