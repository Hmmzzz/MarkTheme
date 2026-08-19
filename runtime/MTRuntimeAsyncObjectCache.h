#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTRuntimeAsyncCacheDisposition) {
    MTRuntimeAsyncCacheDispositionReady = 1,
    MTRuntimeAsyncCacheDispositionScheduled = 2,
    MTRuntimeAsyncCacheDispositionPending = 3,
    MTRuntimeAsyncCacheDispositionFailed = 4,
    MTRuntimeAsyncCacheDispositionSaturated = 5,
};

// Generation-aware single-flight coordinator around the exact LRU. It owns
// only process-local objects and state; callers perform decode on their queue.
@interface MTRuntimeAsyncObjectCache<ObjectType> : NSObject

@property(nonatomic, copy, readonly, nullable)
    NSString *activeGenerationIdentifier;
@property(nonatomic, assign, readonly) uint64_t epoch;
@property(nonatomic, assign, readonly) NSUInteger readyCount;
@property(nonatomic, assign, readonly) NSUInteger readyCost;
@property(nonatomic, assign, readonly) NSUInteger pendingCount;
@property(nonatomic, assign, readonly) NSUInteger failureCount;
@property(nonatomic, assign, readonly) uint64_t evictionCount;

- (instancetype)initWithMaximumReadyCount:(NSUInteger)maximumReadyCount
                          maximumReadyCost:(NSUInteger)maximumReadyCost
                       maximumPendingCount:(NSUInteger)maximumPendingCount
                       maximumFailureCount:(NSUInteger)maximumFailureCount
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Scheduled returns a new epoch token to carry into the background task.
- (MTRuntimeAsyncCacheDisposition)
    lookupObjectForGenerationIdentifier:(NSString *)generationIdentifier
                                     key:(NSString *)key
                                  object:(id _Nullable *_Nullable)object
                                   epoch:(uint64_t *_Nullable)epoch;

// Returns only an already-decoded object from the selected Generation. Unlike
// lookupObject..., this never selects a Generation, creates pending work,
// waits, or records a failure; animation adapters use it before invoking an
// expensive original image producer.
- (nullable ObjectType)readyObjectForGenerationIdentifier:
    (NSString *)generationIdentifier
                                                    key:(NSString *)key;

// Exactly one foreground or background worker may claim a scheduled key.
// A foreground demand can take work that is still queued by a prewarmer; if
// decoding already started it waits for that same completion.
- (BOOL)claimPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch;
- (nullable ObjectType)waitForPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch;

// A nil object records one bounded failure. NO means the task belongs to a
// stale generation/epoch or no longer owns the pending key.
- (BOOL)completeKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch
                  object:(nullable ObjectType)object
                    cost:(NSUInteger)cost;

- (BOOL)isPendingKey:(NSString *)key
    generationIdentifier:(NSString *)generationIdentifier
                   epoch:(uint64_t)epoch;

// Memory pressure removes decoded objects and invalidates in-flight tasks;
// cheap failure history remains scoped to the active generation.
- (void)purgeReadyObjectsAndCancelPending;

@end

NS_ASSUME_NONNULL_END
