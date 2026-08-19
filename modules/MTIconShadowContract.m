#import "MTIconShadowContract.h"

NSString *const MTIconShadowsModuleID = @"icons.shadow";
NSString *const MTIconShadowSurface = @"springboard.icon-shadow";
NSString *const MTIconShadowSubjectIPhone = @"iPhoneShadow";
NSString *const MTIconShadowSubjectIPad = @"iPadShadow";
NSString *const MTIconShadowSubjectIPadPro = @"iPadProShadow";

NSArray<NSString *> *MTIconShadowSubjects(void) {
    static NSArray<NSString *> *subjects;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        subjects = @[
            MTIconShadowSubjectIPhone,
            MTIconShadowSubjectIPad,
            MTIconShadowSubjectIPadPro,
        ];
    });
    return subjects;
}

BOOL MTIconShadowSubjectIsSupported(NSString *subject) {
    return [MTIconShadowSubjects() containsObject:subject];
}

BOOL MTIconShadowDeviceTraitIsSupported(NSString *trait) {
    return [trait isEqualToString:@"any"] ||
        [trait isEqualToString:@"iphone"] ||
        [trait isEqualToString:@"ipad"];
}

double MTIconShadowCanvasPointDimension(NSString *subject) {
    if ([subject isEqualToString:MTIconShadowSubjectIPhone]) return 110.0;
    if ([subject isEqualToString:MTIconShadowSubjectIPad]) return 139.5;
    if ([subject isEqualToString:MTIconShadowSubjectIPadPro]) return 153.0;
    return 0.0;
}
