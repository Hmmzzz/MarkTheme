#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Exact process-local LRU used for decoded Runtime objects. Unlike NSCache,
// count and cost limits are deterministic and therefore testable contracts.
@interface MTRuntimeObjectCache<ObjectType> : NSObject

@property(nonatomic, assign, readonly) NSUInteger maximumCount;
@property(nonatomic, assign, readonly) NSUInteger maximumCost;
@property(nonatomic, assign, readonly) NSUInteger count;
@property(nonatomic, assign, readonly) NSUInteger totalCost;
@property(nonatomic, assign, readonly) uint64_t evictionCount;

- (instancetype)initWithMaximumCount:(NSUInteger)maximumCount
                         maximumCost:(NSUInteger)maximumCost
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable ObjectType)objectForKey:(NSString *)key;
- (BOOL)setObject:(ObjectType)object
           forKey:(NSString *)key
             cost:(NSUInteger)cost;
- (void)removeAllObjects;

@end

NS_ASSUME_NONNULL_END
