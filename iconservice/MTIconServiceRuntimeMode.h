#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTIconServiceRuntimeMode) {
    MTIconServiceRuntimeModeDisabled = 0,
    MTIconServiceRuntimeModeObserve = 1,
    MTIconServiceRuntimeModeSource = 2,
};

FOUNDATION_EXPORT MTIconServiceRuntimeMode
    MTIconServiceConfiguredRuntimeMode(void);
FOUNDATION_EXPORT NSString *MTIconServiceRuntimeModeName(
    MTIconServiceRuntimeMode mode);

NS_ASSUME_NONNULL_END
