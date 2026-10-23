#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTPreferencesGraphicCompletionShape) {
    MTPreferencesGraphicCompletionUnsupported = 0,
    MTPreferencesGraphicCompletionImage = 1,
    MTPreferencesGraphicCompletionImageAndError = 2,
};

typedef id _Nullable (^MTPreferencesGraphicImageTransform)(id image);

FOUNDATION_EXPORT BOOL MTPreferencesGraphicIconTypeIsSupported(
    NSString *_Nullable type);
FOUNDATION_EXPORT MTPreferencesGraphicCompletionShape
    MTPreferencesGraphicIconCompletionShape(id _Nullable completion);

// Unknown block signatures and non-block objects pass through by identity.
// Supported callbacks stay on the caller's queue and forward exactly once per
// invocation. A missing image or a non-nil error never invokes the transform.
FOUNDATION_EXPORT id _Nullable MTPreferencesGraphicIconWrapCompletion(
    id _Nullable completion,
    MTPreferencesGraphicImageTransform transform);

NS_ASSUME_NONNULL_END
