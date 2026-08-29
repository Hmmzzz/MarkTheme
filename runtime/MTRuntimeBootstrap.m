#import <Foundation/Foundation.h>

#import <os/log.h>

#include <stdint.h>
#include <stdatomic.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeProfile.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"
#import "adapters/MTRuntimeAdapterRegistry.h"

static NSString *const MTRuntimeImageID = @"runtime.system-ui";
static MTRuntimeKernel *MTRuntimeKernelInstance;
static atomic_bool MTRuntimeAdaptersInstalled;

static os_log_t MTRuntimeLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.hmmzzz.marktheme", "runtime");
    });
    return log;
}

static void MTRuntimeLogBootstrapFailure(NSString *stage,
                                         NSError * _Nullable error) {
    os_log_with_type(MTRuntimeLog(), OS_LOG_TYPE_ERROR,
        "M3-E bootstrap %{public}@ failed: %{public}@/%{public}ld",
        stage, error.domain ?: @"unknown", (long)error.code);
}

__attribute__((constructor))
static void MTRuntimeBootstrapEntry(void) {
    @autoreleasepool {
        NSError *error = nil;
        MTRuntimeProcessIdentity *identity =
            [MTRuntimeProcessIdentity currentIdentityWithError:&error];
        if (identity == nil) {
            MTRuntimeLogBootstrapFailure(@"identity", error);
            return;
        }
        MTRuntimeProfile *profile = MTRuntimeResolveProfile(
            identity, MTRuntimeImageID, &error);
        if (profile == nil) {
            if (error != nil) MTRuntimeLogBootstrapFailure(@"profile", error);
            return;
        }
        if (profile.mode != MTRuntimeProfileModeKernelOnly &&
            profile.mode != MTRuntimeProfileModeProcessAdapters) return;

        MTRuntimeSnapshotLoader *loader =
            [MTRuntimeSnapshotLoader defaultLoaderWithError:&error];
        if (loader == nil) {
            MTRuntimeLogBootstrapFailure(@"loader", error);
            return;
        }
        NSObject *refreshStateLock = [[NSObject alloc] init];
        __block uint64_t lastScheduledRefreshSequence = UINT64_MAX;
        __block uint64_t lastCompletedRefreshSequence = UINT64_MAX;
        __block __weak MTRuntimeKernel *weakKernel = nil;
        BOOL acknowledgementOwnerProfile =
            [profile.profileID isEqualToString:@"springboard.icons"];
        MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
            initWithLoader:loader
            notificationName:MTRuntimeInvalidationNotificationName
            reloadHandler:^(MTRuntimeReloadDisposition disposition,
                            MTRuntimeSnapshot *snapshot,
                            NSError *reloadError) {
                if (disposition ==
                    MTRuntimeReloadDispositionRetainedAfterFailure) {
                    MTRuntimeLogBootstrapFailure(@"reload", reloadError);
                    return;
                }
                MTRuntimeABIReportRecordRuntimeSnapshot(
                    snapshot.state.sequence,
                    snapshot.state.isRuntimeEnabled,
                    snapshot.isReady,
                    snapshot.state.activeGenerationIdentifier);
                BOOL ownerCanAcknowledge = acknowledgementOwnerProfile &&
                    atomic_load_explicit(
                        &MTRuntimeAdaptersInstalled,
                        memory_order_acquire);
                BOOL shouldScheduleRefresh = NO;
                BOOL refreshAlreadyCompleted = NO;
                @synchronized (refreshStateLock) {
                    refreshAlreadyCompleted =
                        lastCompletedRefreshSequence ==
                            snapshot.state.sequence;
                    if (!refreshAlreadyCompleted &&
                        lastScheduledRefreshSequence !=
                            snapshot.state.sequence) {
                        lastScheduledRefreshSequence =
                            snapshot.state.sequence;
                        shouldScheduleRefresh = YES;
                    }
                }
                if (shouldScheduleRefresh) {
                    MTRuntimeKernel *strongKernel = weakKernel;
                    if (strongKernel != nil) {
                        MTRuntimeRefreshConfiguredAdapters(
                            profile, strongKernel, snapshot,
                            ^(BOOL verified) {
                                @synchronized (refreshStateLock) {
                                    if (verified &&
                                        (lastCompletedRefreshSequence ==
                                             UINT64_MAX ||
                                         snapshot.state.sequence >
                                             lastCompletedRefreshSequence)) {
                                        lastCompletedRefreshSequence =
                                            snapshot.state.sequence;
                                    }
                                    if (!verified &&
                                        lastScheduledRefreshSequence ==
                                            snapshot.state.sequence) {
                                        // A repeated delivery may retry a
                                        // failed native-owner transaction.
                                        lastScheduledRefreshSequence =
                                            UINT64_MAX;
                                    }
                                }
                                if (ownerCanAcknowledge && verified) {
                                    (void)MTRuntimePostAcknowledgement(
                                        snapshot.state.sequence);
                                }
                            });
                    }
                } else if (ownerCanAcknowledge &&
                           refreshAlreadyCompleted) {
                    // Only a transaction whose completion was recorded may
                    // acknowledge a repeated delivery. An in-flight duplicate
                    // remains silent until native owner invalidation finishes.
                    (void)MTRuntimePostAcknowledgement(
                        snapshot.state.sequence);
                }
                os_log_with_type(MTRuntimeLog(), OS_LOG_TYPE_DEFAULT,
                    "M3-E snapshot %{public}lu sequence=%{public}llu "
                    "profile=%{public}@",
                    (unsigned long)disposition,
                    (unsigned long long)snapshot.state.sequence,
                    profile.profileID);
            }];
        weakKernel = kernel;
        MTRuntimeKernelInstance = kernel;
        if (![kernel startSynchronouslyWithError:&error]) {
            // Keep the running Kernel on its canonical stock snapshot. A later
            // store notification can recover without loading any Hook against
            // a partially validated Generation.
            MTRuntimeLogBootstrapFailure(@"initial-snapshot", error);
        }
        MTRuntimeSnapshot *initialSnapshot = kernel.currentSnapshot;
        MTRuntimeABIReportRecordRuntimeSnapshot(
            initialSnapshot.state.sequence,
            initialSnapshot.state.isRuntimeEnabled,
            initialSnapshot.isReady,
            initialSnapshot.state.activeGenerationIdentifier);
        if (!MTRuntimeInstallConfiguredAdapters(profile, kernel, &error)) {
            MTRuntimeLogBootstrapFailure(@"adapters", error);
        } else {
            atomic_store_explicit(&MTRuntimeAdaptersInstalled, true,
                                  memory_order_release);
        }
        os_log_with_type(MTRuntimeLog(), OS_LOG_TYPE_DEFAULT,
            "M3-E runtime started profile=%{public}@ process=%{public}@ "
            "mode=%{public}lu",
            profile.profileID, identity.executableName,
            (unsigned long)profile.mode);

        // Adapters may defer installation to the main queue, so capture the
        // diagnostic report after that pass rather than from the constructor.
        NSString *profileID = profile.profileID;
        dispatch_async(dispatch_get_main_queue(), ^{
            MTRuntimeABIReportFlush(profileID);
        });
    }
}
