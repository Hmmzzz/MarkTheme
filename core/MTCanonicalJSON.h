#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTCanonicalJSONErrorDomain;

// Serializes the data-only MarkTheme64e subset: dictionaries with string keys,
// arrays, NFC strings, integer numbers, booleans and null. Dictionary keys are
// ordered literally and floating-point values are rejected.
FOUNDATION_EXPORT NSData * _Nullable MTCanonicalJSONData(
    id object,
    NSError **error);

NS_ASSUME_NONNULL_END
