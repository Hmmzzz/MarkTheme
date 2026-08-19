#import <Foundation/Foundation.h>

@class MTGenerationDescriptor;
@class MTGenerationIndex;
@class MTGenerationReaderConfiguration;
@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Independent final-tree interpretation result. It is deliberately produced
// without a writer-owned compiled object or writer validation helper.
@interface MTGenerationReaderValidatedTree : NSObject

@property(nonatomic, strong, readonly) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readonly) MTGenerationIndex *index;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

MTGenerationReaderValidatedTree *_Nullable
MTGenerationReaderValidateTree(
    int generationDescriptor,
    MTGenerationReaderConfiguration *configuration,
    NSString *expectedGenerationIdentifier,
    MTImportCancellationToken *_Nullable token,
    NSError **error);

NS_ASSUME_NONNULL_END
