#import "MTRuntimeAdapterRegistry.h"

#import "MTApplicationIconNativeInvalidation.h"
#import "MTBadgeBackgroundImageAdapter.h"
#import "MTCalendarApplicationIconAdapter.h"
#import "MTCalendarUIKitSourceAdapter.h"
#import "MTClockImageSetAdapter.h"
#import "MTDialerButtonAdapter.h"
#import "MTFolderBackgroundImageAdapter.h"
#import "MTGenerationReader.h"
#import "MTIconShadowViewAdapter.h"
#import "MTIconMorphCarrierAdapter.h"
#import "MTPreferencesUIResourceImageAdapter.h"
#import "MTSearchUICalendarIconAdapter.h"
#import "MTShareSheetActivityGlyphAdapter.h"
#import "MTStatusBarSignalImageAdapter.h"
#import "MTApplicationIconInvalidationScope.h"
#import "MTRuntimeABIReport.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeProfile.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeFeatureState.h"
#import "modules/MTBadgeSnapshotModule.h"
#import "modules/MTCalendarIconSnapshotResolver.h"
#import "modules/MTClockIconSnapshotModule.h"
#import "modules/MTDialerSnapshotModule.h"
#import "modules/MTFolderIconSnapshotModule.h"
#import "modules/MTIconMaskSnapshotModule.h"
#import "modules/MTIconOverlaySnapshotModule.h"
#import "modules/MTIconShadowSnapshotModule.h"
#import "modules/MTStaticIconSnapshotModule.h"
#import "modules/MTStatusBarSnapshotModule.h"
#import "modules/MTUIResourceSnapshotModule.h"

NSString *const MTRuntimeAdapterRegistryErrorDomain =
    @"com.hmmzzz.marktheme.runtime-adapter-registry";

static NSString *const MTSpringBoardProfileID = @"springboard.icons";
static NSString *const MTPreferencesProfileID = @"preferences.ui-icons";
static NSString *const MTSpotlightProfileID = @"spotlight.application-icons";
static NSString *const MTDialerProfileID = @"mobilephone.dialer";
static NSSet<NSString *> *MTPreviousApplicationIconIdentifiers;
static BOOL MTPreviousApplicationIconAppearanceWasGlobal;
static NSString *MTPreviousApplicationIconOwnerFingerprint;

static NSArray<NSString *> *MTSpringBoardAdapterIDs(void) {
    return @[
        @"springboard.application-icon-native-invalidation",
        @"springboard.icon-morph-carrier",
        @"calendar-ui-kit.dynamic-icon-source",
        @"springboard.calendar-appearance",
        @"springboard.clock-image-set",
        @"springboard.folder-image",
        @"springboard.badge-background",
        @"springboard.icon-shadow",
        @"springboard.statusbar-signal-image",
    ];
}

static NSArray<NSString *> *MTSpringBoardModuleIDs(void) {
    return @[
        @"static-icons.snapshot",
        @"calendar-icons.composite",
        @"clock-icons.snapshot",
        @"icon-mask.snapshot",
        @"icon-overlay.snapshot",
        @"folder-icons.snapshot",
        @"badges.snapshot",
        @"icon-shadow.snapshot",
        @"statusbar.snapshot",
    ];
}

static NSArray<NSString *> *MTPreferencesAdapterIDs(void) {
    return @[
        @"preferences.ui-resource-image",
        @"preferences.application-icon-native-invalidation",
    ];
}

static NSArray<NSString *> *MTShareSheetAdapterIDs(void) {
    return @[
        @"share-sheet.activity-glyph",
        @"share-sheet.application-icon-native-invalidation",
    ];
}

static NSArray<NSString *> *MTSpotlightAdapterIDs(void) {
    return @[
        @"spotlight.application-icon-native-invalidation",
        @"springboard.clock-image-set",
        @"calendar-ui-kit.dynamic-icon-source",
        @"spotlight.calendar-appearance",
    ];
}

