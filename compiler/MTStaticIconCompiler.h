#import <Foundation/Foundation.h>

@class MTGenerationDescriptor;
@class MTGenerationIndex;
@class MTImportCancellationToken;
@class MTThemeComponentSelection;
@class MTThemeLibraryRevision;
@class MTThemeMixSelection;

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

// Builds one deterministic Generation from the current immutable revisions
// referenced by a feature-level mix selection. The base revision remains the
// public Generation identity; selected records/configurations can come from
// other fully validated Library revisions, and disabled features contribute
// neither records nor module configuration.
- (nullable MTCompiledGeneration *)compileLibraryRevisionsByThemeIdentifier:
    (NSDictionary<NSString *, MTThemeLibraryRevision *> *)
        revisionsByThemeIdentifier
    mixSelection:(MTThemeMixSelection *)mixSelection
    cancellationToken:(nullable MTImportCancellationToken *)cancellationToken
    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
