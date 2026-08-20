#import "MTRuntimeABIReport.h"

#import <sys/utsname.h>

#import "MTBootstrapPaths.h"
#import "adapters/MTIconImageCacheAdapter.h"
#import "adapters/MTIconShadowViewAdapter.h"
#import "adapters/MTRuntimeImageABI.h"
#import "modules/MTIconMaskSnapshotModule.h"
#import "modules/MTStaticIconSnapshotModule.h"

#include <stdatomic.h>
#include <string.h>

#if !defined(MARKTHEME_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME_RUNTIME_BUILD_NUMBER must identify diagnostic Runtime code"
#endif

static const int64_t MTReportLiveFlushDelayNanoseconds =
    2LL * NSEC_PER_SEC;

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

static NSDictionary<NSString *, id> *MTRuntimeSnapshotRecord;
static NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *
    MTLatestDataPlaneSamples;
static NSString *MTActiveProfileID;
static BOOL MTLiveFlushScheduled;

static void MTScheduleLiveFlushLocked(void);

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

void MTRuntimeABIReportRecordRuntimeSnapshot(
    uint64_t sequence,
    BOOL runtimeEnabled,
    BOOL ready,
    NSString *generationIdentifier) {
    NSMutableDictionary<NSString *, id> *record = [@{
        @"sequence" : @(sequence),
        @"runtimeEnabled" : @(runtimeEnabled),
        @"ready" : @(ready),
    } mutableCopy];
    record[@"activeGenerationIdentifier"] =
        generationIdentifier.length > 0
            ? (id)[generationIdentifier copy] : (id)NSNull.null;
    dispatch_async(MTReportQueue(), ^{
        MTRuntimeSnapshotRecord = [record copy];
        MTScheduleLiveFlushLocked();
    });
}

