#import <Foundation/Foundation.h>

@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

// Immutable digest of only the selected Generation modules. This lets a
// Runtime owner avoid expensive cache work when an unrelated feature changed,
// without trusting the whole-Generation identifier as a feature revision.
@interface MTRuntimeFeatureState : NSObject

@property(nonatomic, copy, readonly) NSString *fingerprint;
@property(nonatomic, copy, readonly) NSArray<NSString *> *enabledModuleIDs;
@property(nonatomic, copy, readonly)
    NSSet<NSString *> *moduleIDsWithResources;
@property(nonatomic, assign, readonly) NSUInteger resourceCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Returns nil only when the request or an already-admitted immutable index is
// structurally inconsistent. Disabled/stock snapshots return a stable empty
// state, so callers can distinguish "unchanged stock" from an unsafe failure.
FOUNDATION_EXPORT MTRuntimeFeatureState *_Nullable
MTRuntimeFeatureStateForSnapshot(
    MTRuntimeSnapshot *snapshot,
    NSArray<NSString *> *moduleIDs);

NS_ASSUME_NONNULL_END
