#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull
    (^MTIconShadowSnapshotProvider)(void);

@interface MTIconShadowSnapshotContext : NSObject <NSCopying>

@property(nonatomic, assign, readonly) NSUInteger scale;
@property(nonatomic, copy, readonly) NSString *deviceTrait;
@property(nonatomic, assign, readonly) BOOL prefersLargeIPadCanvas;
@property(nonatomic, copy, readonly) NSString *cacheKey;

+ (nullable instancetype)contextWithScale:(NSUInteger)scale
                               deviceTrait:(NSString *)deviceTrait
                  prefersLargeIPadCanvas:(BOOL)prefersLargeIPadCanvas;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTIconShadowSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;
@property(nonatomic, copy, readonly) NSString *subject;
@property(nonatomic, assign, readonly) NSUInteger sourceScale;
@property(nonatomic, assign, readonly) uint32_t targetPixelDimension;
@property(nonatomic, assign, readonly) double canvasPointDimension;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only selection boundary. UIKit traits are reduced to one
// immutable primitive context by the actual configured icon view.
@interface MTIconShadowSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTIconShadowSnapshotProvider)snapshotProvider
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTIconShadowSnapshotResolution *)
    resolutionForVariant:(NSString *)variant
                  context:(MTIconShadowSnapshotContext *)context
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
