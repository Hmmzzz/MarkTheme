#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIconMaskModuleID;
FOUNDATION_EXPORT NSString *const MTIconMaskSurface;
FOUNDATION_EXPORT NSString *const MTIconMaskGlobalSubject;
FOUNDATION_EXPORT NSString *const MTIconMaskVariantMask;
FOUNDATION_EXPORT NSString *const MTIconMaskVariantPattern;
// Semantic fallback used when IB-MaskIcons enables masking but the theme does
// not author a custom mask raster. It is not a Generation resource variant.
FOUNDATION_EXPORT NSString *const MTIconMaskVariantSystem;

FOUNDATION_EXPORT NSArray<NSString *> *MTIconMaskResourceVariants(void);

NS_ASSUME_NONNULL_END
