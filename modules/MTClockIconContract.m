#import "MTClockIconsModule.h"

NSString *const MTClockIconsModuleID = @"icons.clock";
NSString *const MTClockIconTargetBundleIdentifier = @"com.apple.mobiletimer";

NSArray<NSString *> *MTClockIconResourceVariants(void) {
    static NSArray<NSString *> *variants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        variants = @[
            @"background", @"hour-hand", @"minute-hand", @"second-hand",
        ];
    });
    return variants;
}
