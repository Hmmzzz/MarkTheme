#import <Foundation/Foundation.h>

@class MTRuntimeState;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeHelperClientErrorDomain;

typedef NS_ENUM(NSUInteger, MTRuntimeApplyDelivery) {
    MTRuntimeApplyDeliveryAcknowledged = 1,
    MTRuntimeApplyDeliveryReloadRequired = 2,
};

@interface MTRuntimeApplyResult : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, assign, readonly) BOOL reusedExistingGeneration;
@property(nonatomic, strong, readonly) MTRuntimeState *state;
@property(nonatomic, assign, readonly) MTRuntimeApplyDelivery delivery;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTRuntimeHelperClient : NSObject

@property(nonatomic, copy, readonly) NSURL *helperURL;

+ (nullable instancetype)defaultClientWithError:(NSError **)error;
- (instancetype)initWithHelperURL:(NSURL *)helperURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable MTRuntimeApplyResult *)applyGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                          error:(NSError **)error;
- (nullable MTRuntimeState *)activateGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                        error:(NSError **)error;
- (nullable MTRuntimeState *)rollbackWithError:(NSError **)error;
- (nullable MTRuntimeState *)disableWithError:(NSError **)error;
- (BOOL)reloadDesktopWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
