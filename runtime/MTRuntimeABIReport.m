#import "MTRuntimeABIReport.h"

#import <sys/utsname.h>

#import "MTBootstrapPaths.h"
#import "adapters/MTApplicationIconNativeInvalidation.h"
#import "adapters/MTBadgeNativeSourceAdapter.h"
#import "adapters/MTCalendarApplicationIconAdapter.h"
#import "adapters/MTCalendarUIKitSourceAdapter.h"
#import "adapters/MTClockNativeSourceAdapter.h"
#import "adapters/MTFolderNativeSourceAdapter.h"
#import "adapters/MTIconShadowCarrierAdapter.h"
#import "adapters/MTIconMorphCarrierAdapter.h"
#import "adapters/MTRuntimeImageABI.h"
#import "adapters/MTSearchUICalendarIconAdapter.h"
#import "adapters/MTShareSheetActivityGlyphAdapter.h"
#import "modules/MTIconMaskSnapshotModule.h"
#import "modules/MTIconOverlaySnapshotModule.h"
#import "modules/MTBadgeSnapshotModule.h"
#import "modules/MTFolderIconSnapshotModule.h"
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
    MTApplicationIconNativeInvalidationObservation *nativeIcon =
        &MTRuntimeApplicationIconNativeInvalidationObservation;
    MTCalendarApplicationIconAdapterObservation *calendar =
        &MTRuntimeCalendarApplicationIconAdapterObservation;
    MTCalendarUIKitSourceAdapterObservation *calendarSource =
        &MTRuntimeCalendarUIKitSourceAdapterObservation;
    MTClockNativeSourceAdapterObservation *clockSource =
        &MTRuntimeClockNativeSourceAdapterObservation;
    MTFolderNativeSourceAdapterObservation *folderSource =
        &MTRuntimeFolderNativeSourceAdapterObservation;
    MTBadgeNativeSourceAdapterObservation *badgeSource =
        &MTRuntimeBadgeNativeSourceAdapterObservation;
    MTSearchUICalendarIconAdapterObservation *searchCalendar =
        &MTRuntimeSearchUICalendarIconAdapterObservation;
    MTShareSheetActivityGlyphAdapterObservation *shareGlyph =
        &MTRuntimeShareSheetActivityGlyphAdapterObservation;
    MTIconShadowCarrierAdapterObservation *shadowCarrier =
        &MTRuntimeIconShadowCarrierAdapterObservation;
    MTIconMorphCarrierAdapterObservation *iconMorph =
        &MTRuntimeIconMorphCarrierAdapterObservation;
    MTStaticIconSnapshotObservation *staticIcons =
        &MTRuntimeStaticIconSnapshotObservation;
    MTIconMaskSnapshotObservation *iconMask =
        &MTRuntimeIconMaskSnapshotObservation;
    MTIconOverlaySnapshotObservation *iconOverlay =
        &MTRuntimeIconOverlaySnapshotObservation;
    MTIconOverlayDiagnosticsObservation *overlayDebug =
        &MTRuntimeIconOverlayDiagnosticsObservation;
    MTFolderIconSnapshotObservation *folderIcons =
        &MTRuntimeFolderIconSnapshotObservation;
    MTBadgeSnapshotObservation *badge =
        &MTRuntimeBadgeSnapshotObservation;
    // Schema 3 uses fixed arrays so the injected image does not carry every
    // display label. The Manager expands these positions into readable names.
    return @{
        @"nativeIcon" : @[
            MT_REPORT_ATOMIC_VALUE(nativeIcon->requests),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->verifiedRequests),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->launchServicesSignals),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->notificationCacheClears),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->preferencesReloads),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->shareSheetCacheClears),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->shareSheetReloads),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->failures),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->clientCacheInvalidations),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->clientRegisteredIcons),
            MT_REPORT_ATOMIC_VALUE(
                nativeIcon->clientRegistryEntriesRemoved),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->clientImageCachesCleared),
            MT_REPORT_ATOMIC_VALUE(
                nativeIcon->clientDescriptorBagsCleared),
            MT_REPORT_ATOMIC_VALUE(nativeIcon->shareSheetProvidersTracked),
        ],
        @"calendar" : @[
            MT_REPORT_ATOMIC_VALUE(calendar->installed),
            MT_REPORT_ATOMIC_VALUE(calendar->generatedCalls),
            MT_REPORT_ATOMIC_VALUE(calendar->appearanceReplacements),
        ],
        @"calendarSource" : @[
            MT_REPORT_ATOMIC_VALUE(calendarSource->state),
            MT_REPORT_ATOMIC_VALUE(calendarSource->calls),
            MT_REPORT_ATOMIC_VALUE(calendarSource->outOfScopeCalls),
            MT_REPORT_ATOMIC_VALUE(calendarSource->originalFailures),
            MT_REPORT_ATOMIC_VALUE(calendarSource->resolverMisses),
            MT_REPORT_ATOMIC_VALUE(calendarSource->rasterRejects),
            MT_REPORT_ATOMIC_VALUE(calendarSource->replacements),
        ],
        @"clockSource" : @[
            MT_REPORT_ATOMIC_VALUE(clockSource->state),
            MT_REPORT_ATOMIC_VALUE(clockSource->faceSourceCalls),
            MT_REPORT_ATOMIC_VALUE(clockSource->maskedFaceCalls),
            MT_REPORT_ATOMIC_VALUE(clockSource->unmaskedFaceCalls),
            MT_REPORT_ATOMIC_VALUE(clockSource->themedFaces),
            MT_REPORT_ATOMIC_VALUE(clockSource->handSourceCalls),
            MT_REPORT_ATOMIC_VALUE(clockSource->themedHandSets),
            MT_REPORT_ATOMIC_VALUE(clockSource->originalFailures),
            MT_REPORT_ATOMIC_VALUE(clockSource->resolverMisses),
            MT_REPORT_ATOMIC_VALUE(clockSource->contractRejects),
        ],
        @"folderSource" : @[
            MT_REPORT_ATOMIC_VALUE(folderSource->state),
            MT_REPORT_ATOMIC_VALUE(folderSource->sourceCalls),
            MT_REPORT_ATOMIC_VALUE(folderSource->nativeBackgroundCalls),
            MT_REPORT_ATOMIC_VALUE(folderSource->nilBackgroundCalls),
            MT_REPORT_ATOMIC_VALUE(folderSource->themedBackgrounds),
            MT_REPORT_ATOMIC_VALUE(folderSource->overlayActivations),
            MT_REPORT_ATOMIC_VALUE(folderSource->nativeFallbacks),
            MT_REPORT_ATOMIC_VALUE(folderSource->contractRejects),
        ],
        @"badgeSource" : @[
            MT_REPORT_ATOMIC_VALUE(badgeSource->state),
            MT_REPORT_ATOMIC_VALUE(badgeSource->installAttempts),
            MT_REPORT_ATOMIC_VALUE(badgeSource->sourceCalls),
            MT_REPORT_ATOMIC_VALUE(badgeSource->mainThreadCalls),
            MT_REPORT_ATOMIC_VALUE(badgeSource->nativeBackgroundCalls),
            MT_REPORT_ATOMIC_VALUE(badgeSource->themedBackgrounds),
            MT_REPORT_ATOMIC_VALUE(badgeSource->nativeFallbacks),
            MT_REPORT_ATOMIC_VALUE(badgeSource->contractRejects),
        ],
        @"searchCalendar" : @[
            MT_REPORT_ATOMIC_VALUE(searchCalendar->state),
            MT_REPORT_ATOMIC_VALUE(searchCalendar->calls),
            MT_REPORT_ATOMIC_VALUE(searchCalendar->replacements),
            MT_REPORT_ATOMIC_VALUE(searchCalendar->trackedImages),
            MT_REPORT_ATOMIC_VALUE(searchCalendar->refreshRequests),
            MT_REPORT_ATOMIC_VALUE(searchCalendar->refreshInvalidations),
        ],
        @"shareGlyph" : @[
            MT_REPORT_ATOMIC_VALUE(shareGlyph->state),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->installAttempts),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->requestCalls),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->deliveryCalls),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->applicationContexts),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->customContexts),
            MT_REPORT_ATOMIC_VALUE(
                shareGlyph->nativeApplicationBridgeResults),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->replacements),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->providersTracked),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->contextMisses),
            MT_REPORT_ATOMIC_VALUE(shareGlyph->contractRejects),
        ],
        @"shadowCarrier" : @[
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->state),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->installAttempts),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->layoutCalls),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->reuseCalls),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->mainThreadCalls),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->folderExclusions),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->resolverCalls),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->appliedResults),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->cleanupCalls),
            MT_REPORT_ATOMIC_VALUE(shadowCarrier->contractRejects),
        ],
        @"morph" : @[
            MT_REPORT_ATOMIC_VALUE(iconMorph->state),
            MT_REPORT_ATOMIC_VALUE(iconMorph->scopeUpdates),
            MT_REPORT_ATOMIC_VALUE(iconMorph->squareContentsCalls),
            MT_REPORT_ATOMIC_VALUE(iconMorph->eligibleCarriers),
            MT_REPORT_ATOMIC_VALUE(iconMorph->prepareCalls),
            MT_REPORT_ATOMIC_VALUE(iconMorph->proxyActivations),
            MT_REPORT_ATOMIC_VALUE(iconMorph->fadeSynchronizations),
            MT_REPORT_ATOMIC_VALUE(iconMorph->cleanups),
        ],
        @"folder" : @[
            MT_REPORT_ATOMIC_VALUE(folderIcons->state),
            MT_REPORT_ATOMIC_VALUE(folderIcons->reloads),
            MT_REPORT_ATOMIC_VALUE(folderIcons->baseResourceHits),
            MT_REPORT_ATOMIC_VALUE(folderIcons->lightResourceHits),
            MT_REPORT_ATOMIC_VALUE(folderIcons->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(folderIcons->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(folderIcons->backgroundResolutions),
            MT_REPORT_ATOMIC_VALUE(folderIcons->backgroundReplacements),
            MT_REPORT_ATOMIC_VALUE(folderIcons->overlayActivations),
        ],
        @"badge" : @[
            MT_REPORT_ATOMIC_VALUE(badge->state),
            MT_REPORT_ATOMIC_VALUE(badge->reloads),
            MT_REPORT_ATOMIC_VALUE(badge->lightResourceHits),
            MT_REPORT_ATOMIC_VALUE(badge->darkResourceHits),
            MT_REPORT_ATOMIC_VALUE(badge->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(badge->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(badge->nativeSourceResolutions),
            MT_REPORT_ATOMIC_VALUE(badge->appearanceSelections),
            MT_REPORT_ATOMIC_VALUE(badge->themedBackgrounds),
            MT_REPORT_ATOMIC_VALUE(badge->nativeFallbacks),
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
            MT_REPORT_ATOMIC_VALUE(iconMask->cacheHits),
            MT_REPORT_ATOMIC_VALUE(iconMask->compositions),
            MT_REPORT_ATOMIC_VALUE(iconMask->memoryPressurePurges),
            MT_REPORT_ATOMIC_VALUE(iconMask->cacheEvictions),
        ],
        // Field order: state, reloads, overlayResourceHits, decodeSuccesses,
        // decodeFailures, resolutionCalls, unsupportedCandidateMisses,
        // alreadyProcessedHits, cacheHits, compositions,
        // memoryPressurePurges, cacheEvictions.
        @"overlay" : @[
            MT_REPORT_ATOMIC_VALUE(iconOverlay->state),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->reloads),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->overlayResourceHits),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->resolutionCalls),
            MT_REPORT_ATOMIC_VALUE(
                iconOverlay->unsupportedCandidateMisses),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->alreadyProcessedHits),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->cacheHits),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->compositions),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->memoryPressurePurges),
            MT_REPORT_ATOMIC_VALUE(iconOverlay->cacheEvictions),
        ],
        @"overlayDebug" : @[
            MT_REPORT_ATOMIC_VALUE(overlayDebug->invalidRequestMisses),
            MT_REPORT_ATOMIC_VALUE(
                overlayDebug->imageSetUnavailableMisses),
            MT_REPORT_ATOMIC_VALUE(
                overlayDebug->candidateValidationMisses),
            MT_REPORT_ATOMIC_VALUE(
                overlayDebug->overlayUnavailableMisses),
            MT_REPORT_ATOMIC_VALUE(overlayDebug->compositionMisses),
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
        report[@"generatedAt"] = [[[NSISO8601DateFormatter alloc] init]
            stringFromDate:NSDate.date] ?: @"";
        report[@"processIdentifier"] =
            @(NSProcessInfo.processInfo.processIdentifier);
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
        report[@"observationSchema"] = @5;
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
        // One exact profile maps to one supported host identity. Reuse the
        // established filename so sandboxed system processes can atomically
        // replace a pre-created report instead of requiring a new directory
        // entry after every diagnostics schema migration.
        NSString *fileName = [profile stringByAppendingPathExtension:@"json"];
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
