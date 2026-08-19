#import <Foundation/Foundation.h>

#import <objc/runtime.h>

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

// Records a data-plane module's state (for example Dormant / Configured /
// Ready), so a report shows both whether a Hook installed and whether the
// module behind it could publish its resources for this device.
FOUNDATION_EXPORT void MTRuntimeABIReportRecordModuleState(
    NSString *moduleID,
    uint32_t state,
    NSString *stateName);

// Convenience probes that record one contract and return the same outcome the
// adapter will gate on, so every adapter reports the identical shape with
// minimal boilerplate. A NULL method records an absent selector.
FOUNDATION_EXPORT BOOL MTRuntimeABIReportProbeMethodType(
    NSString *ownerID,
    NSString *contractID,
    Method _Nullable method,
    const char *expectedEncoding);
FOUNDATION_EXPORT BOOL MTRuntimeABIReportProbePresence(
    NSString *ownerID,
    NSString *contractID,
    BOOL present);
// Records one implementation-provenance contract using the shared coexistence
// rule: any resolvable image is hookable, and a non-system image is annotated
// as third-party so a composed hook chain stays visible in user reports.
FOUNDATION_EXPORT BOOL MTRuntimeABIReportProbeImplementation(
    NSString *ownerID,
    NSString *contractID,
    IMP _Nullable implementation);

// Serializes everything recorded in this process to the shared report
// directory. Safe to call repeatedly; the newest write wins. Failures are
// silent because diagnostics must never affect the host process.
FOUNDATION_EXPORT void MTRuntimeABIReportFlush(NSString *profileID);

NS_ASSUME_NONNULL_END
