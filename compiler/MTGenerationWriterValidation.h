#import <Foundation/Foundation.h>

@class MTCompiledGeneration;
@class MTGenerationAssetDescriptor;
@class MTGenerationDescriptor;
@class MTGenerationIndex;
@class MTGenerationWriterConfiguration;
@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Fully reparsed, exact-set view of a pure compiler result. It is internal to
// the writer composition and deliberately is not a published Generation model.
@interface MTGenerationValidatedInput : NSObject

@property(nonatomic, strong) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong) MTGenerationIndex *index;
@property(nonatomic, copy) NSData *indexData;
@property(nonatomic, copy) NSData *descriptorData;
@property(nonatomic, copy)
    NSDictionary<NSString *, MTGenerationAssetDescriptor *> *assetsByDigest;
@property(nonatomic, copy) NSArray<NSString *> *sortedAssetDigests;
@property(nonatomic, copy) NSDictionary<NSString *, NSURL *> *sourceURLs;
@property(nonatomic, assign) uint64_t totalByteCount;

@end


BOOL MTGenerationWriterCancelled(
    MTImportCancellationToken *_Nullable token,
    NSString *description,
    NSError **error);
MTGenerationValidatedInput *_Nullable MTGenerationWriterValidateInput(
    MTCompiledGeneration *compiledGeneration,
    MTGenerationWriterConfiguration *configuration,
    NSError **error);
BOOL MTGenerationWriterVerifyTree(
    int generationDescriptor,
    MTGenerationValidatedInput *input,
    MTImportCancellationToken *_Nullable token,
    NSError **error);
BOOL MTGenerationWriterVerifyFinal(
    int generationsDescriptor,
    MTGenerationValidatedInput *input,
    MTImportCancellationToken *_Nullable token,
    NSError **error);

NS_ASSUME_NONNULL_END
