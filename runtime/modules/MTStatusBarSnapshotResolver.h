#import <Foundation/Foundation.h>

#import "MTStatusBarContract.h"

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull (^MTStatusBarSnapshotProvider)(void);

// Foundation-only coordinates learned from a real status-bar signal view.
// Runtime bootstrap can construct the module without consulting UIKit.
@interface MTStatusBarSnapshotContext : NSObject <NSCopying>

@property(nonatomic, assign, readonly) NSUInteger scale;
@property(nonatomic, copy, readonly) NSString *deviceTrait;
@property(nonatomic, copy, readonly) NSString *cacheKey;

+ (nullable instancetype)contextWithScale:(NSUInteger)scale
                              deviceTrait:(nullable NSString *)deviceTrait;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTStatusBarSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Maps one typed signal level/style to one immutable Generation resource.
// Scale and idiom are primitive inputs; this resolver never imports UIKit.
@interface MTStatusBarSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTStatusBarSnapshotProvider)snapshotProvider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTStatusBarSnapshotResolution *)
    resolutionForKind:(MTStatusBarSignalKind)kind
                 style:(MTStatusBarArtworkStyle)style
                 level:(NSUInteger)level
               context:(MTStatusBarSnapshotContext *)context
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
