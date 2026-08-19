#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull (^MTBadgeSnapshotProvider)(void);

// Immutable, Foundation-only rendering coordinates learned from an actual
// configured Badge view. Construction deliberately accepts primitive values
// instead of consulting UIKit process singletons, so Runtime bootstrap can
// create the Badge module before the UI environment exists.
@interface MTBadgeSnapshotContext : NSObject <NSCopying>

@property(nonatomic, assign, readonly) NSUInteger scale;
@property(nonatomic, copy, readonly) NSString *deviceTrait;
@property(nonatomic, copy, readonly) NSString *cacheKey;

+ (nullable instancetype)contextWithScale:(NSUInteger)scale
                              deviceTrait:(nullable NSString *)deviceTrait;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTBadgeSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only lookup boundary. The caller supplies the selected authored
// style (`variant`) and the current system appearance; resolution keeps those
// axes independent and falls back only within the same style.
@interface MTBadgeSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTBadgeSnapshotProvider)snapshotProvider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A valid resource miss returns nil without setting an error.
- (nullable MTBadgeSnapshotResolution *)
    resolutionForVariant:(NSString *)variant
                    scale:(NSUInteger)scale
              deviceTrait:(NSString *)deviceTrait
               appearance:(NSString *)appearance
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
