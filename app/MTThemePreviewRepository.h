#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MTThemeLibraryStore;
@class MTThemeLibraryThemeSummary;

NS_ASSUME_NONNULL_BEGIN

typedef void (^MTThemePreviewCompletion)(NSArray<UIImage *> *images);

typedef NS_ENUM(NSInteger, MTThemePreviewPriority) {
    MTThemePreviewPriorityLow = 0,
    MTThemePreviewPriorityNormal,
    MTThemePreviewPriorityHigh,
};

@interface MTThemePreviewRequest : NSObject

@property(nonatomic, assign, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;

@end

// One App-lifetime preview read model shared by Home, Library and Detail.
// Entries and in-flight work are keyed by immutable Library revision identity.
@interface MTThemePreviewRepository : NSObject

- (instancetype)initWithLibraryStore:(MTThemeLibraryStore *)libraryStore
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (nullable NSArray<UIImage *> *)cachedImagesForThemeSummary:
    (MTThemeLibraryThemeSummary *)themeSummary;
// Promotes the fixed four-image preview into a small deterministic foreground
// cache. Visible surfaces use this accessor so background recovery cannot
// regress an already decoded preview to placeholders when NSCache is purged.
- (nullable NSArray<UIImage *> *)presentationImagesForThemeSummary:
    (MTThemeLibraryThemeSummary *)themeSummary;
- (MTThemePreviewRequest *)loadImagesForThemeSummary:
        (MTThemeLibraryThemeSummary *)themeSummary
                                         priority:(MTThemePreviewPriority)priority
                                       completion:(MTThemePreviewCompletion)completion;
- (void)removeAllCachedImages;

@end

NS_ASSUME_NONNULL_END
