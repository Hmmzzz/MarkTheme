#import <UIKit/UIKit.h>

@class MTManagerController;

NS_ASSUME_NONNULL_BEGIN

@interface MTSettingsViewController : UITableViewController
@property(nonatomic, copy, nullable) dispatch_block_t dismissalHandler;
- (instancetype)initWithManagerController:
    (MTManagerController *)managerController;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
