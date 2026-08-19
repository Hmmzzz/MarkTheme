#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTRuntimeState;

NS_ASSUME_NONNULL_BEGIN

// One immutable, internally consistent Runtime view. State and Generation are
// exchanged together so a hot-path reader never observes a mixed pair.
@interface MTRuntimeSnapshot : NSObject

@property(nonatomic, strong, readonly) MTRuntimeState *state;
@property(nonatomic, strong, readonly, nullable) MTGeneration *generation;
@property(nonatomic, assign, readonly, getter=isReady) BOOL ready;

+ (instancetype)stockSnapshot;
- (instancetype)initWithState:(MTRuntimeState *)state
                    generation:(nullable MTGeneration *)generation
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
