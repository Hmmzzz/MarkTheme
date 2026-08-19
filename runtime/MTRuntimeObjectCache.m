#import "MTRuntimeObjectCache.h"

#import <os/lock.h>

@interface MTRuntimeObjectCacheEntry : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, strong) id object;
@property(nonatomic, assign) NSUInteger cost;
@property(nonatomic, unsafe_unretained, nullable)
    MTRuntimeObjectCacheEntry *previous;
@property(nonatomic, unsafe_unretained, nullable)
    MTRuntimeObjectCacheEntry *next;
@end

@implementation MTRuntimeObjectCacheEntry
@end

@interface MTRuntimeObjectCache () {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, MTRuntimeObjectCacheEntry *> *_entries;
    MTRuntimeObjectCacheEntry *_head;
    MTRuntimeObjectCacheEntry *_tail;
    NSUInteger _totalCost;
    uint64_t _evictionCount;
}
@end

@implementation MTRuntimeObjectCache

- (instancetype)initWithMaximumCount:(NSUInteger)maximumCount
                         maximumCost:(NSUInteger)maximumCost {
    NSParameterAssert(maximumCount > 0);
    NSParameterAssert(maximumCost > 0);
    self = [super init];
    if (self == nil) return nil;
    _maximumCount = maximumCount;
    _maximumCost = maximumCost;
    _lock = OS_UNFAIR_LOCK_INIT;
    _entries = [NSMutableDictionary dictionaryWithCapacity:maximumCount];
    return self;
}

- (void)moveEntryToHeadLocked:(MTRuntimeObjectCacheEntry *)entry {
    if (_head == entry) return;
    MTRuntimeObjectCacheEntry *previous = entry.previous;
    MTRuntimeObjectCacheEntry *next = entry.next;
    previous.next = next;
    next.previous = previous;
    if (_tail == entry) _tail = previous;
    entry.previous = nil;
    entry.next = _head;
    _head.previous = entry;
    _head = entry;
    if (_tail == nil) _tail = entry;
}

- (void)removeEntryLocked:(MTRuntimeObjectCacheEntry *)entry
            countsEviction:(BOOL)countsEviction {
    MTRuntimeObjectCacheEntry *previous = entry.previous;
    MTRuntimeObjectCacheEntry *next = entry.next;
    previous.next = next;
    next.previous = previous;
    if (_head == entry) _head = next;
    if (_tail == entry) _tail = previous;
    _totalCost -= entry.cost;
    [_entries removeObjectForKey:entry.key];
    entry.previous = nil;
    entry.next = nil;
    if (countsEviction) _evictionCount++;
}

- (id)objectForKey:(NSString *)key {
    if (key.length == 0) return nil;
    os_unfair_lock_lock(&_lock);
    MTRuntimeObjectCacheEntry *entry = _entries[key];
    if (entry != nil) [self moveEntryToHeadLocked:entry];
    id object = entry.object;
    os_unfair_lock_unlock(&_lock);
    return object;
}

- (BOOL)setObject:(id)object
           forKey:(NSString *)key
             cost:(NSUInteger)cost {
    NSParameterAssert(object != nil);
    NSParameterAssert(key.length > 0);
    NSParameterAssert(cost > 0);
    os_unfair_lock_lock(&_lock);
    MTRuntimeObjectCacheEntry *existing = _entries[key];
    if (existing != nil) {
        [self removeEntryLocked:existing countsEviction:NO];
    }
    if (cost > self.maximumCost) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    while (_tail != nil &&
           (_entries.count >= self.maximumCount ||
            _totalCost > self.maximumCost - cost)) {
        [self removeEntryLocked:_tail countsEviction:YES];
    }
    MTRuntimeObjectCacheEntry *entry =
        [[MTRuntimeObjectCacheEntry alloc] init];
    entry.key = key;
    entry.object = object;
    entry.cost = cost;
    entry.next = _head;
    _head.previous = entry;
    _head = entry;
    if (_tail == nil) _tail = entry;
    _entries[entry.key] = entry;
    _totalCost += cost;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (void)removeAllObjects {
    os_unfair_lock_lock(&_lock);
    for (MTRuntimeObjectCacheEntry *entry in _entries.allValues) {
        entry.previous = nil;
        entry.next = nil;
    }
    [_entries removeAllObjects];
    _head = nil;
    _tail = nil;
    _totalCost = 0;
    os_unfair_lock_unlock(&_lock);
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _entries.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSUInteger)totalCost {
    os_unfair_lock_lock(&_lock);
    NSUInteger totalCost = _totalCost;
    os_unfair_lock_unlock(&_lock);
    return totalCost;
}

- (uint64_t)evictionCount {
    os_unfair_lock_lock(&_lock);
    uint64_t evictionCount = _evictionCount;
    os_unfair_lock_unlock(&_lock);
    return evictionCount;
}

@end
