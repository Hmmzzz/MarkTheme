#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MTDiagnosticsCollectionCompletion)(
    NSUInteger persistedProfileCount,
    NSError * _Nullable error);

// Opens one loopback-only, nonce-bound collection session. Sandboxed Runtime
// hosts send their complete report to this App, which is the sole owner that
// persists files in the Manager Diagnostics directory. The session remains
// available briefly while the operator exercises another system surface.
@interface MTDiagnosticsCollector : NSObject

+ (instancetype)sharedCollector;

- (void)refreshWithCompletion:
    (nullable MTDiagnosticsCollectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END
