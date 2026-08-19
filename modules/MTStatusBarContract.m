#import "MTStatusBarContract.h"

NSString *const MTStatusBarModuleID = @"ui.statusbar";
NSString *const MTStatusBarSurface = @"statusbar.item";

NSUInteger MTStatusBarMaximumLevel(MTStatusBarSignalKind kind) {
    switch (kind) {
        case MTStatusBarSignalKindCellular: return 4;
        case MTStatusBarSignalKindWiFi: return 3;
    }
    return NSNotFound;
}

NSString *MTStatusBarResourceSubject(MTStatusBarSignalKind kind,
                                     MTStatusBarArtworkStyle style,
                                     NSUInteger level) {
    NSUInteger maximum = MTStatusBarMaximumLevel(kind);
    if (maximum == NSNotFound || level > maximum ||
        (style != MTStatusBarArtworkStyleBlack &&
         style != MTStatusBarArtworkStyleLockScreen)) {
        return nil;
    }
    NSString *stylePrefix = style == MTStatusBarArtworkStyleBlack
        ? @"Black" : @"LockScreen";
    NSString *family = kind == MTStatusBarSignalKindCellular
        ? @"Bars" : @"WifiBars";
    return [NSString stringWithFormat:@"%@_%lu_%@", stylePrefix,
        (unsigned long)level, family];
}

NSArray<NSString *> *MTStatusBarRuntimeSubjects(void) {
    static NSArray<NSString *> *subjects;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *values =
            [NSMutableArray arrayWithCapacity:18];
        for (NSUInteger style = MTStatusBarArtworkStyleBlack;
             style <= MTStatusBarArtworkStyleLockScreen; style++) {
            for (NSUInteger kind = MTStatusBarSignalKindCellular;
                 kind <= MTStatusBarSignalKindWiFi; kind++) {
                NSUInteger maximum = MTStatusBarMaximumLevel(kind);
                for (NSUInteger level = 0; level <= maximum; level++) {
                    NSString *subject = MTStatusBarResourceSubject(
                        kind, style, level);
                    if (subject != nil) [values addObject:subject];
                }
            }
        }
        subjects = [values copy];
    });
    return subjects;
}

BOOL MTStatusBarResourceSubjectIsSupported(NSString *subject) {
    return [subject isKindOfClass:NSString.class] &&
        [MTStatusBarRuntimeSubjects() containsObject:subject];
}
