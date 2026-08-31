#import <Foundation/Foundation.h>

#import <os/log.h>

#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeProfile.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeSnapshotLoader.h"
#import "MTRuntimeState.h"
#import "adapters/MTRuntimeAdapterRegistry.h"

static NSString *const MTRuntimeImageID = @"runtime.system-ui";
static MTRuntimeKernel *MTRuntimeKernelInstance;

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
        if (profile.mode != MTRuntimeProfileModeProcessAdapters) return;

        MTRuntimeSnapshotLoader *loader =
            [MTRuntimeSnapshotLoader defaultLoaderWithError:&error];
        if (loader == nil) {
            MTRuntimeLogBootstrapFailure(@"loader", error);
            return;
        }
        MTRuntimeSnapshot *snapshot = [loader loadSnapshotWithError:&error];
        if (snapshot == nil) {
            MTRuntimeLogBootstrapFailure(@"initial-snapshot", error);
            snapshot = MTRuntimeSnapshot.stockSnapshot;
        }
        MTRuntimeKernel *kernel = [[MTRuntimeKernel alloc]
            initWithSnapshot:snapshot];
        MTRuntimeKernelInstance = kernel;
        MTRuntimeABIReportRecordRuntimeSnapshot(
            snapshot.state.sequence,
            snapshot.state.isRuntimeEnabled,
            snapshot.isReady,
            snapshot.state.activeGenerationIdentifier);
        if (!MTRuntimeInstallConfiguredAdapters(profile, kernel, &error)) {
            MTRuntimeLogBootstrapFailure(@"adapters", error);
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