static NSArray<NSString *> *MTSpotlightModuleIDs(void) {
    return @[
        @"static-icons.snapshot",
        @"calendar-icons.composite",
        @"clock-icons.snapshot",
        @"icon-mask.snapshot",
        @"icon-overlay.snapshot",
    ];
}

static BOOL MTProfileMatches(MTRuntimeProfile *profile,
                             NSString *profileID,
                             NSArray<NSString *> *adapterIDs,
                             NSArray<NSString *> *moduleIDs) {
    return [profile.profileID isEqualToString:profileID] &&
        [profile.adapterIDs isEqualToArray:adapterIDs] &&
        [profile.moduleIDs isEqualToArray:moduleIDs];
}

static BOOL MTSpringBoardProfileMatches(MTRuntimeProfile *profile) {
    return MTProfileMatches(
        profile, MTSpringBoardProfileID,
        MTSpringBoardAdapterIDs(), MTSpringBoardModuleIDs());
}

static BOOL MTPreferencesProfileMatches(MTRuntimeProfile *profile) {
    return MTProfileMatches(
        profile, MTPreferencesProfileID,
        MTPreferencesAdapterIDs(), @[ @"ui-resources.snapshot" ]);
}

static BOOL MTShareSheetProfileMatches(MTRuntimeProfile *profile) {
    BOOL supported =
        [profile.profileID isEqualToString:@"share-sheet.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"share-sheet.loaded-host.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"sharingd.share-sheet.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"photos.share-sheet.ui-icons"];
    return supported &&
        [profile.adapterIDs isEqualToArray:MTShareSheetAdapterIDs()] &&
        [profile.moduleIDs
            isEqualToArray:@[ @"ui-resources.snapshot" ]];
}

static BOOL MTSpotlightProfileMatches(MTRuntimeProfile *profile) {
    return MTProfileMatches(
        profile, MTSpotlightProfileID,
        MTSpotlightAdapterIDs(), MTSpotlightModuleIDs());
}

static BOOL MTDialerProfileMatches(MTRuntimeProfile *profile) {
    return MTProfileMatches(
        profile, MTDialerProfileID,
        @[ @"mobilephone.dialer-buttons" ],
        @[ @"dialer.snapshot" ]);
}

static void MTSetError(NSError **error,
                       MTRuntimeAdapterRegistryErrorCode code,
                       NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTRuntimeAdapterRegistryErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

// Dynamic Calendar stays outside iconservicesagent's persistent app cache.
// CalendarUIKit now owns its single raw-pixel replacement; only final
// mask/overlay semantics remain in SpringBoard and Spotlight.
static id MTCalendarAppearanceResolve(NSString *bundleIdentifier,
                                      CGSize pointSize,
                                      CGFloat scale,
                                      id originalResult) {
    if (originalResult == nil) return nil;
    id masked = MTIconMaskSnapshotResolveSystemSurface(
        bundleIdentifier, originalResult, originalResult,
        pointSize, scale);
    id carrier = masked ?: originalResult;
    id overlaid = MTIconOverlaySnapshotResolveSystemSurface(
        bundleIdentifier, carrier, pointSize, scale);
    return masked == nil ? overlaid : (overlaid ?: masked);
}

// Clock has not migrated yet, so it still resolves its static face before
// applying the shared mask/overlay appearance modules.
static id MTClockAppearanceResolve(NSString *bundleIdentifier,
                                   id originalResult) {
    id source = MTStaticIconSnapshotResolve(
        bundleIdentifier, originalResult);
    BOOL usesSystemMask = MTIconMaskSnapshotUsesSystemMask();
    id appearance = nil;
    if (!usesSystemMask || source != nil) {
        id candidate = source ?: originalResult;
        id masked = MTIconMaskSnapshotResolve(
            bundleIdentifier, candidate, originalResult);
        appearance = usesSystemMask ? masked : (masked ?: source);
    }
    id overlaid = MTIconOverlaySnapshotResolve(
        bundleIdentifier, appearance ?: originalResult);
    return overlaid ?: appearance;
}

static BOOL MTCalendarSourceModulesPrepare(void) {
    return MTStaticIconSnapshotPrepare();
}

static BOOL MTCalendarAppearanceModulesPrepare(void) {
    return MTIconMaskSnapshotPrepare() &&
        MTIconOverlaySnapshotPrepare();
}

static BOOL MTClockModulesPrepare(void) {
    return MTStaticIconSnapshotPrepare() && MTIconMaskSnapshotPrepare() &&
        MTIconOverlaySnapshotPrepare();
}

static NSSet<NSString *> *MTCurrentApplicationIconIdentifiers(
    MTRuntimeKernel *kernel,
    BOOL globalAppearance) {
    NSSet<NSString *> *installed =
        MTApplicationIconNativeInvalidationInstalledBundleIdentifiers();
    if (installed == nil || globalAppearance) return installed;
    return MTApplicationIconInvalidationAffectedBundleIdentifiers(
        kernel.currentSnapshot, installed.allObjects);
}

static void MTSeedApplicationIconInvalidationScope(
    MTRuntimeKernel *kernel,
    BOOL includesUIResources,
    BOOL requiresBundleIdentifiers,
    BOOL updatesMorphScope) {
    MTRuntimeFeatureState *state = MTApplicationIconOwnerFeatureState(
        kernel.currentSnapshot, includesUIResources);
    BOOL globalAppearance = state == nil ? YES :
        MTApplicationIconFeatureStateUsesGlobalAppearance(state);
    NSSet<NSString *> *identifiers = requiresBundleIdentifiers ?
        MTCurrentApplicationIconIdentifiers(kernel, globalAppearance) : nil;
    if (updatesMorphScope) {
        MTIconMorphCarrierAdapterUpdateAffectedBundleIdentifiers(
            identifiers ?: [NSSet set]);
    }
    @synchronized (MTRuntimeProfile.class) {
        MTPreviousApplicationIconIdentifiers = identifiers;
        MTPreviousApplicationIconAppearanceWasGlobal = globalAppearance;
        // The first canonical notification after this image is mapped must
        // perform one conservative owner invalidation. This covers migration
        // from a pre-service build without making every later unrelated Apply
        // repeat the work.
        MTPreviousApplicationIconOwnerFingerprint = nil;
    }
}

static void MTRefreshNativeApplicationIconOwners(
    MTRuntimeKernel *kernel,
    BOOL includesUIResources,
    BOOL requiresBundleIdentifiers,
    BOOL updatesMorphScope,
    MTRuntimeAdapterRefreshCompletion completion) {
    MTRuntimeFeatureState *state = MTApplicationIconOwnerFeatureState(
        kernel.currentSnapshot, includesUIResources);
    if (state == nil) {
        MTRuntimeABIReportRecordSample(
            @"application-icon.native-invalidation", @{
                @"outcome" : @"feature-state-unavailable",
            });
        if (completion != nil) completion(NO);
        return;
    }
    __block BOOL previousGlobal = NO;
    __block NSSet<NSString *> *previousIdentifiers = nil;
    __block NSString *previousFingerprint = nil;
    @synchronized (MTRuntimeProfile.class) {
        previousGlobal = MTPreviousApplicationIconAppearanceWasGlobal;
        previousIdentifiers = MTPreviousApplicationIconIdentifiers;
        previousFingerprint = MTPreviousApplicationIconOwnerFingerprint;
    }
    if (previousFingerprint != nil &&
        [previousFingerprint isEqualToString:state.fingerprint]) {
        MTRuntimeABIReportRecordSample(
            @"application-icon.native-invalidation", @{
                @"fingerprint" : state.fingerprint,
                @"outcome" : @"feature-state-unchanged",
            });
        if (completion != nil) completion(YES);
        return;
    }
    BOOL currentGlobal =
        MTApplicationIconFeatureStateUsesGlobalAppearance(state);
    NSSet<NSString *> *currentIdentifiers = requiresBundleIdentifiers ?
        MTCurrentApplicationIconIdentifiers(kernel, currentGlobal) : nil;
    if (updatesMorphScope) {
        MTIconMorphCarrierAdapterUpdateAffectedBundleIdentifiers(
            currentIdentifiers ?: [NSSet set]);
    }
    NSSet<NSString *> *signalIdentifiers = nil;
    if (!previousGlobal && !currentGlobal && previousIdentifiers != nil &&
        currentIdentifiers != nil) {
        NSMutableSet<NSString *> *unionIdentifiers =
            [previousIdentifiers mutableCopy];
        [unionIdentifiers unionSet:currentIdentifiers];
        signalIdentifiers = [unionIdentifiers copy];
    }
    MTRuntimeABIReportRecordSample(
        @"application-icon.native-invalidation", @{
            @"fingerprint" : state.fingerprint,
            @"includesUIResources" : @(includesUIResources),
            @"outcome" : @"feature-state-changed",
        });
    MTApplicationIconNativeInvalidationRefreshBundleIdentifiers(
        signalIdentifiers, ^(BOOL verified) {
            if (verified) {
                @synchronized (MTRuntimeProfile.class) {
                    MTPreviousApplicationIconIdentifiers =
                        currentIdentifiers;
                    MTPreviousApplicationIconAppearanceWasGlobal =
                        currentGlobal;
                    MTPreviousApplicationIconOwnerFingerprint =
                        state.fingerprint;
                }
            }
            if (completion != nil) completion(verified);
        });
}

static BOOL MTInstallPreferences(MTRuntimeKernel *kernel,
                                 NSError **error) {
    if (!MTUIResourceSnapshotConfigure(kernel, error) ||
        !MTApplicationIconNativeInvalidationConfigure(
            MTApplicationIconNativeInvalidationOwnerPreferences, error)) {
        return NO;
    }
    if (!MTPreferencesUIResourceImageAdapterSchedule(
            MTUIResourceSnapshotResolve,
            MTUIResourceSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Preferences UI-resource adapter rejected scheduling.");
        return NO;
    }
    MTSeedApplicationIconInvalidationScope(kernel, YES, NO, NO);
    return YES;
}

static BOOL MTInstallShareSheet(MTRuntimeKernel *kernel,
                                NSError **error) {
    if (!MTUIResourceSnapshotConfigure(kernel, error) ||
        !MTApplicationIconNativeInvalidationConfigure(
            MTApplicationIconNativeInvalidationOwnerShareSheet, error)) {
        return NO;
    }
    if (!MTShareSheetActivityGlyphAdapterSchedule(
            MTUIResourceSnapshotResolveShareActivity,
            MTUIResourceSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Share Sheet activity-glyph adapter rejected scheduling.");
        return NO;
    }
    MTSeedApplicationIconInvalidationScope(kernel, YES, NO, NO);
    return YES;
}

static BOOL MTInstallDialer(MTRuntimeKernel *kernel, NSError **error) {
    if (!MTDialerSnapshotConfigure(kernel, error)) return NO;
    MTDialerSnapshotSetReadyHandler(^{
        MTDialerButtonAdapterRefresh();
    });
    MTDialerSnapshotReload();
    if (!MTDialerButtonAdapterSchedule(
            MTDialerSnapshotResolveButton,
            MTDialerSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Dialer button adapter rejected scheduling.");
        return NO;
    }
    return YES;
}

static BOOL MTInstallSpotlight(MTRuntimeKernel *kernel, NSError **error) {
    if (!MTStaticIconSnapshotConfigure(kernel, YES, error) ||
        !MTClockIconSnapshotConfigure(kernel, error) ||
        !MTIconMaskSnapshotConfigure(kernel, YES, error) ||
        !MTIconOverlaySnapshotConfigure(kernel, YES, error) ||
        !MTApplicationIconNativeInvalidationConfigure(
            MTApplicationIconNativeInvalidationOwnerLaunchServices, error)) {
        return NO;
    }
    MTIconMaskSnapshotReload();
    MTIconOverlaySnapshotReload();
    if (!MTCalendarUIKitSourceAdapterSchedule(
            MTStaticIconSnapshotResolveCalendarSource,
            MTCalendarSourceModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The CalendarUIKit source adapter rejected scheduling.");
        return NO;
    }
    if (!MTSearchUICalendarIconAdapterSchedule(
            MTCalendarAppearanceResolve,
            MTCalendarAppearanceModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The SearchUI Calendar adapter rejected scheduling.");
        return NO;
    }
    MTClockIconSnapshotSetReadyHandler(^{
        MTClockImageSetAdapterRefresh();
    });
    MTClockIconSnapshotReload();
    if (!MTClockImageSetAdapterSchedule(
            MTClockAppearanceResolve,
            MTClockModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Spotlight Clock adapter rejected scheduling.");
        return NO;
    }
    MTSeedApplicationIconInvalidationScope(kernel, NO, YES, NO);
    return YES;
}

static BOOL MTInstallSpringBoard(MTRuntimeKernel *kernel, NSError **error) {
    if (!MTStaticIconSnapshotConfigure(kernel, YES, error) ||
        !MTClockIconSnapshotConfigure(kernel, error) ||
        !MTIconMaskSnapshotConfigure(kernel, YES, error) ||
        !MTIconOverlaySnapshotConfigure(kernel, YES, error) ||
        !MTFolderIconSnapshotConfigure(kernel, error) ||
        !MTBadgeSnapshotConfigure(kernel, error) ||
        !MTIconShadowSnapshotConfigure(kernel, error) ||
        !MTStatusBarSnapshotConfigure(kernel, error) ||
        !MTApplicationIconNativeInvalidationConfigure(
            MTApplicationIconNativeInvalidationOwnerLaunchServices |
                MTApplicationIconNativeInvalidationOwnerNotificationImages |
                MTApplicationIconNativeInvalidationOwnerSpringBoardVisibleCache,
            error)) {
        return NO;
    }

    MTIconMaskSnapshotReload();
    MTIconOverlaySnapshotReload();
    if (!MTCalendarUIKitSourceAdapterSchedule(
            MTStaticIconSnapshotResolveCalendarSource,
            MTCalendarSourceModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The CalendarUIKit source adapter rejected scheduling.");
        return NO;
    }
    if (!MTCalendarApplicationIconAdapterInstall(
            MTCalendarAppearanceResolve,
            MTCalendarAppearanceModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The SpringBoard Calendar adapter rejected installation.");
        return NO;
    }

    MTClockIconSnapshotSetReadyHandler(^{
        MTClockImageSetAdapterRefresh();
    });
    MTClockIconSnapshotReload();
    if (!MTClockImageSetAdapterSchedule(
            MTClockAppearanceResolve,
            MTClockModulesPrepare,
            error)) return NO;

    MTFolderIconSnapshotSetReadyHandler(^{
        MTFolderBackgroundImageAdapterRefresh();
    });
    MTFolderIconSnapshotReload();
    if (!MTFolderBackgroundImageAdapterSchedule(
            MTFolderIconSnapshotResolveBackgroundView,
            MTFolderIconSnapshotResolveOverlayView,
            error)) return NO;

    MTBadgeSnapshotSetReadyHandler(^{
        MTBadgeBackgroundImageAdapterRefresh();
    });
    MTBadgeSnapshotReload();
    if (!MTBadgeBackgroundImageAdapterSchedule(
            MTBadgeSnapshotResolveBackgroundImage,
            MTBadgeSnapshotForgetBadgeView,
            error)) return NO;

    MTIconShadowSnapshotSetReadyHandler(^{
        MTIconShadowViewAdapterRefresh();
    });
    MTIconShadowSnapshotReload();
    if (!MTIconShadowViewAdapterSchedule(
            MTIconShadowSnapshotResolveView,
            MTIconShadowSnapshotForgetView,
            error)) return NO;

    if (!MTIconMorphCarrierAdapterSchedule(error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The SpringBoard icon morph-carrier adapter rejected scheduling.");
        return NO;
    }

    MTStatusBarSnapshotSetReadyHandler(^{
        MTStatusBarSignalImageAdapterRefresh();
    });
    MTStatusBarSignalImageAdapterSetActivityProbe(
        MTStatusBarSnapshotShouldResolveSignalView);
    MTStatusBarSnapshotReload();
    if (!MTStatusBarSignalImageAdapterSchedule(
            MTStatusBarSnapshotResolveSignalView, error)) return NO;
    MTSeedApplicationIconInvalidationScope(kernel, NO, YES, YES);
    return YES;
}

BOOL MTRuntimeInstallConfiguredAdapters(MTRuntimeProfile *profile,
                                        MTRuntimeKernel *kernel,
                                        NSError **error) {
    if (![profile isKindOfClass:MTRuntimeProfile.class] ||
        ![kernel isKindOfClass:MTRuntimeKernel.class]) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"Runtime adapter installation requires an exact profile and Kernel.");
        return NO;
    }
    if (profile.mode == MTRuntimeProfileModeKernelOnly) {
        return profile.adapterIDs.count == 0 && profile.moduleIDs.count == 0;
    }
    if (profile.mode != MTRuntimeProfileModeProcessAdapters) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"The Runtime profile does not select process adapters.");
        return NO;
    }
    if (MTPreferencesProfileMatches(profile)) {
        return MTInstallPreferences(kernel, error);
    }
    if (MTShareSheetProfileMatches(profile)) {
        return MTInstallShareSheet(kernel, error);
    }
    if (MTDialerProfileMatches(profile)) {
        return MTInstallDialer(kernel, error);
    }
    if (MTSpotlightProfileMatches(profile)) {
        return MTInstallSpotlight(kernel, error);
    }
    if (MTSpringBoardProfileMatches(profile)) {
        return MTInstallSpringBoard(kernel, error);
    }
    MTSetError(error, MTRuntimeAdapterRegistryErrorInvalidProfile,
        @"The selected Runtime profile has no exact built-in composition.");
    return NO;
}

void MTRuntimeRefreshConfiguredAdapters(
    MTRuntimeProfile *profile,
    MTRuntimeKernel *kernel,
    MTRuntimeSnapshot *snapshot,
    MTRuntimeAdapterRefreshCompletion completion) {
    (void)snapshot;
    if (MTPreferencesProfileMatches(profile)) {
        MTUIResourceSnapshotReload();
        MTRefreshNativeApplicationIconOwners(
            kernel, YES, NO, NO, completion);
        return;
    }
    if (MTShareSheetProfileMatches(profile)) {
        MTUIResourceSnapshotReload();
        MTRefreshNativeApplicationIconOwners(
            kernel, YES, NO, NO, completion);
        return;
    }
    if (MTDialerProfileMatches(profile)) {
        MTDialerSnapshotReload();
        if (completion != nil) completion(YES);
        return;
    }
    if (MTSpotlightProfileMatches(profile)) {
        MTStaticIconSnapshotReload();
        MTClockIconSnapshotReload();
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        MTRefreshNativeApplicationIconOwners(
            kernel, NO, YES, NO, ^(BOOL verified) {
            MTSearchUICalendarIconAdapterRefresh();
            MTClockImageSetAdapterRefresh();
            if (completion != nil) completion(verified);
        });
        return;
    }
    if (MTSpringBoardProfileMatches(profile)) {
        MTStaticIconSnapshotReload();
        MTClockIconSnapshotReload();
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        MTFolderIconSnapshotReload();
        MTBadgeSnapshotReload();
        MTIconShadowSnapshotReload();
        MTStatusBarSnapshotReload();
        MTRefreshNativeApplicationIconOwners(
            kernel, NO, YES, YES, completion);
        return;
    }
    if (completion != nil) completion(NO);
}
