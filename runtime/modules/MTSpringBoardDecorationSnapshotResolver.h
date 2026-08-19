#import <Foundation/Foundation.h>

@class MTGeneration;
@class MTGenerationResource;
@class MTRuntimeSnapshot;

NS_ASSUME_NONNULL_BEGIN

typedef MTRuntimeSnapshot * _Nonnull
    (^MTSpringBoardDecorationSnapshotProvider)(void);

typedef NS_ENUM(NSUInteger, MTSpringBoardDecorationKind) {
    MTSpringBoardDecorationKindIconMask = 0,
    MTSpringBoardDecorationKindIconPattern = 1,
    MTSpringBoardDecorationKindFolderBackground = 2,
    MTSpringBoardDecorationKindFolderBackgroundLight = 3,
};

@interface MTSpringBoardDecorationSnapshotResolution : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, copy, readonly) NSString *canonicalResourceKey;
@property(nonatomic, strong, readonly) MTGeneration *generation;
@property(nonatomic, strong, readonly) MTGenerationResource *resource;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Foundation-only boundary between the SpringBoard adapter and the immutable
// Generation. Hook selection and UIKit image work remain outside this type.
@interface MTSpringBoardDecorationSnapshotResolver : NSObject

- (instancetype)initWithSnapshotProvider:
    (MTSpringBoardDecorationSnapshotProvider)snapshotProvider
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A valid miss returns nil without setting an error.
- (nullable MTSpringBoardDecorationSnapshotResolution *)
    resolutionForKind:(MTSpringBoardDecorationKind)kind
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
