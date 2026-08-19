#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull (^MTUIResourceSnapshotProvider)(void);

@interface MTUIResourceSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only lookup from a process adapter identity to Generation v1.
@interface MTUIResourceSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTUIResourceSnapshotProvider)snapshotProvider
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTUIResourceSnapshotResolution *)
    resolutionForPreferencesIconName:(NSString *)resourceName
                               scale:(NSUInteger)scale
                               error:(NSError **)error;

- (nullable MTUIResourceSnapshotResolution *)
    resolutionForShareActivityName:(NSString *)activityName
                              scale:(NSUInteger)scale
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
