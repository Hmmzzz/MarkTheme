#import "MTAppDelegate.h"

#import <TargetConditionals.h>

#import "MTDesignSystem.h"
#import "MTFoundationViewController.h"
#import "MTManagerController.h"
#if TARGET_OS_SIMULATOR
#import "MTApplyResultViewController.h"
#endif

@interface MTAppDelegate ()
@property(nonatomic, strong) MTManagerController *managerController;
@property(nonatomic, strong) MTFoundationViewController *foundationController;
#if TARGET_OS_SIMULATOR
- (void)presentApplyResultPreviewIfRequested;
#endif
@end

@implementation MTAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:
        (NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    NSError *managerError = nil;
    self.managerController =
        [MTManagerController defaultControllerWithError:&managerError];
    if (self.managerController == nil) {
        NSLog(@"MarkTheme Manager startup failed (%@/%ld): %@",
              managerError.domain, (long)managerError.code,
              managerError.localizedDescription);
        return NO;
    }
    // Start the asynchronous Library/Runtime read before constructing the
    // view hierarchy. The root screen consumes whichever immutable snapshot
    // is current when it loads; it must not own the cold-start lifecycle.
    [self.managerController reload];
    self.foundationController = [[MTFoundationViewController alloc]
        initWithManagerController:self.managerController];
    UINavigationController *navigation =
        [[UINavigationController alloc]
            initWithRootViewController:self.foundationController];
    MTConfigureNavigationController(navigation);
    navigation.navigationBar.prefersLargeTitles = NO;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = MTAccentColor();
    self.window.overrideUserInterfaceStyle = MTPreferredInterfaceStyle();
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.foundationController presentImportForURL:launchURL];
        });
    }
#if TARGET_OS_SIMULATOR
    if (launchURL == nil) [self presentApplyResultPreviewIfRequested];
#endif
    return YES;
}

#if TARGET_OS_SIMULATOR
- (void)presentApplyResultPreviewIfRequested {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    BOOL reloadRequired = [arguments containsObject:
        @"--marktheme-preview-apply-reload"];
    BOOL live = [arguments containsObject:@"--marktheme-preview-apply-live"];
    if (!reloadRequired && !live) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        MTApplyResultViewController *result =
            [[MTApplyResultViewController alloc]
                initWithThemeName:@"visionOS 美化鸭"
                  restoredStock:NO
                 reloadRequired:reloadRequired
               managerController:self.managerController];
        [self.foundationController presentViewController:result
                                                animated:NO
                                              completion:nil];
    });
}
#endif

- (BOOL)application:(UIApplication *)application
             openURL:(NSURL *)url
             options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    (void)application;
    (void)options;
    if (!url.isFileURL) return NO;
    [self.foundationController presentImportForURL:url];
    return YES;
}

@end
