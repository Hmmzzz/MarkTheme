#import "MTDiagnosticsViewController.h"

#import "MTDesignSystem.h"
#import "MTDiagnosticsReport.h"

@interface MTDiagnosticsViewController ()
@property(nonatomic, strong) UITextView *textView;
@end

@implementation MTDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
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

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(copyReport)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier =
        @"marktheme.diagnostics.copy";
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
        alertControllerWithTitle:@"Copied"
                         message:@"Send this text to the developer."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
