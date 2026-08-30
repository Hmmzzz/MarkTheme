#import "MTRuntimeABIReport.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <notify.h>
#import <os/log.h>
#import <sys/socket.h>
#import <sys/utsname.h>
#import <time.h>
#import <unistd.h>

#import "MTRuntimeDiagnosticsProtocol.h"
#import "adapters/MTApplicationIconNativeInvalidation.h"
#import "adapters/MTBadgeNativeSourceAdapter.h"
#import "adapters/MTCalendarApplicationIconAdapter.h"
#import "adapters/MTCalendarUIKitSourceAdapter.h"
#import "adapters/MTClockNativeSourceAdapter.h"
#import "adapters/MTDialerButtonAdapter.h"
#import "adapters/MTFolderNativeSourceAdapter.h"
#import "adapters/MTIconShadowCarrierAdapter.h"
#import "adapters/MTIconMorphCarrierAdapter.h"
#import "adapters/MTNotificationIconSourceAdapter.h"
#import "adapters/MTRuntimeImageABI.h"
#import "adapters/MTPreferencesUIResourceImageAdapter.h"
#import "adapters/MTSearchUICalendarIconAdapter.h"
#import "adapters/MTShareSheetActivityGlyphAdapter.h"
#import "adapters/MTStatusBarSignalImageAdapter.h"
#import "modules/MTDialerSnapshotModule.h"
#import "modules/MTCalendarIconRenderer.h"
#import "modules/MTClockIconSnapshotModule.h"
#import "modules/MTIconMaskSnapshotModule.h"
#import "modules/MTIconOverlaySnapshotModule.h"
#import "modules/MTIconShadowSnapshotModule.h"
#import "modules/MTBadgeSnapshotModule.h"
#import "modules/MTFolderIconSnapshotModule.h"
#import "modules/MTStaticIconSnapshotModule.h"
#import "modules/MTStatusBarSnapshotModule.h"
#import "modules/MTUIResourceSnapshotModule.h"

#include <stdatomic.h>
#include <string.h>

#if !defined(MARKTHEME_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME_RUNTIME_BUILD_NUMBER must identify diagnostic Runtime code"
#endif

static const int64_t MTReportLiveFlushDelayNanoseconds =
    2LL * NSEC_PER_SEC;
static const int64_t MTReportTransportHeartbeatNanoseconds =
    3LL * NSEC_PER_SEC;

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
static BOOL MTTransportHeartbeatScheduled;
static int MTTransportRequestToken = NOTIFY_TOKEN_INVALID;
static NSDictionary<NSString *, id> *MTLastTransportPayload;
static uint32_t MTLastTransportNonce;

static void MTScheduleLiveFlushLocked(void);
static void MTScheduleTransportHeartbeatLocked(void);

static os_log_t MTDiagnosticsTransportLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.hmmzzz.marktheme", "diagnostics-transport");
    });
    return log;
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

#define MT_REPORT_ATOMIC_VALUE(value) \
    @(atomic_load_explicit(&(value), memory_order_relaxed))

