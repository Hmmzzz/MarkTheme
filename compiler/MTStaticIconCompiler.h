#import <Foundation/Foundation.h>

@class MTGenerationDescriptor;
@class MTGenerationIndex;
@class MTImportCancellationToken;
@class MTThemeComponentSelection;
@class MTThemeLibraryRevision;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTStaticIconCompilerErrorDomain;

typedef NS_ENUM(NSInteger, MTStaticIconCompilerErrorCode) {
    MTStaticIconCompilerErrorInvalidRevision = 1,
    MTStaticIconCompilerErrorUnsupportedResource = 2,
    MTStaticIconCompilerErrorIntegrity = 3,
    MTStaticIconCompilerErrorCancelled = 4,
    MTStaticIconCompilerErrorImageValidation = 5,
};

// Pure compile result. Asset URLs remain Library-owned inputs; the future
// writer must reopen no-follow, copy, and independently rehash them.
@interface MTCompiledGeneration : NSObject

@property(nonatomic, strong, readonly) MTGenerationDescriptor *descriptor;
@property(nonatomic, strong, readonly) MTGenerationIndex *index;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSURL *> *sourceAssetURLsByContentSHA256;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTStaticIconCompiler : NSObject

+ (instancetype)defaultCompiler;

- (nullable MTCompiledGeneration *)compileLibraryRevision:
    (MTThemeLibraryRevision *)revision
                                                cancellationToken:
    (nullable MTImportCancellationToken *)cancellationToken
                                                         error:
    (NSError **)error;

// The Library remains the immutable superset. A validated Manager selection
// filters authored alternatives and optional components into one compact
// Generation without copying or rewriting the Library revision.
- (nullable MTCompiledGeneration *)compileLibraryRevision:
    (MTThemeLibraryRevision *)revision
                                           componentSelection:
                                               (nullable MTThemeComponentSelection *)componentSelection
                                             cancellationToken:
                                                 (nullable MTImportCancellationToken *)cancellationToken
                                                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
