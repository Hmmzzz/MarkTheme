#import <Foundation/Foundation.h>

@class MTGenerationResource;
@class MTGeneration;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull (^MTRuntimeSnapshotProvider)(void);

@interface MTStaticIconSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only bridge from one private-surface identity to the immutable
// Generation index. It performs no file I/O or image work.
@interface MTStaticIconSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTRuntimeSnapshotProvider)snapshotProvider
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A valid snapshot/resource miss returns nil without setting an error.
- (nullable MTStaticIconSnapshotResolution *)
    resolutionForBundleIdentifier:(NSString *)bundleIdentifier
                            scale:(NSUInteger)scale
                            error:(NSError **)error;

// Returns every existing source in SnowBoard-compatible preference order.
// A consumer must continue through the array when a preferred PNG cannot be
// decoded for its requested output geometry.
- (nullable NSArray<MTStaticIconSnapshotResolution *> *)
    resolutionsForBundleIdentifier:(NSString *)bundleIdentifier
                              scale:(NSUInteger)scale
                        deviceTrait:(NSString *)deviceTrait
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
