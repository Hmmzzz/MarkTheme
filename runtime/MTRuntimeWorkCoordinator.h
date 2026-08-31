#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Coalesces a small number of demanded cache fills. It owns no result cache,
// failure history, generation epoch, or cancellation state: callers store the
// result in their existing cache and use the boolean return only to decide
// whether that fill completed inside their bounded wait.
@interface MTRuntimeWorkCoordinator : NSObject

@property(nonatomic, assign, readonly) NSUInteger maximumPendingCount;

- (instancetype)initWithMaximumPendingCount:(NSUInteger)maximumPendingCount
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Schedules work once for a key and waits no longer than waitNanoseconds for
// the shared fill. Returns NO on timeout or when the pending budget is full;
// already-scheduled work continues in the background.
- (BOOL)performWorkForKey:(NSString *)key
          waitNanoseconds:(uint64_t)waitNanoseconds
                     work:(dispatch_block_t)work;

@end

NS_ASSUME_NONNULL_END
