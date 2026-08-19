#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTRuntimeStateErrorDomain;
FOUNDATION_EXPORT NSUInteger const MTRuntimeStateSchemaVersion;

typedef NS_ENUM(NSInteger, MTRuntimeStateErrorCode) {
    MTRuntimeStateErrorInvalidInput = 1,
    MTRuntimeStateErrorMalformedData = 2,
    MTRuntimeStateErrorUnsupportedVersion = 3,
    MTRuntimeStateErrorStorage = 4,
};

typedef NS_ENUM(NSUInteger, MTRuntimeStateOwnershipProfile) {
    MTRuntimeStateOwnershipProfilePrivate = 1,
    MTRuntimeStateOwnershipProfilePublished = 2,
};

// The complete cross-process control plane. Runtime assets stay immutable;
// activation only atomically replaces state/active.json.
@interface MTRuntimeState : NSObject

@property(nonatomic, assign, readonly) NSUInteger schemaVersion;
@property(nonatomic, assign, readonly) uint64_t sequence;
@property(nonatomic, assign, readonly, getter=isRuntimeEnabled)
    BOOL runtimeEnabled;
@property(nonatomic, copy, readonly, nullable)
    NSString *activeGenerationIdentifier;
@property(nonatomic, copy, readonly, nullable)
    NSString *previousGenerationIdentifier;
@property(nonatomic, copy, readonly) NSData *canonicalData;

+ (instancetype)initialState;

- (nullable instancetype)initWithSequence:(uint64_t)sequence
                           runtimeEnabled:(BOOL)runtimeEnabled
               activeGenerationIdentifier:
                   (nullable NSString *)activeGenerationIdentifier
             previousGenerationIdentifier:
                   (nullable NSString *)previousGenerationIdentifier
                                     error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (nullable instancetype)initWithCanonicalData:(NSData *)canonicalData
                                          error:(NSError **)error;

+ (nullable instancetype)stateByReadingRuntimeRootURL:(NSURL *)runtimeRootURL
                                     ownershipProfile:
                                         (MTRuntimeStateOwnershipProfile)ownershipProfile
                                                 error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
