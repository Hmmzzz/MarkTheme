#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTDialerModuleID;
FOUNDATION_EXPORT NSString *const MTDialerSurface;
FOUNDATION_EXPORT const CGFloat MTDialerButtonPointDimension;
FOUNDATION_EXPORT NSString *const MTDialerCallButtonSubject;
FOUNDATION_EXPORT NSString *const MTDialerCallButtonPressedSubject;

FOUNDATION_EXPORT NSArray<NSString *> *MTDialerNumberButtonSubjects(void);
FOUNDATION_EXPORT NSArray<NSString *> *MTDialerRuntimeSubjects(void);
FOUNDATION_EXPORT BOOL MTDialerResourceSubjectIsSupported(NSString *subject);

NS_ASSUME_NONNULL_END
