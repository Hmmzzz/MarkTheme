#import <Foundation/Foundation.h>

@class MTModuleDescriptor;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTClockIconsModuleID;
FOUNDATION_EXPORT NSString *const MTClockIconTargetBundleIdentifier;
FOUNDATION_EXPORT NSArray<NSString *> *MTClockIconResourceVariants(void);
FOUNDATION_EXPORT MTModuleDescriptor *MTClockIconsModuleDescriptor(void);

NS_ASSUME_NONNULL_END
