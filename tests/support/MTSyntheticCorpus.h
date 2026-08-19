#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSyntheticCorpusErrorDomain;

typedef NS_ENUM(NSInteger, MTSyntheticCorpusErrorCode) {
    MTSyntheticCorpusErrorInvalidRequest = 1,
    MTSyntheticCorpusErrorFilesystem = 2,
    MTSyntheticCorpusErrorEncoding = 3,
    MTSyntheticCorpusErrorLimitExceeded = 4,
};

// Test-only deterministic source pair. Directory and ZIP contain byte-identical
// files so container benchmarks do not accidentally compare different themes.
@interface MTSyntheticCorpus : NSObject

@property(nonatomic, copy, readonly) NSURL *directoryURL;
@property(nonatomic, copy, readonly) NSURL *archiveURL;
@property(nonatomic, assign, readonly) NSUInteger iconCount;
@property(nonatomic, assign, readonly) uint32_t pixelDimension;
@property(nonatomic, assign, readonly) uint64_t directoryPayloadByteCount;
@property(nonatomic, assign, readonly) uint64_t archiveByteCount;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// The caller owns rootURL. This function creates two siblings below it and
// never removes or replaces an existing node.
FOUNDATION_EXPORT MTSyntheticCorpus *_Nullable
MTSyntheticCorpusCreate(NSURL *rootURL,
                        NSUInteger iconCount,
                        uint32_t pixelDimension,
                        NSError **error);

// Generates one deterministic, static, non-interlaced RGBA8 PNG. It is useful
// for standalone decoder benchmarks and shares the corpus pixel algorithm.
FOUNDATION_EXPORT NSData *_Nullable
MTSyntheticPNGData(uint32_t pixelDimension,
                   uint32_t seed,
                   NSError **error);

NS_ASSUME_NONNULL_END
