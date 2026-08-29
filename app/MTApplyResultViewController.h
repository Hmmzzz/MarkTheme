#import <UIKit/UIKit.h>

@class MTManagerController;

NS_ASSUME_NONNULL_BEGIN

// Shared Apply outcome for Home and Theme Detail. A verified IconServices +
// display transaction completes in place; Respring is offered only when the
// already-running display owner did not acknowledge the committed state.
@interface MTApplyResultViewController : UIViewController

@property(nonatomic, copy, nullable) dispatch_block_t dismissalHandler;

- (instancetype)initWithThemeName:(NSString *)themeName
                    restoredStock:(BOOL)restoredStock
                   reloadRequired:(BOOL)reloadRequired
                 managerController:(MTManagerController *)managerController
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                          bundle:(nullable NSBundle *)nibBundleOrNil
    NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
