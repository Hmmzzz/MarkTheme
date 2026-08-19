#import "MTBadgeContract.h"

NSString *const MTBadgesModuleID = @"badges";
NSString *const MTBadgeSurface = @"springboard.badge";
NSString *const MTBadgeGlobalSubject = @"global";
NSString *const MTBadgeAppearanceAny = @"any";
NSString *const MTBadgeAppearanceLight = @"light";
NSString *const MTBadgeAppearanceDark = @"dark";

static BOOL MTBadgeDeviceTraitIsSupported(NSString *trait) {
    return [trait isEqualToString:@"any"] ||
        [trait isEqualToString:@"iphone"] ||
        [trait isEqualToString:@"ipad"];
}

static BOOL MTBadgeAppearanceIsSupported(NSString *appearance) {
    return [appearance isEqualToString:MTBadgeAppearanceAny] ||
        [appearance isEqualToString:MTBadgeAppearanceLight] ||
        [appearance isEqualToString:MTBadgeAppearanceDark];
}

NSString *MTBadgeResourceTrait(NSString *deviceTrait,
                               NSString *appearance) {
    if (!MTBadgeDeviceTraitIsSupported(deviceTrait) ||
        !MTBadgeAppearanceIsSupported(appearance)) {
        return nil;
    }
    if ([appearance isEqualToString:MTBadgeAppearanceAny]) {
        return deviceTrait;
    }
    if ([deviceTrait isEqualToString:@"any"]) {
        return appearance;
    }
    return [NSString stringWithFormat:@"%@-%@", deviceTrait, appearance];
}

BOOL MTBadgeResourceTraitIsSupported(NSString *trait) {
    if (![trait isKindOfClass:NSString.class]) return NO;
    for (NSString *deviceTrait in @[@"any", @"iphone", @"ipad"]) {
        for (NSString *appearance in @[
                MTBadgeAppearanceAny,
                MTBadgeAppearanceLight,
                MTBadgeAppearanceDark,
            ]) {
            if ([trait isEqualToString:
                    MTBadgeResourceTrait(deviceTrait, appearance)]) {
                return YES;
            }
        }
    }
    return NO;
}

NSArray<NSString *> *MTBadgeResourceTraitCandidates(
    NSString *deviceTrait,
    NSString *appearance) {
    if (!MTBadgeDeviceTraitIsSupported(deviceTrait) ||
        !MTBadgeAppearanceIsSupported(appearance)) {
        return @[];
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (![appearance isEqualToString:MTBadgeAppearanceAny]) {
        NSString *combined = MTBadgeResourceTrait(deviceTrait, appearance);
        if (combined != nil) [candidates addObject:combined];
        if (![deviceTrait isEqualToString:@"any"] &&
            ![candidates containsObject:appearance]) {
            [candidates addObject:appearance];
        }
    }
    if (![deviceTrait isEqualToString:@"any"] &&
        ![candidates containsObject:deviceTrait]) {
        [candidates addObject:deviceTrait];
    }
    if (![candidates containsObject:MTBadgeAppearanceAny]) {
        [candidates addObject:MTBadgeAppearanceAny];
    }
    return [candidates copy];
}
