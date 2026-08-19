#import "MTFolderIconContract.h"

NSString *const MTFolderIconsModuleID = @"folders";
NSString *const MTFolderIconSurface = @"springboard.folder";
NSString *const MTFolderIconGlobalSubject = @"global";
NSString *const MTFolderIconVariantBackground = @"background";
NSString *const MTFolderIconVariantBackgroundLight = @"background-light";

NSArray<NSString *> *MTFolderIconResourceVariants(void) {
    static NSArray<NSString *> *variants;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        variants = @[
            MTFolderIconVariantBackground,
            MTFolderIconVariantBackgroundLight,
        ];
    });
    return variants;
}