static NSDictionary<NSString *, NSArray<NSNumber *> *> *
MTLiveObservationRecords(void) {
    MTApplicationIconNativeInvalidationObservation *nativeIcon =
        &MTRuntimeApplicationIconNativeInvalidationObservation;
    MTNotificationIconSourceAdapterObservation *notificationSource =
        &MTRuntimeNotificationIconSourceAdapterObservation;
    MTCalendarApplicationIconAdapterObservation *calendar =
        &MTRuntimeCalendarApplicationIconAdapterObservation;
    MTCalendarUIKitSourceAdapterObservation *calendarSource =
        &MTRuntimeCalendarUIKitSourceAdapterObservation;
    MTCalendarIconRendererObservation *calendarRender =
        &MTRuntimeCalendarIconRendererObservation;
    MTClockNativeSourceAdapterObservation *clockSource =
        &MTRuntimeClockNativeSourceAdapterObservation;
    MTClockIconSnapshotObservation *clock =
        &MTRuntimeClockIconSnapshotObservation;
    MTDialerButtonAdapterObservation *dialerSource =
        &MTRuntimeDialerButtonAdapterObservation;
    MTDialerSnapshotObservation *dialer =
        &MTRuntimeDialerSnapshotObservation;
    MTFolderNativeSourceAdapterObservation *folderSource =
        &MTRuntimeFolderNativeSourceAdapterObservation;
    MTBadgeNativeSourceAdapterObservation *badgeSource =
        &MTRuntimeBadgeNativeSourceAdapterObservation;
    MTPreferencesUIResourceImageAdapterObservation *preferencesSource =
        &MTRuntimePreferencesUIResourceImageAdapterObservation;
    MTSearchUICalendarIconAdapterObservation *searchCalendar =
        &MTRuntimeSearchUICalendarIconAdapterObservation;
    MTShareSheetActivityGlyphAdapterObservation *shareGlyph =
        &MTRuntimeShareSheetActivityGlyphAdapterObservation;
    MTStatusBarSignalImageAdapterObservation *statusBarSource =
        &MTRuntimeStatusBarSignalImageAdapterObservation;
    MTStatusBarSnapshotObservation *statusBar =
        &MTRuntimeStatusBarSnapshotObservation;
    MTIconShadowCarrierAdapterObservation *shadowCarrier =
        &MTRuntimeIconShadowCarrierAdapterObservation;
    MTIconShadowSnapshotObservation *shadow =
        &MTRuntimeIconShadowSnapshotObservation;
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
    MTUIResourceSnapshotObservation *uiResources =
        &MTRuntimeUIResourceSnapshotObservation;
    // Compact observation schemas use fixed arrays so the injected image does
    // not carry every display label. The Manager expands these positions into
    // readable names.
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
        @"notificationSource" : @[
            MT_REPORT_ATOMIC_VALUE(notificationSource->state),
            MT_REPORT_ATOMIC_VALUE(notificationSource->installAttempts),
            MT_REPORT_ATOMIC_VALUE(notificationSource->totalCalls),
            MT_REPORT_ATOMIC_VALUE(notificationSource->identityResults),
            MT_REPORT_ATOMIC_VALUE(notificationSource->resolverCalls),
            MT_REPORT_ATOMIC_VALUE(notificationSource->replacementResults),
            MT_REPORT_ATOMIC_VALUE(notificationSource->mappedCacheClears),
            MT_REPORT_ATOMIC_VALUE(notificationSource->contractRejects),
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
        @"calendarRender" : @[
            MT_REPORT_ATOMIC_VALUE(calendarRender->renderAttempts),
            MT_REPORT_ATOMIC_VALUE(calendarRender->renderSuccesses),
            MT_REPORT_ATOMIC_VALUE(calendarRender->renderFailures),
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
        @"clock" : @[
            MT_REPORT_ATOMIC_VALUE(clock->state),
            MT_REPORT_ATOMIC_VALUE(clock->reloads),
            MT_REPORT_ATOMIC_VALUE(clock->resourceRequests),
            MT_REPORT_ATOMIC_VALUE(clock->resourceHits),
            MT_REPORT_ATOMIC_VALUE(clock->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(clock->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(clock->imageSetPublishes),
            MT_REPORT_ATOMIC_VALUE(clock->componentMatchRequests),
            MT_REPORT_ATOMIC_VALUE(clock->componentMatchResults),
            MT_REPORT_ATOMIC_VALUE(clock->staleResultsDiscarded),
        ],
        @"dialerSource" : @[
            MT_REPORT_ATOMIC_VALUE(dialerSource->state),
            MT_REPORT_ATOMIC_VALUE(dialerSource->installAttempts),
            MT_REPORT_ATOMIC_VALUE(dialerSource->numberSourceCalls),
            MT_REPORT_ATOMIC_VALUE(dialerSource->numberNormalCalls),
            MT_REPORT_ATOMIC_VALUE(dialerSource->numberHighlightedCalls),
            MT_REPORT_ATOMIC_VALUE(dialerSource->circleAlphaCalls),
            MT_REPORT_ATOMIC_VALUE(dialerSource->circleSuppressions),
            MT_REPORT_ATOMIC_VALUE(dialerSource->callButtonCreations),
            MT_REPORT_ATOMIC_VALUE(
                dialerSource->callNormalReplacements),
            MT_REPORT_ATOMIC_VALUE(dialerSource->callOverlayRequests),
            MT_REPORT_ATOMIC_VALUE(
                dialerSource->callPressedReplacements),
            MT_REPORT_ATOMIC_VALUE(dialerSource->resolverMisses),
            MT_REPORT_ATOMIC_VALUE(dialerSource->contractRejects),
        ],
        @"dialer" : @[
            MT_REPORT_ATOMIC_VALUE(dialer->state),
            MT_REPORT_ATOMIC_VALUE(dialer->reloads),
            MT_REPORT_ATOMIC_VALUE(dialer->imageRequests),
            MT_REPORT_ATOMIC_VALUE(dialer->contractRejects),
            MT_REPORT_ATOMIC_VALUE(dialer->resourceHits),
            MT_REPORT_ATOMIC_VALUE(dialer->cacheHits),
            MT_REPORT_ATOMIC_VALUE(dialer->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(dialer->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(dialer->replacementResults),
            MT_REPORT_ATOMIC_VALUE(dialer->completeSetChecks),
            MT_REPORT_ATOMIC_VALUE(dialer->completeSetPasses),
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
        @"preferencesSource" : @[
            MT_REPORT_ATOMIC_VALUE(preferencesSource->state),
            MT_REPORT_ATOMIC_VALUE(preferencesSource->installAttempts),
            MT_REPORT_ATOMIC_VALUE(preferencesSource->totalCalls),
            MT_REPORT_ATOMIC_VALUE(preferencesSource->stringKeys),
            MT_REPORT_ATOMIC_VALUE(preferencesSource->nilOriginalResults),
            MT_REPORT_ATOMIC_VALUE(preferencesSource->replacementResults),
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
        @"statusBarSource" : @[
            MT_REPORT_ATOMIC_VALUE(statusBarSource->state),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->installAttempts),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->wifiCommitCalls),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->cellularCommitCalls),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->mainThreadCalls),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->resolverCalls),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->appliedResults),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->stockFallbacks),
            MT_REPORT_ATOMIC_VALUE(statusBarSource->contractRejects),
        ],
        @"statusBar" : @[
            MT_REPORT_ATOMIC_VALUE(statusBar->state),
            MT_REPORT_ATOMIC_VALUE(statusBar->reloads),
            MT_REPORT_ATOMIC_VALUE(statusBar->nativeCommitRequests),
            MT_REPORT_ATOMIC_VALUE(statusBar->contextRequests),
            MT_REPORT_ATOMIC_VALUE(statusBar->contextMisses),
            MT_REPORT_ATOMIC_VALUE(statusBar->resourceHits),
            MT_REPORT_ATOMIC_VALUE(statusBar->cacheHits),
            MT_REPORT_ATOMIC_VALUE(statusBar->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(statusBar->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(statusBar->replacementResults),
            MT_REPORT_ATOMIC_VALUE(statusBar->stockRestores),
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
        @"shadow" : @[
            MT_REPORT_ATOMIC_VALUE(shadow->state),
            MT_REPORT_ATOMIC_VALUE(shadow->preparationAttempts),
            MT_REPORT_ATOMIC_VALUE(shadow->resourceHits),
            MT_REPORT_ATOMIC_VALUE(shadow->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(shadow->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(shadow->carrierResolutions),
            MT_REPORT_ATOMIC_VALUE(shadow->attachmentsCreated),
            MT_REPORT_ATOMIC_VALUE(shadow->attachmentUpdates),
            MT_REPORT_ATOMIC_VALUE(shadow->attachmentsRemoved),
            MT_REPORT_ATOMIC_VALUE(shadow->contextMisses),
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
        @"uiResources" : @[
            MT_REPORT_ATOMIC_VALUE(uiResources->state),
            MT_REPORT_ATOMIC_VALUE(uiResources->lookupCalls),
            MT_REPORT_ATOMIC_VALUE(uiResources->snapshotMisses),
            MT_REPORT_ATOMIC_VALUE(uiResources->resourceHits),
            MT_REPORT_ATOMIC_VALUE(uiResources->cacheHits),
            MT_REPORT_ATOMIC_VALUE(uiResources->decodeSuccesses),
            MT_REPORT_ATOMIC_VALUE(uiResources->decodeFailures),
            MT_REPORT_ATOMIC_VALUE(uiResources->replacementResults),
            MT_REPORT_ATOMIC_VALUE(uiResources->memoryPressurePurges),
        ],
    };
}

#undef MT_REPORT_ATOMIC_VALUE

static NSDictionary<NSString *, id> *MTReportPayloadLocked(
    NSString *profile) {
    struct utsname systemInfo = {0};
    uname(&systemInfo);
    return @{
        @"schemaVersion" : @3,
        @"runtimeBuild" : @(MARKTHEME_RUNTIME_BUILD_NUMBER),
        @"processIdentifier" :
            @(NSProcessInfo.processInfo.processIdentifier),
        @"profile" : profile,
        @"process" : NSProcessInfo.processInfo.processName ?: @"unknown",
        // Compatibility remains a pure capability probe. Build and snapshot
        // values are evidence only and never gate Hook installation.
        @"systemVersion" :
            NSProcessInfo.processInfo.operatingSystemVersionString ?: @"",
        @"machine" :
            [NSString stringWithUTF8String:systemInfo.machine] ?: @"",
        @"adapters" : [MTAdapterStates() copy],
        @"modules" : [MTModuleStates() copy],
        @"contracts" : [MTContractRecords() copy],
        @"runtime" : MTRuntimeSnapshotRecord ?: @{},
        @"observationSchema" : @8,
        @"observations" : MTLiveObservationRecords(),
        @"samples" : [MTLatestDataPlaneSamples copy] ?: @{},
    };
}

static NSData *_Nullable MTTransportDataForPayload(
    NSDictionary<NSString *, id> *payload,
    uint32_t nonce) {
    NSMutableDictionary<NSString *, id> *report = [payload mutableCopy];
    report[@"generatedAt"] = [[[NSISO8601DateFormatter alloc] init]
        stringFromDate:NSDate.date] ?: @"";
    NSMutableDictionary<NSString *, id> *transport = [@{
        @"schemaVersion" : @1,
        @"method" : @"loopback-udp",
        @"nonce" : @(nonce),
    } mutableCopy];
    report[@"transport"] = transport;

    __block NSError *error = nil;
    NSData *(^serialize)(void) = ^NSData *{
        return [NSJSONSerialization dataWithJSONObject:report
            options:NSJSONWritingSortedKeys error:&error];
    };
    NSData *data = serialize();
    if (data != nil &&
        data.length <= MTRuntimeDiagnosticsMaximumDatagramByteCount) {
        return data;
    }

    NSArray<NSDictionary<NSString *, id> *> *contracts =
        [report[@"contracts"] isKindOfClass:NSArray.class]
            ? report[@"contracts"] : @[];
    NSMutableArray<NSDictionary<NSString *, id> *> *failures =
        [NSMutableArray array];
    for (id value in contracts) {
        if ([value isKindOfClass:NSDictionary.class] &&
            ![value[@"satisfied"] boolValue]) {
            [failures addObject:value];
        }
    }
    report[@"contracts"] = failures;
    report[@"contractSummary"] = @{
        @"total" : @(contracts.count),
        @"failures" : @(failures.count),
        @"satisfiedContractsOmitted" :
            @(contracts.count - failures.count),
    };
    transport[@"truncatedSatisfiedContracts"] = @YES;
    error = nil;
    data = serialize();
    if (data != nil &&
        data.length <= MTRuntimeDiagnosticsMaximumDatagramByteCount) {
        return data;
    }

    report[@"samples"] = @{};
    transport[@"truncatedSamples"] = @YES;
    error = nil;
    data = serialize();
    if (data != nil &&
        data.length <= MTRuntimeDiagnosticsMaximumDatagramByteCount) {
        return data;
    }
    os_log_with_type(MTDiagnosticsTransportLog(), OS_LOG_TYPE_ERROR,
        "report serialization exceeded datagram boundary profile=%{public}@ "
        "bytes=%{public}lu error=%{public}@/%{public}ld",
        payload[@"profile"] ?: @"unknown", (unsigned long)data.length,
        error.domain ?: @"none", (long)error.code);
    return nil;
}

static BOOL MTActiveCollectionRequestLocked(
    MTRuntimeDiagnosticsCollectionRequest *requestOut) {
    if (MTTransportRequestToken == NOTIFY_TOKEN_INVALID) return NO;
    uint64_t word = 0;
    if (notify_get_state(MTTransportRequestToken, &word) !=
        NOTIFY_STATUS_OK) {
        return NO;
    }
    return MTRuntimeDiagnosticsDecodeCollectionRequestWord(
        word, (uint64_t)time(NULL), requestOut);
}

static BOOL MTSendActiveReportIfRequestedLocked(BOOL force) {
    if (MTActiveProfileID.length == 0) return NO;
    MTRuntimeDiagnosticsCollectionRequest request = {0};
    if (!MTActiveCollectionRequestLocked(&request)) return NO;
    NSDictionary<NSString *, id> *payload =
        MTReportPayloadLocked(MTActiveProfileID);
    if (!force && request.nonce == MTLastTransportNonce &&
        [payload isEqualToDictionary:MTLastTransportPayload]) {
        return YES;
    }
    NSData *data = MTTransportDataForPayload(payload, request.nonce);
    if (data == nil) return NO;

    int socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socketDescriptor < 0) {
        os_log_with_type(MTDiagnosticsTransportLog(), OS_LOG_TYPE_ERROR,
            "loopback socket failed profile=%{public}@ errno=%{public}d",
            MTActiveProfileID, errno);
        return NO;
    }
    struct sockaddr_in destination = {0};
    destination.sin_len = sizeof(destination);
    destination.sin_family = AF_INET;
    destination.sin_port = htons(request.port);
    destination.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ssize_t sent = sendto(socketDescriptor, data.bytes, data.length, 0,
        (const struct sockaddr *)&destination, sizeof(destination));
    int sendError = sent == (ssize_t)data.length ? 0 : errno;
    close(socketDescriptor);
    if (sendError != 0) {
        os_log_with_type(MTDiagnosticsTransportLog(), OS_LOG_TYPE_ERROR,
            "loopback report failed profile=%{public}@ errno=%{public}d",
            MTActiveProfileID, sendError);
        return NO;
    }
    MTLastTransportPayload = payload;
    MTLastTransportNonce = request.nonce;
    return YES;
}

static void MTEnsureTransportRegistrationLocked(void) {
    if (MTTransportRequestToken != NOTIFY_TOKEN_INVALID) return;
    int token = NOTIFY_TOKEN_INVALID;
    int result = notify_register_dispatch(
        MTRuntimeDiagnosticsCollectionRequestNotificationName.UTF8String,
        &token, MTReportQueue(), ^(__unused int callbackToken) {
            (void)MTSendActiveReportIfRequestedLocked(YES);
            MTScheduleTransportHeartbeatLocked();
        });
    if (result == NOTIFY_STATUS_OK) {
        MTTransportRequestToken = token;
    } else {
        os_log_with_type(MTDiagnosticsTransportLog(), OS_LOG_TYPE_ERROR,
            "collection request registration failed status=%{public}d",
            result);
    }
}

static void MTScheduleLiveFlushLocked(void) {
    if (MTActiveProfileID.length == 0 || MTLiveFlushScheduled) return;
    MTRuntimeDiagnosticsCollectionRequest request = {0};
    if (!MTActiveCollectionRequestLocked(&request)) return;
    MTLiveFlushScheduled = YES;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      MTReportLiveFlushDelayNanoseconds),
        MTReportQueue(), ^{
            MTLiveFlushScheduled = NO;
            if (MTActiveProfileID.length > 0) {
                (void)MTSendActiveReportIfRequestedLocked(NO);
            }
        });
}

static void MTScheduleTransportHeartbeatLocked(void) {
    if (MTTransportHeartbeatScheduled) return;
    MTRuntimeDiagnosticsCollectionRequest request = {0};
    if (!MTActiveCollectionRequestLocked(&request)) return;
    MTTransportHeartbeatScheduled = YES;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      MTReportTransportHeartbeatNanoseconds),
        MTReportQueue(), ^{
            MTTransportHeartbeatScheduled = NO;
            if (MTActiveCollectionRequestLocked(NULL)) {
                (void)MTSendActiveReportIfRequestedLocked(NO);
                MTScheduleTransportHeartbeatLocked();
            }
        });
}

void MTRuntimeABIReportFlush(NSString *profileID) {
    NSString *profile = profileID.length > 0 ? [profileID copy] : @"unknown";
    dispatch_async(MTReportQueue(), ^{
        MTActiveProfileID = profile;
        MTEnsureTransportRegistrationLocked();
        (void)MTSendActiveReportIfRequestedLocked(NO);
        MTScheduleTransportHeartbeatLocked();
    });
}
