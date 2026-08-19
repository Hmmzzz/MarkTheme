#import "MTDialerContract.h"

#import <dispatch/dispatch.h>

NSString *const MTDialerModuleID = @"ui.dialer";
NSString *const MTDialerSurface = @"phone.dialer";
const CGFloat MTDialerButtonPointDimension = 75.0;
NSString *const MTDialerCallButtonSubject = @"callButton";
NSString *const MTDialerCallButtonPressedSubject = @"callButtonPressed";

NSArray<NSString *> *MTDialerNumberButtonSubjects(void) {
    static NSArray<NSString *> *subjects;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        subjects = @[
            @"0", @"1", @"2", @"3", @"4", @"5",
            @"6", @"7", @"8", @"9", @"10", @"11",
        ];
    });
    return subjects;
}

NSArray<NSString *> *MTDialerRuntimeSubjects(void) {
    static NSArray<NSString *> *subjects;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        subjects = [MTDialerNumberButtonSubjects() arrayByAddingObjectsFromArray:
            @[ MTDialerCallButtonSubject, MTDialerCallButtonPressedSubject ]];
    });
    return subjects;
}

BOOL MTDialerResourceSubjectIsSupported(NSString *subject) {
    return [subject isKindOfClass:NSString.class] &&
        [MTDialerRuntimeSubjects() containsObject:subject];
}
