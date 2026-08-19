#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconShadowsModuleID;
FOUNDATION_EXPORT NSString *const MTIconShadowSurface;
FOUNDATION_EXPORT NSString *const MTIconShadowSubjectIPhone;
FOUNDATION_EXPORT NSString *const MTIconShadowSubjectIPad;
FOUNDATION_EXPORT NSString *const MTIconShadowSubjectIPadPro;

FOUNDATION_EXPORT NSArray<NSString *> *MTIconShadowSubjects(void);
FOUNDATION_EXPORT BOOL MTIconShadowSubjectIsSupported(NSString *subject);
FOUNDATION_EXPORT BOOL MTIconShadowDeviceTraitIsSupported(NSString *trait);

// AnemoneEffects shadow canvases are intentionally larger than the icon. The
// point dimensions below preserve the established 220/330 px iPhone,
// 279 px iPad, and 306 px iPad Pro resources without baking them into the
// 60 pt icon raster.
FOUNDATION_EXPORT double MTIconShadowCanvasPointDimension(
    NSString *subject);

NS_ASSUME_NONNULL_END
