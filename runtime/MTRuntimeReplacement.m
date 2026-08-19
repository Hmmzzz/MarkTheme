#import "MTRuntimeReplacement.h"

id MTRuntimeResultByApplyingReplacementResolver(
    NSString *resourceIdentifier,
    id originalResult,
    MTRuntimeReplacementResolver resolver,
    BOOL *didReplace) {
    id replacement = resolver(resourceIdentifier, originalResult);
    BOOL replaced = replacement != nil;
    if (didReplace != NULL) *didReplace = replaced;
    return replaced ? replacement : originalResult;
}
