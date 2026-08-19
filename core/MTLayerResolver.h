#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTResourceKey;

NS_ASSUME_NONNULL_BEGIN

@interface MTResourceCandidate : NSObject

@property(nonatomic, strong, readonly) MTResourceKey *resourceKey;
@property(nonatomic, copy, readonly) NSString *themeID;
@property(nonatomic, copy, readonly) NSString *relativeAssetPath;
@property(nonatomic, assign, readonly) NSInteger layerPriority;
@property(nonatomic, assign, readonly) NSUInteger matchRank;
@property(nonatomic, assign, readonly, getter=isExplicitOverride)
    BOOL explicitOverride;

- (nullable instancetype)initWithResourceKey:(MTResourceKey *)resourceKey
                                      themeID:(NSString *)themeID
                             relativeAssetPath:(NSString *)relativeAssetPath
                                layerPriority:(NSInteger)layerPriority
                                    matchRank:(NSUInteger)matchRank
                              explicitOverride:(BOOL)explicitOverride
                                        error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface MTResolutionResult : NSObject

@property(nonatomic, strong, readonly, nullable) MTResourceCandidate *winner;
@property(nonatomic, copy, readonly) NSArray<MTResourceCandidate *> *shadowed;
@property(nonatomic, assign, readonly, getter=hasConflict) BOOL conflict;
@property(nonatomic, strong, readonly, nullable) MTDiagnostic *diagnostic;

@end

@interface MTLayerResolver : NSObject

+ (MTResolutionResult *)resolveCandidates:(NSArray<MTResourceCandidate *> *)candidates
                           forResourceKey:(MTResourceKey *)resourceKey;

@end

NS_ASSUME_NONNULL_END