void MTRuntimeABIReportRecordSample(
    NSString *groupID,
    NSDictionary<NSString *, id> *fields) {
    if (groupID.length == 0 ||
        ![fields isKindOfClass:NSDictionary.class] || fields.count == 0) {
        return;
    }
    NSString *group = [groupID copy];
    NSDictionary<NSString *, id> *sample = [fields copy];
    dispatch_async(MTReportQueue(), ^{
        if (MTLatestDataPlaneSamples == nil) {
            MTLatestDataPlaneSamples = [NSMutableDictionary dictionary];
        }
        MTLatestDataPlaneSamples[group] = sample;
        MTScheduleLiveFlushLocked();
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
    return [MTDefaultManagerDataRootURL()
        URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
}

#define MT_REPORT_ATOMIC_VALUE(value) \
    @(atomic_load_explicit(&(value), memory_order_relaxed))

static NSDictionary<NSString *, NSArray<NSNumber *> *> *
MTLiveObservationRecords(void) {
    MTIconImageCacheAdapterObservation *adapter =
        &MTRuntimeIconImageCacheAdapterObservation;
    MTIconShadowViewAdapterObservation *iconView =
        &MTRuntimeIconShadowViewAdapterObservation;
    MTStaticIconSnapshotObservation *staticIcons =
        &MTRuntimeStaticIconSnapshotObservation;
    MTIconMaskSnapshotObservation *iconMask =
        &MTRuntimeIconMaskSnapshotObservation;
    // Schema 1 uses fixed arrays so the injected image does not carry every
    // display label. The Manager expands these positions into readable names.
    return @{
        @"icon" : @[
            MT_REPORT_ATOMIC_VALUE(adapter->state),
            MT_REPORT_ATOMIC_VALUE(adapter->totalCalls),
            MT_REPORT_ATOMIC_VALUE(adapter->identityStringResults),
            MT_REPORT_ATOMIC_VALUE(adapter->resolverCalls),
            MT_REPORT_ATOMIC_VALUE(adapter->replacementResults),
            MT_REPORT_ATOMIC_VALUE(adapter->transitionCalls),
            MT_REPORT_ATOMIC_VALUE(adapter->transitionReplacements),
            MT_REPORT_ATOMIC_VALUE(adapter->cacheRequestCalls),
            MT_REPORT_ATOMIC_VALUE(adapter->cacheRequestRecipients),
            MT_REPORT_ATOMIC_VALUE(adapter->viewRecipientRecords),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshRequests),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshExecutions),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshCachePurges),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshIconPurges),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshObserverNotifications),
            MT_REPORT_ATOMIC_VALUE(adapter->refreshNativeRecaches),
        ],
        @"view" : @[
            MT_REPORT_ATOMIC_VALUE(iconView->state),
            MT_REPORT_ATOMIC_VALUE(iconView->configureCalls),
            MT_REPORT_ATOMIC_VALUE(iconView->imageInfoCalls),
            MT_REPORT_ATOMIC_VALUE(iconView->resolverCalls),
            MT_REPORT_ATOMIC_VALUE(iconView->appliedResults),
            MT_REPORT_ATOMIC_VALUE(iconView->refreshRequests),
            MT_REPORT_ATOMIC_VALUE(iconView->refreshExecutions),
        ],
        @"static" : @[
            MT_REPORT_ATOMIC_VALUE(staticIcons->state),
            MT_REPORT_ATOMIC_VALUE(staticIcons->lookupCalls),
            MT_REPORT_ATOMIC_VALUE(staticIcons->unsupportedOriginalMisses),
            MT_REPORT_ATOMIC_VALUE(staticIcons->snapshotMisses),
            MT_REPORT_ATOMIC_VALUE(staticIcons->resourceHits),
            MT_REPORT_ATOMIC_VALUE(staticIcons->cacheHits),
            MT_REPORT_ATOMIC_VALUE(staticIcons->decodeScheduled),
            MT_REPORT_ATOMIC_VALUE(staticIcons->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(staticIcons->decodeFailures),
        ],
        @"mask" : @[
            MT_REPORT_ATOMIC_VALUE(iconMask->state),
            MT_REPORT_ATOMIC_VALUE(iconMask->reloads),
            MT_REPORT_ATOMIC_VALUE(iconMask->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(iconMask->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(iconMask->resolutionCalls),
            MT_REPORT_ATOMIC_VALUE(iconMask->unsupportedCandidateMisses),
            MT_REPORT_ATOMIC_VALUE(iconMask->compositions),
        ],
    };
}

#undef MT_REPORT_ATOMIC_VALUE

static void MTWriteReportLocked(NSString *profile) {
    @autoreleasepool {
        NSURL *directory = MTReportDirectoryURL();
        if (directory == nil) return;
        struct utsname systemInfo = {0};
        uname(&systemInfo);
        NSMutableDictionary<NSString *, id> *report =
            [NSMutableDictionary dictionary];
        report[@"schemaVersion"] = @3;
        report[@"runtimeBuild"] = @(MARKTHEME_RUNTIME_BUILD_NUMBER);
        report[@"profile"] = profile;
        report[@"process"] =
            NSProcessInfo.processInfo.processName ?: @"unknown";
        // Compatibility remains a pure capability probe. Build and snapshot
        // values are evidence only and never gate Hook installation.
        report[@"systemVersion"] =
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"";
        report[@"machine"] =
            [NSString stringWithUTF8String:systemInfo.machine] ?: @"";
        report[@"adapters"] = [MTAdapterStates() copy];
        report[@"modules"] = [MTModuleStates() copy];
        report[@"contracts"] = [MTContractRecords() copy];
        report[@"runtime"] = MTRuntimeSnapshotRecord ?: @{};
        report[@"observationSchema"] = @1;
        report[@"observations"] = MTLiveObservationRecords();
        report[@"samples"] = [MTLatestDataPlaneSamples copy] ?: @{};

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
}

static void MTScheduleLiveFlushLocked(void) {
    if (MTActiveProfileID.length == 0 || MTLiveFlushScheduled) return;
    MTLiveFlushScheduled = YES;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      MTReportLiveFlushDelayNanoseconds),
        MTReportQueue(), ^{
            MTLiveFlushScheduled = NO;
            if (MTActiveProfileID.length > 0) {
                MTWriteReportLocked(MTActiveProfileID);
            }
        });
}

void MTRuntimeABIReportFlush(NSString *profileID) {
    NSString *profile = profileID.length > 0 ? [profileID copy] : @"unknown";
    dispatch_async(MTReportQueue(), ^{
        MTActiveProfileID = profile;
        MTWriteReportLocked(profile);
    });
}
