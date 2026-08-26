#import "MTIconOverlayContract.h"

NSString *const MTIconOverlayModuleID = @"icons.overlay";
NSString *const MTIconOverlaySurface = @"springboard.icon";
NSString *const MTIconOverlayGlobalSubject = @"global";
NSString *const MTIconOverlayVariantOverlay = @"overlay";

NSArray<NSString *> *MTIconOverlayResourceVariants(void) {
    static NSArray<NSString *> *variants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        variants = @[MTIconOverlayVariantOverlay];
    });
    return variants;
}
