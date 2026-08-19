#import <Foundation/Foundation.h>

#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTSystemIconMaskProviderExpectedImageUUID;

// Lazily asks the already-loaded 21D61 IconServices image for its native
// continuous rounded-rectangle alpha carrier. Callers must provide the exact
// point-size/scale contract from an actual system icon producer. A nil result
// is a stock fallback; this function never loads a framework or reads a UIKit
// process singleton.
FOUNDATION_EXPORT id _Nullable MTSystemIconMaskProviderImage(
    CGSize pointSize,
    CGFloat scale);

#if MT_HOST_TESTING
typedef id _Nullable (^MTSystemIconMaskTestRenderer)(
    CGSize pointSize,
    CGFloat scale);

FOUNDATION_EXPORT id MTSystemIconMaskProviderCreateForTesting(
    MTSystemIconMaskTestRenderer renderer);
FOUNDATION_EXPORT id _Nullable MTSystemIconMaskProviderImageForTesting(
    id provider,
    CGSize pointSize,
    CGFloat scale);
#endif

NS_ASSUME_NONNULL_END
