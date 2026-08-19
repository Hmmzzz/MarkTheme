#import <UIKit/UIKit.h>

@class MTManagerController;

@interface MTFoundationViewController : UIViewController
- (instancetype)initWithManagerController:
    (MTManagerController *)managerController;
- (instancetype)init;

- (void)presentImportForURL:(NSURL *)url;
@end
