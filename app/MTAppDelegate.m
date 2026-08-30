#import "MTAppDelegate.h"

#import <TargetConditionals.h>

#import "MTDesignSystem.h"
#import "MTFoundationViewController.h"
#import "MTImportDiagnostics.h"
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
    MTImportDiagnosticsRecord(@"app.launch", @{
        @"hasLaunchURL" : @(launchURL != nil),
        @"launchURLPath" : launchURL.path ?: @"",
    });
    if (launchURL != nil) {
        // A cold-launch URL can otherwise sit unclaimed until the first main-
        // queue turn constructs and presents Import. Hold its scope across
        // that gap; the coordinator takes its own balanced scope synchronously
        // inside presentImportForURL:.
        BOOL launchURLSecurityScopeAccessed =
            [launchURL startAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.foundationController presentImportForURL:launchURL];
            if (launchURLSecurityScopeAccessed) {
                [launchURL stopAccessingSecurityScopedResource];
            }
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
    if (![arguments containsObject:@"--marktheme-preview-apply"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        MTApplyResultViewController *result =
            [[MTApplyResultViewController alloc]
                initWithThemeName:@"visionOS 美化鸭"
                  restoredStock:NO
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
    MTImportDiagnosticsRecord(@"app.open-url", @{
        @"isFileURL" : @(url.isFileURL),
        @"path" : url.path ?: @"",
        @"lastPathComponent" : url.lastPathComponent ?: @"",
        @"options" : options.description ?: @"",
    });
    if (!url.isFileURL) return NO;
    [self.foundationController presentImportForURL:url];
    return YES;
}

@end
