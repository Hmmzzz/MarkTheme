#import "MTIconMaskContract.h"

NSString *const MTIconMaskModuleID = @"icons.mask";
NSString *const MTIconMaskSurface = @"springboard.icon";
NSString *const MTIconMaskGlobalSubject = @"global";
NSString *const MTIconMaskVariantMask = @"mask";
NSString *const MTIconMaskVariantPattern = @"pattern";
NSString *const MTIconMaskVariantSystem = @"system";

NSArray<NSString *> *MTIconMaskResourceVariants(void) {
    static NSArray<NSString *> *variants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        variants = @[MTIconMaskVariantMask, MTIconMaskVariantPattern];
    });
    return variants;
}
