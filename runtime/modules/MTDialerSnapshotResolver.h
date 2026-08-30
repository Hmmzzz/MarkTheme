#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull (^MTDialerSnapshotProvider)(void);

@interface MTDialerSnapshotContext : NSObject <NSCopying>

@property(nonatomic, assign, readonly) NSUInteger scale;
@property(nonatomic, copy, readonly) NSString *deviceTrait;
@property(nonatomic, copy, readonly) NSString *cacheKey;

+ (nullable instancetype)contextWithScale:(NSUInteger)scale
                              deviceTrait:(nullable NSString *)deviceTrait;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTDialerSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only mapping from the legacy TelephonyUI subject namespace to
// one validated Generation resource. The native source image supplies its
// scale as a primitive; this object never queries a UIKit process singleton.
@interface MTDialerSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTDialerSnapshotProvider)snapshotProvider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTDialerSnapshotResolution *)
    resolutionForSubject:(NSString *)subject
                  context:(MTDialerSnapshotContext *)context
                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
