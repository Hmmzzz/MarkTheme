#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL MTPreferencesGraphicIconRendererPrepare(void);
FOUNDATION_EXPORT id _Nullable MTPreferencesGraphicIconRendererResolve(
    NSString *type, id originalImage, id descriptor);

NS_ASSUME_NONNULL_END
