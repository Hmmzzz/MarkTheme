#import <Foundation/Foundation.h>

#include <stdatomic.h>
#include <stdint.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTBadgeSnapshotModuleID;

typedef NS_ENUM(uint32_t, MTBadgeSnapshotModuleState) {
    MTBadgeSnapshotModuleStateDormant = 0,
    MTBadgeSnapshotModuleStateConfigured = 1,
    MTBadgeSnapshotModuleStateReady = 2,
};

typedef struct MTBadgeSnapshotObservation {
    uint32_t schemaVersion;
    _Atomic(uint32_t) state;
    _Atomic(uint64_t) lightResourceHits;
    _Atomic(uint64_t) darkResourceHits;
    _Atomic(uint64_t) decodeSuccesses;
    _Atomic(uint64_t) decodeFailures;
    _Atomic(uint64_t) nativeSourceResolutions;
    _Atomic(uint64_t) appearanceSelections;
    _Atomic(uint64_t) themedBackgrounds;
    _Atomic(uint64_t) nativeFallbacks;
} MTBadgeSnapshotObservation;

FOUNDATION_EXPORT MTBadgeSnapshotObservation
    MTRuntimeBadgeSnapshotObservation;

FOUNDATION_EXPORT BOOL MTBadgeSnapshotConfigure(
    MTRuntimeKernel *kernel,
    NSError **error);

// Publishes the immutable light/dark badge image set on the first native badge
// source call, after UIKit has begun constructing SpringBoard's view graph.
// Theme and mix changes recreate this state through the product-wide Respring
// boundary; bootstrap never asks UIScreen to initialize from a dylib
// constructor.
FOUNDATION_EXPORT BOOL MTBadgeSnapshotPrepare(void);

// Applies an authored raster to Apple's persistent SBDarkeningImageView
// carrier. A false result means that the exact native color background stays
// untouched.
FOUNDATION_EXPORT BOOL MTBadgeSnapshotApplyNativeBackground(
    id badgeView,
    id nativeBackgroundView);

NS_ASSUME_NONNULL_END
