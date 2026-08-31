#import <Foundation/Foundation.h>

@class MTRuntimeState;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeHelperClientErrorDomain;

@interface MTRuntimeApplyResult : NSObject

@property(nonatomic, copy, readonly) NSString *generationIdentifier;
@property(nonatomic, assign, readonly) BOOL reusedExistingGeneration;
@property(nonatomic, strong, readonly) MTRuntimeState *state;
// IconServices is the sole ordinary application-icon pixel source. A false
// value is a source transaction failure, not a request to respring a display
// process.
@property(nonatomic, assign, readonly) BOOL iconServiceAcknowledged;

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
// State-changing operations require the trusted IconServices transaction.
// Display Runtime processes consume the new state at the explicit Respring.
- (nullable MTRuntimeState *)activateGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                        error:(NSError **)error;
- (nullable MTRuntimeState *)disableWithError:(NSError **)error;
- (BOOL)requestRespringWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
