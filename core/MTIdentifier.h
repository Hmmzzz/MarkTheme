#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTIdentifierErrorDomain;

// Stable identifiers are lowercase ASCII, 1...128 bytes, start and end with
// an alphanumeric character, and may contain '.', '-' or '_' separators.
FOUNDATION_EXPORT BOOL MTIdentifierIsValid(NSString *identifier);

// Normalizes ASCII case without trimming or repairing malformed input. The
// caller must treat nil as a validation failure rather than inventing an ID.
FOUNDATION_EXPORT NSString *_Nullable
MTNormalizeIdentifier(NSString *identifier, NSError **error);

NS_ASSUME_NONNULL_END
