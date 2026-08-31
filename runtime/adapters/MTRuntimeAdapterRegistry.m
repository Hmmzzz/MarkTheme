#import "MTRuntimeAdapterRegistry.h"

#import "MTBadgeNativeSourceAdapter.h"
#import "MTCalendarApplicationIconAdapter.h"
#import "MTCalendarUIKitSourceAdapter.h"
#import "MTClockNativeSourceAdapter.h"
#import "MTDialerButtonAdapter.h"
#import "MTFolderNativeSourceAdapter.h"
#import "MTGenerationReader.h"
#import "MTIconShadowCarrierAdapter.h"
#import "MTIconMorphCarrierAdapter.h"
#import "MTNotificationIconSourceAdapter.h"
#import "MTPreferencesUIResourceImageAdapter.h"
#import "MTSearchUICalendarIconAdapter.h"
#import "MTShareSheetActivityGlyphAdapter.h"
#import "MTStatusBarSignalImageAdapter.h"
#import "MTApplicationIconSourceState.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeProfile.h"
#import "MTRuntimeSnapshot.h"
#import "modules/MTBadgeSnapshotModule.h"
#import "modules/MTCalendarIconSnapshotResolver.h"
#import "modules/MTClockIconSnapshotModule.h"
#import "modules/MTDialerSnapshotModule.h"
#import "modules/MTFolderIconSnapshotModule.h"
#import "modules/MTIconMaskSnapshotModule.h"
#import "modules/MTIconOverlaySnapshotModule.h"
#import "modules/MTNotificationIconSnapshotModule.h"
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

static NSArray<NSString *> *MTSpringBoardAdapterIDs(void) {
    return @[
        @"springboard.notification-icon-source",
        @"springboard.icon-morph-carrier",
        @"calendar-ui-kit.dynamic-icon-source",
        @"springboard.calendar-appearance",
        @"springboard-home.clock-icon-sources",
        @"springboard-home.folder-icon-source",
        @"springboard-home.badge-source",
        @"springboard-home.icon-shadow-carrier",
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
    return @[ @"preferences.ui-resource-image" ];
}

static NSArray<NSString *> *MTShareSheetAdapterIDs(void) {
    return @[ @"share-sheet.activity-glyph" ];
}

static NSArray<NSString *> *MTSpotlightAdapterIDs(void) {
    return @[
        @"springboard-home.clock-icon-sources",
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

// SpringBoardHome owns the Clock face's square/masked distinction. Resolve the
// raw face at its exact source geometry, preserve an unmasked square carrier,
// and apply final mask/overlay appearance only where that native call permits.
static id MTClockNativeFaceResolve(NSString *bundleIdentifier,
                                   CGSize pointSize,
                                   CGFloat scale,
                                   BOOL includingMask,
                                   id originalResult) {
    id source = MTStaticIconSnapshotResolveClockSource(pointSize, scale);
    id appearance = source ?: originalResult;
    BOOL changed = source != nil;
    BOOL usesSystemMask = MTIconMaskSnapshotUsesSystemMask();
    if (includingMask && (!usesSystemMask || source != nil)) {
        id masked = MTIconMaskSnapshotResolveSystemSurface(
            bundleIdentifier, appearance, originalResult,
            pointSize, scale);
        if (masked != nil) {
            appearance = masked;
            changed = YES;
        }
    }
    id overlaid = MTIconOverlaySnapshotResolveSystemSurface(
        bundleIdentifier, appearance, pointSize, scale);
    if (overlaid != nil) {
        appearance = overlaid;
        changed = YES;
    }
    return changed ? appearance : nil;
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

static BOOL MTFolderModulesPrepare(void) {
    return MTFolderIconSnapshotPrepare() &&
        MTIconOverlaySnapshotPrepare();
}

static BOOL MTInstallPreferences(MTRuntimeKernel *kernel,
                                 NSError **error) {
    if (!MTUIResourceSnapshotConfigure(kernel, error)) return NO;
    if (!MTPreferencesUIResourceImageAdapterSchedule(
            MTUIResourceSnapshotResolve,
            MTUIResourceSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Preferences UI-resource adapter rejected scheduling.");
        return NO;
    }
    return YES;
}

static BOOL MTInstallShareSheet(MTRuntimeKernel *kernel,
                                NSError **error) {
    if (!MTUIResourceSnapshotConfigure(kernel, error)) return NO;
    if (!MTShareSheetActivityGlyphAdapterSchedule(
            MTUIResourceSnapshotResolveShareActivity,
            MTUIResourceSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Share Sheet activity-glyph adapter rejected scheduling.");
        return NO;
    }
    return YES;
}

static BOOL MTInstallDialer(MTRuntimeKernel *kernel, NSError **error) {
    if (!MTDialerSnapshotConfigure(kernel, error)) return NO;
    if (!MTDialerButtonAdapterSchedule(
            MTDialerSnapshotResolveImage,
            MTDialerSnapshotHasCompleteNumberSet,
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
        !MTIconOverlaySnapshotConfigure(kernel, YES, error)) {
        return NO;
    }
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
    if (!MTClockNativeSourceAdapterSchedule(
            MTClockNativeFaceResolve,
            MTClockModulesPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Spotlight Clock source adapter rejected scheduling.");
        return NO;
    }
    return YES;
}

static BOOL MTInstallSpringBoard(MTRuntimeKernel *kernel, NSError **error) {
    if (!MTStaticIconSnapshotConfigure(kernel, YES, error) ||
        !MTNotificationIconSnapshotConfigure(kernel, error) ||
        !MTClockIconSnapshotConfigure(kernel, error) ||
        !MTIconMaskSnapshotConfigure(kernel, YES, error) ||
        !MTIconOverlaySnapshotConfigure(kernel, YES, error) ||
        !MTFolderIconSnapshotConfigure(kernel, error) ||
        !MTBadgeSnapshotConfigure(kernel, error) ||
        !MTIconShadowSnapshotConfigure(kernel, error) ||
        !MTStatusBarSnapshotConfigure(kernel, error)) {
        return NO;
    }

    if (!MTNotificationIconSourceAdapterSchedule(
            MTNotificationIconSnapshotResolve,
            MTNotificationIconSnapshotPrepare,
            error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The notification icon source adapter rejected scheduling.");
        return NO;
    }
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

    if (!MTClockNativeSourceAdapterSchedule(
            MTClockNativeFaceResolve,
            MTClockModulesPrepare,
            error)) return NO;

    if (!MTFolderNativeSourceAdapterSchedule(
            MTFolderIconSnapshotResolveNativeBackground,
            MTFolderIconSnapshotSynchronizeOverlay,
            MTFolderModulesPrepare,
            error)) return NO;

    if (!MTBadgeNativeSourceAdapterSchedule(
            MTBadgeSnapshotApplyNativeBackground,
            MTBadgeSnapshotPrepare,
            error)) return NO;

    if (!MTIconShadowCarrierAdapterSchedule(
            MTIconShadowSnapshotApplyToCarrier,
            MTIconShadowSnapshotClearCarrier,
            MTIconShadowSnapshotPrepare,
            error)) return NO;

    if (!MTIconMorphCarrierAdapterSchedule(
            ^BOOL(NSString *bundleIdentifier) {
                return MTApplicationIconSnapshotAffectsBundleIdentifier(
                    kernel.currentSnapshot, bundleIdentifier);
            }, error)) {
        MTSetError(error, MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The SpringBoard icon morph-carrier adapter rejected scheduling.");
        return NO;
    }

    if (!MTStatusBarSignalImageAdapterSchedule(
            MTStatusBarSnapshotResolveSignalView, error)) return NO;
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
