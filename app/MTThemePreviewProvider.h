#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MTThemeLibraryStore;
@class MTThemeLibraryThemeSummary;

NS_ASSUME_NONNULL_BEGIN

// Loads at most four app icons from one metadata-validated catalog revision.
// Only the selected assets are read and hashed; Apply remains the full-revision
// validation boundary. Common system apps keep stable positions across themes.
FOUNDATION_EXPORT NSArray<UIImage *> *MTLoadThemePreviewImages(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryThemeSummary *themeSummary,
    NSError **error);

// Reads the matching stock app icons from the current iOS installation. The
// implementation is cached and supplies generated symbols only when an app is
// unavailable (for example Phone in Simulator).
FOUNDATION_EXPORT NSArray<UIImage *> *MTSystemDefaultPreviewImages(void);

NS_ASSUME_NONNULL_END
