#import <UIKit/UIKit.h>

@class MTManagerController;

NS_ASSUME_NONNULL_BEGIN

// Shared Apply outcome for Home and Theme Detail. Every successful active
// theme, stock restore, or mix-Generation change ends at the same explicit
// Respring boundary. Runtime delivery changes only the explanatory copy; it
// never turns a committed content change into a no-Respring success.
@interface MTApplyResultViewController : UIViewController

@property(nonatomic, copy, nullable) dispatch_block_t dismissalHandler;

- (instancetype)initWithThemeName:(NSString *)themeName
                    restoredStock:(BOOL)restoredStock
       runtimeDeliveryNeedsReload:(BOOL)runtimeDeliveryNeedsReload
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
