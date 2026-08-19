#import <UIKit/UIKit.h>

@class MTManagerController;
@class MTThemePreviewRepository;

NS_ASSUME_NONNULL_BEGIN

@interface MTThemeDetailViewController : UITableViewController

- (instancetype)initWithManagerController:
    (MTManagerController *)managerController
    previewRepository:(MTThemePreviewRepository *)previewRepository
    themeIdentifier:(NSString *)themeIdentifier;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
