#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTClockIconSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTClockIconSnapshotModuleState) {
    MTClockIconSnapshotModuleStateDormant = 0,
    MTClockIconSnapshotModuleStateConfigured = 1,
    MTClockIconSnapshotModuleStateReady = 2,
};

typedef struct MTClockIconSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) reloads;
    _Atomic(uint64_t) resourceRequests;
    _Atomic(uint64_t) resourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) imageSetPublishes;
    _Atomic(uint64_t) componentMatchRequests;
    _Atomic(uint64_t) componentMatchResults;
    _Atomic(uint64_t) staleResultsDiscarded;
} MTClockIconSnapshotObservation;

FOUNDATION_EXPORT MTClockIconSnapshotObservation
    MTRuntimeClockIconSnapshotObservation;

// Immutable legacy hand artwork decoded once per active Generation. The
// native-source adapter asks this module to match those images to the exact
// component geometry produced by SpringBoardHome; each absent or invalid
// component falls back independently to Apple's image.
@interface MTClockIconImageSet : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, strong, readonly, nullable) id hourHand;
@property(nonatomic, strong, readonly, nullable) id minuteHand;
@property(nonatomic, strong, readonly, nullable) id secondHand;
@property(nonatomic, strong, readonly, nullable) id hourMinuteDot;
@property(nonatomic, strong, readonly, nullable) id secondDot;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

FOUNDATION_EXPORT BOOL MTClockIconSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);
// Prepares the active Generation's immutable legacy hand set before returning.
// Bootstrap calls this before installing Clock source hooks. Theme changes use
// a Respring boundary because SpringBoardHome owns process-lifetime face and
// hand caches.
FOUNDATION_EXPORT void MTClockIconSnapshotReload(void);
FOUNDATION_EXPORT MTClockIconImageSet * _Nullable
    MTClockIconSnapshotCurrentImageSet(void);
FOUNDATION_EXPORT MTClockIconImageSet * _Nullable
    MTClockIconSnapshotImageSetMatchingNativeComponents(
        id _Nullable hourHand,
        id _Nullable minuteHand,
        id _Nullable secondHand,
        id _Nullable hourMinuteDot,
        id _Nullable secondDot);

NS_ASSUME_NONNULL_END
