#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MTThemeLibraryStore;
@class MTThemeLibraryThemeSummary;
@class MTImportCancellationToken;

NS_ASSUME_NONNULL_BEGIN

// Loads at most four app icons from one metadata-validated catalog revision.
// Only the selected assets are read and hashed; Apply remains the full-revision
// validation boundary. Common system apps keep stable positions across themes.
FOUNDATION_EXPORT NSArray<UIImage *> *MTLoadThemePreviewImages(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryThemeSummary *themeSummary,
    NSError **error);

// The repository uses this form so a cell that leaves the screen can stop
// manifest scanning, bounded asset reads, and the remaining ImageIO decodes.
FOUNDATION_EXPORT NSArray<UIImage *> *MTLoadThemePreviewImagesWithCancellation(
    MTThemeLibraryStore *libraryStore,
    MTThemeLibraryThemeSummary *themeSummary,
    MTImportCancellationToken * _Nullable cancellationToken,
    NSError **error);

// Resolves each registered system App bundle through LaunchServices, then
// reads stock icons directly from that bundle's Info.plist/Assets.car.
// IconServices is bypassed so the current MarkTheme Generation cannot affect
// the system-default preview. The result is cached and supplies generated
// symbols only when an App bundle is unavailable (for example in Simulator).
FOUNDATION_EXPORT NSArray<UIImage *> *MTSystemDefaultPreviewImages(void);

NS_ASSUME_NONNULL_END
