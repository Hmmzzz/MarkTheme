#import "MTRuntimeAsyncObjectCache.h"

#import <os/lock.h>

#import "MTRuntimeObjectCache.h"

// These private LRUs never escape the generation-aware cache. Every access is
// already serialized by its owner lock, so they do not need a second lock.
@interface MTRuntimeObjectCache<ObjectType> (MTExternalSynchronization)
- (instancetype)initWithMaximumCount:(NSUInteger)maximumCount
                          maximumCost:(NSUInteger)maximumCost
                     usesInternalLock:(BOOL)usesInternalLock;
@end

@interface MTRuntimeAsyncObjectCache () {
    os_unfair_lock _lock;
    MTRuntimeObjectCache *_ready;
    MTRuntimeObjectCache *_failures;
    NSMutableSet<NSString *> *_pending;
    NSMutableSet<NSString *> *_working;
    NSMutableDictionary<NSString *, dispatch_group_t> *_pendingGroups;
    NSUInteger _maximumPendingCount;
    NSString *_activeGenerationIdentifier;
    uint64_t _epoch;
}
@end

@implementation MTRuntimeAsyncObjectCache

- (instancetype)initWithMaximumReadyCount:(NSUInteger)maximumReadyCount
                          maximumReadyCost:(NSUInteger)maximumReadyCost
                       maximumPendingCount:(NSUInteger)maximumPendingCount
                       maximumFailureCount:(NSUInteger)maximumFailureCount {
    NSParameterAssert(maximumReadyCount > 0);
    NSParameterAssert(maximumReadyCost > 0);
    NSParameterAssert(maximumPendingCount > 0);
    NSParameterAssert(maximumFailureCount > 0);
    self = [super init];
    if (self == nil) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _ready = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:maximumReadyCount
        maximumCost:maximumReadyCost
        usesInternalLock:NO];
    _failures = [[MTRuntimeObjectCache alloc]
        initWithMaximumCount:maximumFailureCount
        maximumCost:maximumFailureCount
        usesInternalLock:NO];
    _pending = [NSMutableSet setWithCapacity:maximumPendingCount];
    _working = [NSMutableSet setWithCapacity:maximumPendingCount];
    _pendingGroups = [NSMutableDictionary
        dictionaryWithCapacity:maximumPendingCount];
    _maximumPendingCount = maximumPendingCount;
    return self;
}

- (void)selectGenerationLocked:(NSString *)generationIdentifier {
    if ([_activeGenerationIdentifier
            isEqualToString:generationIdentifier]) {
        return;
    }
    _activeGenerationIdentifier = [generationIdentifier copy];
    _epoch++;
    [_ready removeAllObjects];
    [_failures removeAllObjects];
    for (dispatch_group_t group in _pendingGroups.allValues) {
        dispatch_group_leave(group);
    }
    [_pending removeAllObjects];
    [_working removeAllObjects];
    [_pendingGroups removeAllObjects];
}

- (MTRuntimeAsyncCacheDisposition)
    lookupObjectForGenerationIdentifier:(NSString *)generationIdentifier
                                     key:(NSString *)key
                                  object:(id *)object
                                   epoch:(uint64_t *)epoch {
    NSParameterAssert(generationIdentifier.length > 0);
    NSParameterAssert(key.length > 0);
    if (object != NULL) *object = nil;
    if (epoch != NULL) *epoch = 0;
    os_unfair_lock_lock(&_lock);
    [self selectGenerationLocked:generationIdentifier];
    id ready = [_ready objectForKey:key];
    MTRuntimeAsyncCacheDisposition disposition;
    if (ready != nil) {
        if (object != NULL) *object = ready;
        disposition = MTRuntimeAsyncCacheDispositionReady;
    } else if ([_failures objectForKey:key] != nil) {
        disposition = MTRuntimeAsyncCacheDispositionFailed;
    } else if ([_pending containsObject:key]) {
        if (epoch != NULL) *epoch = _epoch;
        disposition = MTRuntimeAsyncCacheDispositionPending;
    } else if (_pending.count >= _maximumPendingCount) {
        disposition = MTRuntimeAsyncCacheDispositionSaturated;
    } else {
        [_pending addObject:key];
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        _pendingGroups[key] = group;
        if (epoch != NULL) *epoch = _epoch;
        disposition = MTRuntimeAsyncCacheDispositionScheduled;
    }
    os_unfair_lock_unlock(&_lock);
    return disposition;
}

