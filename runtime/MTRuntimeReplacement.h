#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (*MTRuntimeReplacementResolver)(
    NSString *resourceIdentifier,
    id _Nullable originalResult);
typedef BOOL (*MTRuntimeReplacementPreparation)(void);

// Applies one already-selected Runtime resolver. A miss is represented by nil
// and must return the exact original object, including an original nil result.
FOUNDATION_EXPORT id _Nullable MTRuntimeResultByApplyingReplacementResolver(
    NSString *resourceIdentifier,
    id _Nullable originalResult,
    MTRuntimeReplacementResolver resolver,
    BOOL * _Nullable didReplace);

NS_ASSUME_NONNULL_END
