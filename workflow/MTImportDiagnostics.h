#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A small persistent breadcrumb ring for device-only import failures. Values
// are reduced to property-list scalars, and only the newest events survive.
FOUNDATION_EXPORT void MTImportDiagnosticsRecord(
    NSString *event,
    NSDictionary<NSString *, id> * _Nullable fields);
FOUNDATION_EXPORT void MTImportDiagnosticsRecordError(
    NSString *event,
    NSError * _Nullable error,
    NSDictionary<NSString *, id> * _Nullable fields);
FOUNDATION_EXPORT NSString *MTImportDiagnosticsText(void);

NS_ASSUME_NONNULL_END