- (id)readyObjectForGenerationIdentifier:(NSString *)generationIdentifier
                                      key:(NSString *)key {
    if (generationIdentifier.length == 0 || key.length == 0) return nil;
    os_unfair_lock_lock(&_lock);
    id object = [_activeGenerationIdentifier
            isEqualToString:generationIdentifier]
        ? [_ready objectForKey:key] : nil;
    os_unfair_lock_unlock(&_lock);
    return object;
}

- (BOOL)claimPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch {
    os_unfair_lock_lock(&_lock);
    BOOL claimed = epoch == _epoch &&
        [_activeGenerationIdentifier isEqualToString:generationIdentifier] &&
        [_pending containsObject:key] && ![_working containsObject:key];
    if (claimed) [_working addObject:key];
    os_unfair_lock_unlock(&_lock);
    return claimed;
}

- (id)waitForPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch {
    os_unfair_lock_lock(&_lock);
    dispatch_group_t group = epoch == _epoch &&
        [_activeGenerationIdentifier isEqualToString:generationIdentifier]
        ? _pendingGroups[key] : nil;
    os_unfair_lock_unlock(&_lock);
    if (group != nil) dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    os_unfair_lock_lock(&_lock);
    id object = epoch == _epoch &&
        [_activeGenerationIdentifier isEqualToString:generationIdentifier]
        ? [_ready objectForKey:key] : nil;
    os_unfair_lock_unlock(&_lock);
    return object;
}

- (BOOL)completeKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch
                  object:(id)object
                    cost:(NSUInteger)cost {
    NSParameterAssert(key.length > 0);
    NSParameterAssert(generationIdentifier.length > 0);
    os_unfair_lock_lock(&_lock);
    BOOL accepted = epoch == _epoch &&
        [_activeGenerationIdentifier
            isEqualToString:generationIdentifier] &&
        [_pending containsObject:key];
    if (accepted) {
        dispatch_group_t group = _pendingGroups[key];
        [_pending removeObject:key];
        [_working removeObject:key];
        [_pendingGroups removeObjectForKey:key];
        if (object != nil && cost > 0 &&
            [_ready setObject:object forKey:key cost:cost]) {
            // A successful object supersedes any earlier failure entry.
        } else {
            [_failures setObject:@YES forKey:key cost:1];
        }
        if (group != nil) dispatch_group_leave(group);
    }
    os_unfair_lock_unlock(&_lock);
    return accepted;
}

- (BOOL)isPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch {
    os_unfair_lock_lock(&_lock);
    BOOL pending = epoch == _epoch &&
        [_activeGenerationIdentifier
            isEqualToString:generationIdentifier] &&
        [_pending containsObject:key];
    os_unfair_lock_unlock(&_lock);
    return pending;
}

- (void)purgeReadyObjectsAndCancelPending {
    os_unfair_lock_lock(&_lock);
    _epoch++;
    [_ready removeAllObjects];
    for (dispatch_group_t group in _pendingGroups.allValues) {
        dispatch_group_leave(group);
    }
    [_pending removeAllObjects];
    [_working removeAllObjects];
    [_pendingGroups removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (NSString *)activeGenerationIdentifier {
    os_unfair_lock_lock(&_lock);
    NSString *identifier = _activeGenerationIdentifier;
    os_unfair_lock_unlock(&_lock);
    return identifier;
}

- (uint64_t)epoch {
    os_unfair_lock_lock(&_lock);
    uint64_t epoch = _epoch;
    os_unfair_lock_unlock(&_lock);
    return epoch;
}

- (NSUInteger)readyCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _ready.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSUInteger)readyCost {
    os_unfair_lock_lock(&_lock);
    NSUInteger cost = _ready.totalCost;
    os_unfair_lock_unlock(&_lock);
    return cost;
}

- (NSUInteger)pendingCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _pending.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSUInteger)failureCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _failures.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (uint64_t)evictionCount {
    os_unfair_lock_lock(&_lock);
    uint64_t count = _ready.evictionCount;
    os_unfair_lock_unlock(&_lock);
    return count;
}

@end
