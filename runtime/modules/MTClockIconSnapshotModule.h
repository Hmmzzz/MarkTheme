#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

@class MTRuntimeKernel;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTClockIconSnapshotModuleID;

// Immutable hand images decoded once per active Generation. The live face
// reuses the static icon module's decoded background; each optional hand
// component falls back independently to the system image.
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
// Prepares the active Generation's immutable hand set before returning.
// Bootstrap calls this before installing Clock hooks; later reloads already
// run on the Kernel's utility queue.
FOUNDATION_EXPORT void MTClockIconSnapshotReload(void);
FOUNDATION_EXPORT void MTClockIconSnapshotSetReadyHandler(
    dispatch_block_t _Nullable handler);
FOUNDATION_EXPORT MTClockIconImageSet * _Nullable
    MTClockIconSnapshotCurrentImageSet(void);

NS_ASSUME_NONNULL_END
