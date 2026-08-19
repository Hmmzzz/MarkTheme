#import <UIKit/UIKit.h>

@class MTManagerController;
@class MTThemePreviewRepository;

NS_ASSUME_NONNULL_BEGIN

typedef void (^MTThemeLibrarySelectionHandler)(
    NSString * _Nullable themeIdentifier);

@interface MTThemeLibraryViewController : UIViewController

@property(nonatomic, copy, nullable) dispatch_block_t dismissalHandler;

- (instancetype)initWithManagerController:
    (MTManagerController *)managerController
    previewRepository:(MTThemePreviewRepository *)previewRepository
    selectedThemeIdentifier:
    (nullable NSString *)selectedThemeIdentifier
    selectionHandler:(MTThemeLibrarySelectionHandler)selectionHandler;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
