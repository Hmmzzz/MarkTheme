#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL MTShareSheetProviderClassMatchesExpectedImage(
    Class runtimeClass);
FOUNDATION_EXPORT BOOL
    MTShareSheetProviderImplementationMatchesExpectedImage(
        IMP implementation);

NS_ASSUME_NONNULL_END
