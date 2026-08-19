#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One immutable, short-lived invocation target. The tracker itself keeps
// recipients and subjects weak; a snapshot retains only the objects needed by
// the refresh already in flight.
@interface MTRuntimeRefreshTarget : NSObject

@property(nonatomic, strong, readonly) id recipient;
@property(nonatomic, copy, readonly) NSArray *subjects;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTRuntimeTargetedRefreshSnapshot : NSObject

@property(nonatomic, copy, readonly) NSArray<NSString *> *identifiers;
@property(nonatomic, assign, readonly) NSUInteger subjectCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// nil selects every identifier in this snapshot.
- (NSArray<MTRuntimeRefreshTarget *> *)targetsForIdentifiers:
    (nullable NSSet<NSString *> *)identifiers;

@end

// Thread-safe weak registry shared by a ProcessAdapter's hot path and its
// background refresh coordinator. It has no private-API or process knowledge.
@interface MTRuntimeTargetedRefreshTracker : NSObject

- (void)recordRecipient:(nullable id)recipient
                 subject:(nullable id)subject
              identifier:(NSString *)identifier;
- (MTRuntimeTargetedRefreshSnapshot *)snapshot;

@end

NS_ASSUME_NONNULL_END
