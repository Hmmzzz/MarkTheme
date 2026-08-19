#import <Foundation/Foundation.h>

@class MTCompiledGeneration;
@class MTThemeLibraryRevision;
@class MTThemeLibraryStore;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSUInteger MTRunThemeApplyServiceTests(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryRevision *revision,
    MTCompiledGeneration *compiledGeneration);

NS_ASSUME_NONNULL_END
