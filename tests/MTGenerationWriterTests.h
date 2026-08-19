#import <Foundation/Foundation.h>

@class MTCompiledGeneration;

NS_ASSUME_NONNULL_BEGIN

// Exercises the writer against a disposable clone of a real pure compiler
// result and returns the number of completed Host contract assertions.
FOUNDATION_EXPORT NSUInteger MTRunGenerationWriterTests(
    MTCompiledGeneration *compiledGeneration);

NS_ASSUME_NONNULL_END
