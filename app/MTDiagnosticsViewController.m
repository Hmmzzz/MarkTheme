#import "MTDiagnosticsViewController.h"

#import "MTDesignSystem.h"
#import "MTDiagnosticsReport.h"

@interface MTDiagnosticsViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

static NSString *MTDiagnosticsLocalized(NSString *key) {
    return NSLocalizedString(key, nil);
}

@implementation MTDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = MTDiagnosticsLocalized(@"diagnostics.title");
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.backgroundColor = MTCardColor();
    textView.font = [UIFont monospacedSystemFontOfSize:11
                                                weight:UIFontWeightRegular];
    textView.textColor = UIColor.labelColor;
    textView.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
    textView.accessibilityIdentifier = @"marktheme.diagnostics.text";
    [self.view addSubview:textView];
    self.textView = textView;

    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [textView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor],
        [textView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor],
        [textView.bottomAnchor
            constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(copyReport)];
    copyItem.accessibilityIdentifier = @"marktheme.diagnostics.copy";
    copyItem.accessibilityLabel =
        MTDiagnosticsLocalized(@"diagnostics.copy");
    UIBarButtonItem *exportItem = [[UIBarButtonItem alloc]
        initWithTitle:MTDiagnosticsLocalized(@"diagnostics.export")
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(exportReport:)];
    exportItem.accessibilityIdentifier = @"marktheme.diagnostics.export";
    self.navigationItem.rightBarButtonItems = @[exportItem, copyItem];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Re-read on every appearance so a respring's fresh report shows without
    // relaunching the app.
    self.textView.text = MTDiagnosticsReportText();
}

- (void)copyReport {
    UIPasteboard.generalPasteboard.string = self.textView.text ?: @"";
    [[[UINotificationFeedbackGenerator alloc] init]
        notificationOccurred:UINotificationFeedbackTypeSuccess];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:
            MTDiagnosticsLocalized(@"diagnostics.copied.title")
                         message:
            MTDiagnosticsLocalized(@"diagnostics.copied.message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:MTDiagnosticsLocalized(@"common.ok")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportReport:(UIBarButtonItem *)sender {
    // Re-read immediately so the exported file contains the newest Runtime
    // flush even if the page has remained open since the last respring.
    NSString *report = MTDiagnosticsReportText();
    self.textView.text = report;
    NSURL *temporaryDirectory = [NSURL
        fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *fileURL = [temporaryDirectory
        URLByAppendingPathComponent:@"MarkTheme-Diagnostics.txt"
                        isDirectory:NO];
    NSError *error = nil;
    BOOL wrote = [report writeToURL:fileURL
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&error];
    if (!wrote) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:
                MTDiagnosticsLocalized(@"diagnostics.export.error.title")
                             message:MTErrorPresentationMessage(
                MTDiagnosticsLocalized(@"diagnostics.export.error.message"),
                error)
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
            actionWithTitle:MTDiagnosticsLocalized(@"common.ok")
                      style:UIAlertActionStyleDefault
                    handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL]
        applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:activity animated:YES completion:nil];
}

@end
