#import "MTRuntimeWorkCoordinator.h"

#import <os/lock.h>

#include <limits.h>

@interface MTRuntimeWorkCoordinator () {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, dispatch_group_t> *_pendingGroups;
}
@end

@implementation MTRuntimeWorkCoordinator

- (instancetype)initWithMaximumPendingCount:(NSUInteger)maximumPendingCount {
    if (maximumPendingCount == 0) return nil;
    self = [super init];
    if (self == nil) return nil;
    _maximumPendingCount = maximumPendingCount;
    _lock = OS_UNFAIR_LOCK_INIT;
    _pendingGroups = [NSMutableDictionary
        dictionaryWithCapacity:maximumPendingCount];
    return _pendingGroups == nil ? nil : self;
}

- (BOOL)performWorkForKey:(NSString *)key
          waitNanoseconds:(uint64_t)waitNanoseconds
                     work:(dispatch_block_t)work {
    if (key.length == 0 || work == nil || waitNanoseconds > INT64_MAX) {
        return NO;
    }
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_lock);
    dispatch_group_t group = _pendingGroups[key];
    if (group == nil && _pendingGroups.count < self.maximumPendingCount) {
        group = dispatch_group_create();
        dispatch_group_enter(group);
        _pendingGroups[key] = group;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_lock);
    if (group == nil) return NO;

    if (shouldSchedule) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    work();
                }
                dispatch_group_leave(group);
                MTRuntimeWorkCoordinator *strongSelf = weakSelf;
                if (strongSelf == nil) return;
                os_unfair_lock_lock(&strongSelf->_lock);
                if (strongSelf->_pendingGroups[key] == group) {
                    [strongSelf->_pendingGroups removeObjectForKey:key];
                }
                os_unfair_lock_unlock(&strongSelf->_lock);
            });
    }
    dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW, (int64_t)waitNanoseconds);
    return dispatch_group_wait(group, deadline) == 0;
}

@end
