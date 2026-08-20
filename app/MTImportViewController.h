#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeArchiveContentTypeIdentifier;

typedef void (^MTThemeImportCompletionHandler)(NSString *themeIdentifier);

@interface MTImportViewController : UIViewController
@property(nonatomic, copy, nullable) dispatch_block_t dismissalHandler;
- (instancetype)initWithCompletionHandler:
    (nullable MTThemeImportCompletionHandler)completionHandler;
- (instancetype)init;
- (void)beginChoosingThemeSource;
- (void)startImportAtURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
