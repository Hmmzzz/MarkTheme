#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Records one capability-probe outcome for a single adapter contract. The
// adapter reports the encoding it required and the encoding the running system
// actually published, so an unsupported OS build can be diagnosed from a user
// report instead of a device the maintainer owns.
//
// `actualEncoding` is nil when the class or selector is absent entirely; that
// distinction separates "layout changed" from "surface removed".
FOUNDATION_EXPORT void MTRuntimeABIReportRecordContract(
    NSString *adapterID,
    NSString *contractID,
    BOOL satisfied,
    NSString * _Nullable expectedEncoding,
    NSString * _Nullable actualEncoding);

// Records the adapter's terminal state code once installation finishes or is
// abandoned. `stateName` is the compile-time enum spelling.
FOUNDATION_EXPORT void MTRuntimeABIReportRecordAdapterState(
    NSString *adapterID,
    uint32_t state,
    NSString *stateName);

// Serializes everything recorded in this process to the shared report
// directory. Safe to call repeatedly; the newest write wins. Failures are
// silent because diagnostics must never affect the host process.
FOUNDATION_EXPORT void MTRuntimeABIReportFlush(NSString *profileID);

NS_ASSUME_NONNULL_END
