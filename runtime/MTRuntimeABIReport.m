#import "MTRuntimeABIReport.h"

#import <sys/utsname.h>

#import "MTBootstrapPaths.h"
#import "adapters/MTRuntimeImageABI.h"

#include <string.h>

// The report is written from arbitrary host processes, so every access is
// serialized on a private queue and no host object is retained.
static dispatch_queue_t MTReportQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.hmmzzz.marktheme.abi-report", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableArray<NSDictionary<NSString *, id> *> *MTContractRecords(void) {
    static NSMutableArray<NSDictionary<NSString *, id> *> *records;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        records = [NSMutableArray array];
    });
    return records;
}

static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
MTAdapterStates(void) {
    static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *states;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = [NSMutableDictionary dictionary];
    });
    return states;
}

static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
MTModuleStates(void) {
    static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *states;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        states = [NSMutableDictionary dictionary];
    });
    return states;
}

void MTRuntimeABIReportRecordContract(NSString *adapterID,
                                      NSString *contractID,
                                      BOOL satisfied,
                                      NSString *expectedEncoding,
                                      NSString *actualEncoding) {
    if (adapterID.length == 0 || contractID.length == 0) return;
    NSMutableDictionary<NSString *, id> *record =
        [NSMutableDictionary dictionary];
    record[@"adapter"] = [adapterID copy];
    record[@"contract"] = [contractID copy];
    record[@"satisfied"] = @(satisfied);
    if (expectedEncoding != nil) record[@"expected"] = [expectedEncoding copy];
    // A nil actual encoding is meaningful: the selector or class is absent.
    record[@"actual"] = actualEncoding != nil
        ? (id)[actualEncoding copy] : (id)NSNull.null;
    dispatch_async(MTReportQueue(), ^{
        [MTContractRecords() addObject:record];
    });
}

void MTRuntimeABIReportRecordAdapterState(NSString *adapterID,
                                          uint32_t state,
                                          NSString *stateName) {
    if (adapterID.length == 0) return;
    NSDictionary<NSString *, id> *record = @{
        @"state" : @(state),
        @"stateName" : stateName.length > 0 ? [stateName copy] : @"unknown",
    };
    NSString *key = [adapterID copy];
    dispatch_async(MTReportQueue(), ^{
        MTAdapterStates()[key] = record;
    });
}

void MTRuntimeABIReportRecordModuleState(NSString *moduleID,
                                         uint32_t state,
                                         NSString *stateName) {
    if (moduleID.length == 0) return;
    NSDictionary<NSString *, id> *record = @{
        @"state" : @(state),
        @"stateName" : stateName.length > 0 ? [stateName copy] : @"unknown",
    };
    NSString *key = [moduleID copy];
    dispatch_async(MTReportQueue(), ^{
        MTModuleStates()[key] = record;
    });
}

BOOL MTRuntimeABIReportProbeMethodType(NSString *ownerID,
                                       NSString *contractID,
                                       Method method,
                                       const char *expectedEncoding) {
    const char *actual =
        method == NULL ? NULL : method_getTypeEncoding(method);
    BOOL satisfied = actual != NULL && expectedEncoding != NULL &&
        strcmp(actual, expectedEncoding) == 0;
    MTRuntimeABIReportRecordContract(
        ownerID, contractID, satisfied,
        expectedEncoding == NULL ? nil : @(expectedEncoding),
        actual == NULL ? nil : @(actual));
    return satisfied;
}

BOOL MTRuntimeABIReportProbePresence(NSString *ownerID,
                                     NSString *contractID,
                                     BOOL present) {
    MTRuntimeABIReportRecordContract(
        ownerID, contractID, present, nil, present ? @"present" : nil);
    return present;
}

BOOL MTRuntimeABIReportProbeImplementation(NSString *ownerID,
                                           NSString *contractID,
                                           IMP implementation) {
    const char *imageName =
        MTRuntimeImplementationImageName(implementation);
    BOOL hookable = imageName != NULL;
    NSString *actual = imageName == NULL ? nil : @(imageName);
    if (hookable && actual != nil &&
        !MTRuntimeImplementationMatchesSystemImagePath(implementation)) {
        actual = [actual stringByAppendingString:@" (third-party)"];
    }
    MTRuntimeABIReportRecordContract(
        ownerID, contractID, hookable,
        @"Apple system or third-party image (chained for coexistence)",
        actual);
    return hookable;
}

static NSURL *MTReportDirectoryURL(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    return [applicationSupport
        URLByAppendingPathComponent:@"MarkTheme/Diagnostics" isDirectory:YES];
#else
    NSString *path = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTDiagnosticsLogicalPath
                             error:NULL];
    return path == nil ? nil : [NSURL fileURLWithPath:path isDirectory:YES];
#endif
}

void MTRuntimeABIReportFlush(NSString *profileID) {
    NSString *profile = profileID.length > 0 ? [profileID copy] : @"unknown";
    dispatch_async(MTReportQueue(), ^{
        @autoreleasepool {
            NSURL *directory = MTReportDirectoryURL();
            if (directory == nil) return;
            struct utsname systemInfo = {0};
            uname(&systemInfo);
            NSMutableDictionary<NSString *, id> *report =
                [NSMutableDictionary dictionary];
            report[@"schemaVersion"] = @2;
            report[@"profile"] = profile;
            report[@"process"] =
                NSProcessInfo.processInfo.processName ?: @"unknown";
            // This string already carries the build number, so no kernel
            // state is read here. Compatibility must stay a pure capability
            // probe; the build identifier is diagnostic text only and is
            // never consulted when deciding whether to install a Hook.
            report[@"systemVersion"] =
                NSProcessInfo.processInfo.operatingSystemVersionString ?: @"";
            report[@"machine"] =
                [NSString stringWithUTF8String:systemInfo.machine] ?: @"";
            report[@"adapters"] = [MTAdapterStates() copy];
            report[@"modules"] = [MTModuleStates() copy];
            report[@"contracts"] = [MTContractRecords() copy];

            NSError *error = nil;
            NSData *data = [NSJSONSerialization
                dataWithJSONObject:report
                           options:NSJSONWritingPrettyPrinted |
                                   NSJSONWritingSortedKeys
                             error:&error];
            if (data == nil) return;
            [NSFileManager.defaultManager
                createDirectoryAtURL:directory
         withIntermediateDirectories:YES
                          attributes:nil
                               error:NULL];
            NSString *fileName =
                [NSString stringWithFormat:@"%@.json", profile];
            NSURL *fileURL =
                [directory URLByAppendingPathComponent:fileName];
            [data writeToURL:fileURL options:NSDataWritingAtomic error:NULL];
        }
    });
}
