#import "MTRuntimeAdapterRegistry.h"

#import "MTBadgeBackgroundImageAdapter.h"
#import "MTIconImageCacheAdapter.h"
#import "MTNotificationIconAdapter.h"
#import "MTIconShadowViewAdapter.h"
#import "MTClockImageSetAdapter.h"
#import "MTDialerButtonAdapter.h"
#import "MTFolderBackgroundImageAdapter.h"
#import "MTPreferencesApplicationIconAdapter.h"
#import "MTPreferencesIconImageCacheAdapter.h"
#import "MTShareSheetActivityImageAdapter.h"
#import "MTSearchUIAppIconImageAdapter.h"
#import "MTStatusBarSignalImageAdapter.h"
#import "MTRuntimeKernel.h"
#import "MTRuntimeProfile.h"
#import "MTRuntimeSnapshot.h"
#import "MTRuntimeState.h"
#import "MTRuntimeTargetedRefresh.h"
#import "MTClockIconsModule.h"
#import "modules/MTCalendarIconSnapshotResolver.h"
#import "modules/MTBadgeSnapshotModule.h"
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

static NSString *const MTSpringBoardIconImageCacheAdapterID =
    @"springboard.icon-image-cache";
static NSString *const MTNotificationIconAdapterID =
    @"springboard.notification-icon";
static NSString *const MTSpotlightIconImageCacheAdapterID =
    @"spotlight.icon-image-cache";
static NSString *const MTClockImageSetAdapterID =
    @"springboard.clock-image-set";
static NSString *const MTFolderBackgroundImageAdapterID =
    @"springboard.folder-image";
static NSString *const MTBadgeBackgroundImageAdapterID =
    @"springboard.badge-background";
static NSString *const MTIconShadowViewAdapterID =
    @"springboard.icon-shadow";
static NSString *const MTStatusBarSignalImageAdapterID =
    @"springboard.statusbar-signal-image";
static NSString *const MTPreferencesIconImageCacheAdapterID =
    @"preferences.icon-image-cache";
static NSString *const MTPreferencesApplicationIconAdapterID =
    @"preferences.application-icon-image";
static NSString *const MTShareSheetActivityImageAdapterID =
    @"share-sheet.activity-image";
static NSString *const MTDialerButtonAdapterID =
    @"mobilephone.dialer-buttons";
static NSString *const MTSearchUIAppIconImageAdapterID =
    @"spotlight.search-ui-app-image";

static BOOL MTRuntimeProfileSelectsIconModules(MTRuntimeProfile *profile) {
    return profile.moduleIDs.count == 9 &&
        [profile.moduleIDs[0] isEqualToString:MTStaticIconSnapshotModuleID] &&
        [profile.moduleIDs[1] isEqualToString:MTCalendarIconCompositeModuleID] &&
        [profile.moduleIDs[2] isEqualToString:MTClockIconSnapshotModuleID] &&
        [profile.moduleIDs[3] isEqualToString:MTIconMaskSnapshotModuleID] &&
        [profile.moduleIDs[4]
            isEqualToString:MTIconOverlaySnapshotModuleID] &&
        [profile.moduleIDs[5] isEqualToString:MTFolderIconSnapshotModuleID] &&
        [profile.moduleIDs[6] isEqualToString:MTBadgeSnapshotModuleID] &&
        [profile.moduleIDs[7]
            isEqualToString:MTIconShadowSnapshotModuleID] &&
        [profile.moduleIDs[8]
            isEqualToString:MTStatusBarSnapshotModuleID];
}

static BOOL MTRuntimeProfileSelectsIconAdapters(MTRuntimeProfile *profile) {
    return profile.adapterIDs.count == 7 &&
        [profile.adapterIDs[0]
            isEqualToString:MTSpringBoardIconImageCacheAdapterID] &&
        [profile.adapterIDs[1]
            isEqualToString:MTNotificationIconAdapterID] &&
        [profile.adapterIDs[2] isEqualToString:MTClockImageSetAdapterID] &&
        [profile.adapterIDs[3]
            isEqualToString:MTFolderBackgroundImageAdapterID] &&
        [profile.adapterIDs[4]
            isEqualToString:MTBadgeBackgroundImageAdapterID] &&
        [profile.adapterIDs[5]
            isEqualToString:MTIconShadowViewAdapterID] &&
        [profile.adapterIDs[6]
            isEqualToString:MTStatusBarSignalImageAdapterID];
}

static BOOL MTRuntimeProfileSelectsPreferencesUIIcons(
    MTRuntimeProfile *profile) {
    return [profile.profileID isEqualToString:@"preferences.ui-icons"] &&
        profile.adapterIDs.count == 2 &&
        [profile.adapterIDs[0]
            isEqualToString:MTPreferencesIconImageCacheAdapterID] &&
        [profile.adapterIDs[1]
            isEqualToString:MTPreferencesApplicationIconAdapterID] &&
        profile.moduleIDs.count == 4 &&
        [profile.moduleIDs[0]
            isEqualToString:MTStaticIconSnapshotModuleID] &&
        [profile.moduleIDs[1]
            isEqualToString:MTIconMaskSnapshotModuleID] &&
        [profile.moduleIDs[2]
            isEqualToString:MTIconOverlaySnapshotModuleID] &&
        [profile.moduleIDs[3]
            isEqualToString:MTUIResourceSnapshotModuleID];
}

static BOOL MTRuntimeProfileSelectsShareSheetUIIcons(
    MTRuntimeProfile *profile) {
    BOOL supportedHost =
        [profile.profileID isEqualToString:@"share-sheet.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"share-sheet.loaded-host.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"photos.share-sheet.ui-icons"] ||
        [profile.profileID
            isEqualToString:@"sharingd.share-sheet.ui-icons"];
    return supportedHost &&
        profile.adapterIDs.count == 1 &&
        [profile.adapterIDs[0]
            isEqualToString:MTShareSheetActivityImageAdapterID] &&
        profile.moduleIDs.count == 4 &&
        [profile.moduleIDs[0]
            isEqualToString:MTStaticIconSnapshotModuleID] &&
        [profile.moduleIDs[1]
            isEqualToString:MTIconMaskSnapshotModuleID] &&
        [profile.moduleIDs[2]
            isEqualToString:MTIconOverlaySnapshotModuleID] &&
        [profile.moduleIDs[3]
            isEqualToString:MTUIResourceSnapshotModuleID];
}

static BOOL MTRuntimeProfileSelectsDialer(MTRuntimeProfile *profile) {
    return [profile.profileID isEqualToString:@"mobilephone.dialer"] &&
        profile.adapterIDs.count == 1 &&
        [profile.adapterIDs[0] isEqualToString:MTDialerButtonAdapterID] &&
        profile.moduleIDs.count == 1 &&
        [profile.moduleIDs[0]
            isEqualToString:MTDialerSnapshotModuleID];
}

static BOOL MTRuntimeProfileSelectsSpotlightIcons(
    MTRuntimeProfile *profile) {
    return [profile.profileID
            isEqualToString:@"spotlight.application-icons"] &&
        profile.adapterIDs.count == 3 &&
        [profile.adapterIDs[0]
            isEqualToString:MTSpotlightIconImageCacheAdapterID] &&
        [profile.adapterIDs[1] isEqualToString:MTClockImageSetAdapterID] &&
        [profile.adapterIDs[2]
            isEqualToString:MTSearchUIAppIconImageAdapterID] &&
        profile.moduleIDs.count == 5 &&
        [profile.moduleIDs[0]
            isEqualToString:MTStaticIconSnapshotModuleID] &&
        [profile.moduleIDs[1]
            isEqualToString:MTCalendarIconCompositeModuleID] &&
        [profile.moduleIDs[2]
            isEqualToString:MTClockIconSnapshotModuleID] &&
        [profile.moduleIDs[3]
            isEqualToString:MTIconMaskSnapshotModuleID] &&
        [profile.moduleIDs[4]
            isEqualToString:MTIconOverlaySnapshotModuleID];
}

static BOOL MTShareSheetSnapshotModulesPrepare(void) {
    return MTUIResourceSnapshotPrepare() &&
        MTStaticIconSnapshotPrepare() &&
        MTIconMaskSnapshotPrepare() &&
        MTIconOverlaySnapshotPrepare();
}

static BOOL MTIconAppearanceSnapshotModulesPrepare(void) {
    return MTStaticIconSnapshotPrepare() && MTIconMaskSnapshotPrepare() &&
        MTIconOverlaySnapshotPrepare();
}

// The one composition order for every surface: mask clips the icon to its
// authored shape, then the overlay draws its own artwork on top. A miss in
// either stage leaves the previous stage's exact result untouched.
static id MTIconAppearanceSnapshotResolve(NSString *bundleIdentifier,
                                          id originalResult) {
    id staticReplacement = MTStaticIconSnapshotResolve(
        bundleIdentifier, originalResult);
    BOOL usesSystemMask = MTIconMaskSnapshotUsesSystemMask();
    // The system mask only ever reshapes authored artwork: a stock icon is
    // already drawn in the system shape, so masking it again would clip a
    // second time. Skip just the mask stage in that case -- not the overlay
    // below, which is themed content in its own right and must still reach
    // icons this theme supplies no artwork for.
    id appearance = nil;
    if (!usesSystemMask || staticReplacement != nil) {
        id candidate = staticReplacement ?: originalResult;
        id masked = MTIconMaskSnapshotResolve(
            bundleIdentifier, candidate, originalResult);
        appearance = usesSystemMask ? masked : (masked ?: staticReplacement);
    }
    // An overlay alone is themed content, so it may act on the stock image when
    // neither a static replacement nor a mask changed this icon.
    id overlaid = MTIconOverlaySnapshotResolve(
        bundleIdentifier, appearance ?: originalResult);
    return overlaid ?: appearance;
}

static id MTIconSourceSnapshotResolve(NSString *bundleIdentifier,
                                      id originalResult) {
    return MTStaticIconSnapshotResolve(bundleIdentifier, originalResult);
}

static id MTIconAppearanceSnapshotResolveReady(NSString *bundleIdentifier,
                                               CGSize pointSize,
                                               CGFloat scale) {
    id staticReplacement = MTStaticIconSnapshotResolveReady(
        bundleIdentifier, pointSize, scale);
    if (staticReplacement == nil) return nil;
    id masked = MTIconMaskSnapshotResolveReady(
        bundleIdentifier, staticReplacement);
    if (masked == nil) return nil;
    // This path never creates pixels: a nil overlay result means the active
    // overlay still needs composition, so the Adapter keeps original-first.
    return MTIconOverlaySnapshotResolveReady(bundleIdentifier, masked);
}

static BOOL MTIconAppearanceSnapshotUsesNativeSystemMask(void) {
    return MTIconMaskSnapshotUsesSystemMask();
}

static id MTSecondaryIconSurfaceAppearanceResolve(
    NSString *bundleIdentifier,
    id source,
    CGSize pointSize,
    CGFloat scale,
    id originalResult) {
    // Every non-SpringBoard producer converges here. A custom author mask and
    // the system squircle are both applied by the same ModuleRuntime. A mask
    // miss is stock; returning an unmasked theme source would expose square
    // PNG corners on surfaces whose native views do not clip.
    //
    // Without authored artwork there is nothing to reshape, but an overlay is
    // themed content in its own right and still belongs on the stock icon.
    // Decorate the original carrier directly in that case rather than missing
    // outright, which is what used to strip the overlay from every app this
    // theme supplies no icon for.
    id masked = source == nil ? nil : MTIconMaskSnapshotResolveSystemSurface(
        bundleIdentifier, source, originalResult, pointSize, scale);
    if (masked == nil && source != nil) return nil;
    id carrier = masked ?: originalResult;
    if (carrier == nil) return nil;
    id overlaid = MTIconOverlaySnapshotResolveSystemSurface(
        bundleIdentifier, carrier, pointSize, scale);
    if (masked == nil) return overlaid;
    return overlaid ?: masked;
}

static id MTSecondaryApplicationIconAppearanceResolve(
    NSString *bundleIdentifier,
    id originalResult) {
    CGSize pointSize = CGSizeZero;
    CGFloat scale = 0;
    id source = MTStaticIconSnapshotResolveSecondarySurfaceImage(
        bundleIdentifier, originalResult, &pointSize, &scale);
    return MTSecondaryIconSurfaceAppearanceResolve(
        bundleIdentifier, source, pointSize, scale, originalResult);
}

// The return-to-Home zoom carrier holds authored square pixels by contract;
// SpringBoard normally rounds it with an animated corner mask, and the morph
// square proxy suppresses exactly that mask. Compose the active mask (author
// artwork, or the system default when none is authored) into those pixels
// before the overlay so the proxy never displays raw corners. The geometry
// protocol keeps this file free of UIKit, mirroring the Adapter's own carrier
// reads.
@protocol MTIconSquareCarrierGeometry <NSObject>
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGFloat scale;
@end

static id MTIconSquareContentsAppearanceResolve(NSString *bundleIdentifier,
                                                id originalResult) {
    if (![originalResult respondsToSelector:@selector(size)] ||
        ![originalResult respondsToSelector:@selector(scale)]) {
        return nil;
    }
    id<MTIconSquareCarrierGeometry> carrier = originalResult;
    id masked = MTIconMaskSnapshotResolveSystemSurface(
        bundleIdentifier, carrier, nil, carrier.size, carrier.scale);
    if (masked == nil) return nil;
    // A mask-only result is not a themed carrier: for a bundle with no
    // authored icon resource the system squircle still composes, but no
    // overlay follows. Returning it would activate the morph square proxy and
    // suppress SpringBoard's animated mask while skipping the Adapter's
    // final decoration pass, dropping the overlay. Miss instead, so the
    // Adapter keeps the native carrier and decorates it as before.
    id overlaid = MTIconOverlaySnapshotResolve(bundleIdentifier, masked);
    if (overlaid == nil || overlaid == masked) return nil;
    return overlaid;
}

static id MTSystemIconSurfaceAppearanceResolve(
    NSString *bundleIdentifier,
    CGSize pointSize,
    CGFloat scale,
    id originalResult) {
    id source = MTStaticIconSnapshotResolveSystemSurface(
        bundleIdentifier, pointSize, scale);
    return MTSecondaryIconSurfaceAppearanceResolve(
        bundleIdentifier, source, pointSize, scale, originalResult);
}
// Main-queue owned. It tracks identifiers that currently display either a
// static replacement or the one global mask result.
static NSSet<NSString *> *MTRuntimeActiveRefreshIdentifiers;

static BOOL MTRuntimeRefreshSnapshotIsCurrent(
    MTRuntimeKernel *kernel,
    uint64_t sequence,
    NSString *generationIdentifier,
    BOOL ready) {
    MTRuntimeSnapshot *current = kernel.currentSnapshot;
    if (current.state.sequence != sequence || current.isReady != ready) {
        return NO;
    }
    return generationIdentifier == nil ||
        [current.state.activeGenerationIdentifier
            isEqualToString:generationIdentifier];
}

static void MTRuntimeRefreshReadyBatch(
    MTRuntimeKernel *kernel,
    MTRuntimeTargetedRefreshSnapshot *refreshSnapshot,
    uint64_t sequence,
    NSString *generationIdentifier,
    BOOL appliesGlobalMask,
    NSUInteger startIndex) {
    if (startIndex >= refreshSnapshot.identifiers.count) return;
    NSUInteger length = MIN(MTStaticIconSnapshotPrewarmBatchLimit,
        refreshSnapshot.identifiers.count - startIndex);
    NSArray<NSString *> *batch = [refreshSnapshot.identifiers
        subarrayWithRange:NSMakeRange(startIndex, length)];
    MTStaticIconSnapshotPrewarmBundleIdentifiers(
        batch, generationIdentifier,
        ^(NSSet<NSString *> *resolvedIdentifiers) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!MTRuntimeRefreshSnapshotIsCurrent(
                        kernel, sequence, generationIdentifier, YES)) {
                    return;
                }
                NSMutableSet<NSString *> *purgedIdentifiers =
                    [resolvedIdentifiers mutableCopy];
                NSSet<NSString *> *maskIdentifiers = appliesGlobalMask
                    ? [NSSet setWithArray:batch] : [NSSet set];
                [purgedIdentifiers unionSet:maskIdentifiers];
                if (startIndex == 0) {
                    if (!appliesGlobalMask) {
                        [purgedIdentifiers unionSet:
                            MTRuntimeActiveRefreshIdentifiers ?: [NSSet set]];
                    }
                    NSMutableSet<NSString *> *activeIdentifiers =
                        [resolvedIdentifiers mutableCopy];
                    [activeIdentifiers unionSet:maskIdentifiers];
                    MTRuntimeActiveRefreshIdentifiers = activeIdentifiers;
                } else if (resolvedIdentifiers.count > 0 ||
                           maskIdentifiers.count > 0) {
                    NSMutableSet<NSString *> *activeIdentifiers =
                        [MTRuntimeActiveRefreshIdentifiers mutableCopy] ?:
                        [NSMutableSet set];
                    [activeIdentifiers unionSet:resolvedIdentifiers];
                    [activeIdentifiers unionSet:maskIdentifiers];
                    MTRuntimeActiveRefreshIdentifiers =
                        [activeIdentifiers copy];
                }
                if (purgedIdentifiers.count > 0) {
                    MTIconImageCacheAdapterRefreshSnapshot(
                        refreshSnapshot, purgedIdentifiers);
                }
                if ([resolvedIdentifiers containsObject:
                        MTClockIconTargetBundleIdentifier]) {
                    MTClockImageSetAdapterRefresh();
                }
                dispatch_async(dispatch_get_global_queue(
                    QOS_CLASS_UTILITY, 0), ^{
                    MTRuntimeRefreshReadyBatch(kernel, refreshSnapshot,
                        sequence, generationIdentifier,
                        appliesGlobalMask,
                        startIndex + length);
                });
            });
        });
}

static void MTRuntimeAdapterRegistrySetError(
    NSError **error,
    MTRuntimeAdapterRegistryErrorCode code,
    NSString *description) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:MTRuntimeAdapterRegistryErrorDomain
                                 code:code
                             userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

BOOL MTRuntimeInstallConfiguredAdapters(MTRuntimeProfile *profile,
                                        MTRuntimeKernel *kernel,
                                        NSError **error) {
    if (![profile isKindOfClass:MTRuntimeProfile.class]) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"Runtime adapter installation requires one resolved profile.");
        return NO;
    }
    if (profile.mode == MTRuntimeProfileModeKernelOnly) {
        if (profile.adapterIDs.count == 0 && profile.moduleIDs.count == 0) {
            return YES;
        }
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"A kernel-only profile cannot select adapters or modules.");
        return NO;
    }
    if (profile.mode != MTRuntimeProfileModeProcessAdapters) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"A Runtime adapter profile must use process-adapter mode.");
        return NO;
    }

    if (MTRuntimeProfileSelectsPreferencesUIIcons(profile)) {
        if (!MTUIResourceSnapshotConfigure(kernel, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences UI resource module rejected configuration.");
            return NO;
        }
        if (!MTStaticIconSnapshotConfigure(kernel, NO, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences static icon module rejected configuration.");
            return NO;
        }
        if (!MTIconMaskSnapshotConfigure(kernel, YES, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences icon mask module rejected configuration.");
            return NO;
        }
        if (!MTIconOverlaySnapshotConfigure(kernel, YES, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences icon overlay module rejected configuration.");
            return NO;
        }
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        if (!MTPreferencesIconImageCacheAdapterSchedule(
                MTUIResourceSnapshotResolve,
                MTUIResourceSnapshotPrepare,
                MTUIResourceSnapshotAttachedViewControllers,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences icon cache adapter rejected scheduling.");
            return NO;
        }
        if (!MTPreferencesApplicationIconAdapterSchedule(
                MTSecondaryApplicationIconAppearanceResolve,
                MTIconAppearanceSnapshotModulesPrepare,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Preferences application icon adapter rejected scheduling.");
            return NO;
        }
        return YES;
    }

    if (MTRuntimeProfileSelectsShareSheetUIIcons(profile)) {
        if (!MTUIResourceSnapshotConfigure(kernel, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Share Sheet UI resource module rejected configuration.");
            return NO;
        }
        if (!MTStaticIconSnapshotConfigure(kernel, NO, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Share Sheet static icon module rejected configuration.");
            return NO;
        }
        if (!MTIconMaskSnapshotConfigure(kernel, YES, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Share Sheet icon mask module rejected configuration.");
            return NO;
        }
        if (!MTIconOverlaySnapshotConfigure(kernel, YES, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Share Sheet icon overlay module rejected configuration.");
            return NO;
        }
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        if (!MTShareSheetActivityImageAdapterSchedule(
                MTUIResourceSnapshotResolveShareActivity,
                MTSecondaryApplicationIconAppearanceResolve,
                MTShareSheetSnapshotModulesPrepare,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Share Sheet activity image adapter rejected scheduling.");
            return NO;
        }
        return YES;
    }

    if (MTRuntimeProfileSelectsDialer(profile)) {
        if (!MTDialerSnapshotConfigure(kernel, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Dialer snapshot module rejected configuration.");
            return NO;
        }
        MTDialerSnapshotSetReadyHandler(^{
            MTDialerButtonAdapterRefresh();
        });
        // Constructor-time reload only selects immutable Generation state.
        // Decode work starts after the deterministic main-queue boundary.
        MTDialerSnapshotReload();
        if (!MTDialerButtonAdapterSchedule(
                MTDialerSnapshotResolveButton,
                MTDialerSnapshotPrepare,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Dialer button adapter rejected scheduling.");
            return NO;
        }
        return YES;
    }

    if (MTRuntimeProfileSelectsSpotlightIcons(profile)) {
        if (!MTStaticIconSnapshotConfigure(kernel, YES, error) ||
            !MTClockIconSnapshotConfigure(kernel, error) ||
            !MTIconMaskSnapshotConfigure(kernel, YES, error) ||
            !MTIconOverlaySnapshotConfigure(kernel, YES, error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Spotlight icon modules rejected configuration.");
            return NO;
        }
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        if (!MTIconImageCacheAdapterSchedule(
                MTIconImageCacheAdapterModeEmbeddedCache,
                MTIconAppearanceSnapshotResolve,
                MTIconSourceSnapshotResolve,
                MTIconOverlaySnapshotResolve,
                MTIconOverlaySnapshotPresentationVersionForCandidate,
                MTIconSquareContentsAppearanceResolve,
                MTIconAppearanceSnapshotResolveReady,
                MTSystemIconSurfaceAppearanceResolve,
                MTIconAppearanceSnapshotUsesNativeSystemMask,
                MTIconAppearanceSnapshotModulesPrepare,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Spotlight icon cache adapter rejected scheduling.");
            return NO;
        }
        MTClockIconSnapshotSetReadyHandler(^{
            MTClockImageSetAdapterRefresh();
        });
        MTClockIconSnapshotReload();
        if (!MTClockImageSetAdapterSchedule(error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The Spotlight Clock adapter rejected scheduling.");
            return NO;
        }
        if (!MTSearchUIAppIconImageAdapterInstall(
                MTSystemIconSurfaceAppearanceResolve,
                MTIconAppearanceSnapshotModulesPrepare,
                MTIconImageCacheAdapterInstallIfAvailable,
                error)) {
            MTRuntimeAdapterRegistrySetError(error,
                MTRuntimeAdapterRegistryErrorInstallRejected,
                @"The SearchUI app-icon adapter rejected installation.");
            return NO;
        }
        return YES;
    }

    if (!MTRuntimeProfileSelectsIconAdapters(profile) ||
        !MTRuntimeProfileSelectsIconModules(profile)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInvalidProfile,
            @"The selected Runtime profile has no exact built-in composition.");
        return NO;
    }

    if (!MTStaticIconSnapshotConfigure(kernel, YES, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The static icon module rejected configuration.");
        return NO;
    }
    if (!MTClockIconSnapshotConfigure(kernel, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Clock icon module rejected configuration.");
        return NO;
    }
    if (!MTIconMaskSnapshotConfigure(kernel, YES, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The icon mask module rejected configuration.");
        return NO;
    }
    if (!MTIconOverlaySnapshotConfigure(kernel, YES, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The icon overlay module rejected configuration.");
        return NO;
    }
    if (!MTFolderIconSnapshotConfigure(kernel, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Folder icon module rejected configuration.");
        return NO;
    }
    if (!MTBadgeSnapshotConfigure(kernel, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Badge snapshot module rejected configuration.");
        return NO;
    }
    if (!MTIconShadowSnapshotConfigure(kernel, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Icon Shadow snapshot module rejected configuration.");
        return NO;
    }
    if (!MTStatusBarSnapshotConfigure(kernel, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Status Bar snapshot module rejected configuration.");
        return NO;
    }
    __weak MTRuntimeKernel *weakKernel = kernel;
    MTStaticIconSnapshotSetImageReadyHandler(
        ^(NSString *bundleIdentifier, NSString *generationIdentifier) {
            MTRuntimeKernel *strongKernel = weakKernel;
            NSString *activeGenerationIdentifier = strongKernel
                .currentSnapshot.state.activeGenerationIdentifier;
            if (strongKernel == nil ||
                ![activeGenerationIdentifier
                    isEqualToString:generationIdentifier]) {
                return;
            }
            MTRuntimeTargetedRefreshSnapshot *refreshSnapshot =
                MTIconImageCacheAdapterCaptureRefreshSnapshot();
            NSSet<NSString *> *identifiers =
                [NSSet setWithObject:bundleIdentifier];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *currentGenerationIdentifier = strongKernel
                    .currentSnapshot.state.activeGenerationIdentifier;
                if (![currentGenerationIdentifier
                        isEqualToString:generationIdentifier]) {
                    return;
                }
                NSMutableSet<NSString *> *activeIdentifiers =
                    [MTRuntimeActiveRefreshIdentifiers mutableCopy] ?:
                    [NSMutableSet set];
                [activeIdentifiers addObject:bundleIdentifier];
                MTRuntimeActiveRefreshIdentifiers =
                    [activeIdentifiers copy];
                MTIconImageCacheAdapterRefreshSnapshot(
                    refreshSnapshot, identifiers);
                if ([bundleIdentifier
                        isEqualToString:MTClockIconTargetBundleIdentifier]) {
                    MTClockImageSetAdapterRefresh();
                }
            });
        });
    // Decode the one global mask and overlay before installing the existing
    // shared icon Hook. A miss leaves the static/stock result untouched.
    MTIconMaskSnapshotReload();
    MTIconOverlaySnapshotReload();
    if (!MTIconImageCacheAdapterSchedule(
            MTIconImageCacheAdapterModeSpringBoard,
            MTIconAppearanceSnapshotResolve,
            MTIconSourceSnapshotResolve,
            MTIconOverlaySnapshotResolve,
            MTIconOverlaySnapshotPresentationVersionForCandidate,
            MTIconSquareContentsAppearanceResolve,
            MTIconAppearanceSnapshotResolveReady,
            MTSystemIconSurfaceAppearanceResolve,
            MTIconAppearanceSnapshotUsesNativeSystemMask,
            MTIconAppearanceSnapshotModulesPrepare,
            error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The icon image cache adapter rejected scheduling.");
        return NO;
    }
    if (!MTNotificationIconAdapterSchedule(
            MTSecondaryApplicationIconAppearanceResolve,
            MTIconAppearanceSnapshotModulesPrepare,
            error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The notification icon adapter rejected scheduling.");
        return NO;
    }
    MTClockIconSnapshotSetReadyHandler(^{
        MTClockImageSetAdapterRefresh();
    });
    // Bootstrap has already synchronously published one complete snapshot.
    // Prepare its hand images before the Clock Hook is installed, so the first
    // imageSetForMetrics: call cannot observe a temporary stock hand set.
    MTClockIconSnapshotReload();
    if (!MTClockImageSetAdapterSchedule(error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Clock image-set adapter rejected scheduling.");
        return NO;
    }
    MTFolderIconSnapshotSetReadyHandler(^{
        MTFolderBackgroundImageAdapterRefresh();
    });
    // Decode the one global Folder image set before installing its hook so
    // cold SpringBoard requests cannot briefly expose the stock material.
    MTFolderIconSnapshotReload();
    if (!MTFolderBackgroundImageAdapterSchedule(
            MTFolderIconSnapshotResolveBackgroundView,
            MTFolderIconSnapshotResolveOverlayView,
            error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Folder background adapter rejected scheduling.");
        return NO;
    }
    MTBadgeSnapshotSetReadyHandler(^{
        MTBadgeBackgroundImageAdapterRefresh();
    });
    // Select the initial Generation without consulting UIKit. No image work is
    // scheduled until an actual configured Badge view supplies its scale and
    // idiom; until then the Hook remains exact original-first/stock.
    MTBadgeSnapshotReload();
    if (!MTBadgeBackgroundImageAdapterSchedule(
            MTBadgeSnapshotResolveBackgroundImage,
            MTBadgeSnapshotForgetBadgeView,
            error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Badge background adapter rejected scheduling.");
        return NO;
    }
    MTIconShadowSnapshotSetReadyHandler(^{
        MTIconShadowViewAdapterRefresh();
    });
    // Like Badge, the constructor only selects Generation state. The first
    // real configured icon view supplies scale, idiom, and icon geometry.
    MTIconShadowSnapshotReload();
    if (!MTIconShadowViewAdapterSchedule(
            MTIconShadowSnapshotResolveView,
            MTIconShadowSnapshotForgetView,
            error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Icon Shadow view adapter rejected scheduling.");
        return NO;
    }
    MTStatusBarSnapshotSetReadyHandler(^{
        MTStatusBarSignalImageAdapterRefresh();
    });
    MTStatusBarSignalImageAdapterSetActivityProbe(
        MTStatusBarSnapshotShouldResolveSignalView);
    // Initial reload only selects immutable Generation state. Decode starts
    // after a real signal view supplies scale and idiom; exact ABI hooks are
    // registered synchronously before SpringBoard constructs those views.
    MTStatusBarSnapshotReload();
    if (!MTStatusBarSignalImageAdapterSchedule(
            MTStatusBarSnapshotResolveSignalView, error)) {
        MTRuntimeAdapterRegistrySetError(error,
            MTRuntimeAdapterRegistryErrorInstallRejected,
            @"The Status Bar signal-image adapter rejected scheduling.");
        return NO;
    }
    return YES;
}

void MTRuntimeRefreshConfiguredAdapters(MTRuntimeProfile *profile,
                                        MTRuntimeKernel *kernel,
                                        MTRuntimeSnapshot *snapshot) {
    if (profile.mode == MTRuntimeProfileModeProcessAdapters &&
        MTRuntimeProfileSelectsShareSheetUIIcons(profile)) {
        MTUIResourceSnapshotReload();
        MTStaticIconSnapshotReload();
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        return;
    }
    if (profile.mode == MTRuntimeProfileModeProcessAdapters &&
        MTRuntimeProfileSelectsPreferencesUIIcons(profile)) {
        MTUIResourceSnapshotReload();
        MTStaticIconSnapshotReload();
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        uint64_t sequence = snapshot.state.sequence;
        NSString *generationIdentifier =
            snapshot.state.activeGenerationIdentifier;
        BOOL ready = snapshot.isReady;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (MTRuntimeRefreshSnapshotIsCurrent(
                    kernel, sequence, generationIdentifier, ready)) {
                MTPreferencesIconImageCacheAdapterRefresh();
            }
        });
        return;
    }
    if (profile.mode == MTRuntimeProfileModeProcessAdapters &&
        MTRuntimeProfileSelectsDialer(profile)) {
        MTDialerSnapshotReload();
        uint64_t sequence = snapshot.state.sequence;
        NSString *generationIdentifier =
            snapshot.state.activeGenerationIdentifier;
        BOOL ready = snapshot.isReady;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (MTRuntimeRefreshSnapshotIsCurrent(
                    kernel, sequence, generationIdentifier, ready)) {
                MTDialerButtonAdapterRefresh();
            }
        });
        return;
    }
    if (profile.mode == MTRuntimeProfileModeProcessAdapters &&
        MTRuntimeProfileSelectsSpotlightIcons(profile)) {
        MTRuntimeTargetedRefreshSnapshot *refreshSnapshot =
            MTIconImageCacheAdapterCaptureRefreshSnapshot();
        MTStaticIconSnapshotReload();
        MTClockIconSnapshotReload();
        MTIconMaskSnapshotReload();
        MTIconOverlaySnapshotReload();
        uint64_t sequence = snapshot.state.sequence;
        NSString *generationIdentifier =
            snapshot.state.activeGenerationIdentifier;
        BOOL ready = snapshot.isReady;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!MTRuntimeRefreshSnapshotIsCurrent(
                    kernel, sequence, generationIdentifier, ready)) {
                return;
            }
            MTIconImageCacheAdapterRefreshSnapshot(
                refreshSnapshot, nil);
            MTSearchUIAppIconImageAdapterRefresh();
            MTClockImageSetAdapterRefresh();
        });
        return;
    }
    if (profile.mode != MTRuntimeProfileModeProcessAdapters ||
        !MTRuntimeProfileSelectsIconAdapters(profile) ||
        !MTRuntimeProfileSelectsIconModules(profile)) {
        return;
    }
    uint64_t sequence = snapshot.state.sequence;
    // The initial Kernel reload can precede adapter installation, while
    // SpringBoard creates SBIconViews later on main. Arm the accepted sequence
    // before snapshot capture so that either side of that race performs one
    // native recache: existing views use the snapshot, late views use their
    // exact configured icon/cache pair.
    MTIconImageCacheAdapterArmRefreshSequence(sequence);
    MTRuntimeTargetedRefreshSnapshot *refreshSnapshot =
        MTIconImageCacheAdapterCaptureRefreshSnapshot();
    // Keep the old complete Clock set visible while the Kernel validates, then
    // prepare the accepted Generation on this utility reload queue before any
    // icon-cache refresh is exposed to SpringBoard.
    MTStaticIconSnapshotReload();
    MTClockIconSnapshotReload();
    MTIconMaskSnapshotReload();
    MTIconOverlaySnapshotReload();
    MTFolderIconSnapshotReload();
    MTBadgeSnapshotReload();
    MTIconShadowSnapshotReload();
    MTStatusBarSnapshotReload();
    if (!snapshot.isReady) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!MTRuntimeRefreshSnapshotIsCurrent(
                    kernel, sequence, nil, NO)) {
                return;
            }
            NSSet<NSString *> *activeIdentifiers =
                MTRuntimeActiveRefreshIdentifiers ?: [NSSet set];
            if (activeIdentifiers.count > 0) {
                MTIconImageCacheAdapterRefreshSnapshot(
                    refreshSnapshot, activeIdentifiers);
            }
            MTRuntimeActiveRefreshIdentifiers = [NSSet set];
        });
        return;
    }
    NSString *generationIdentifier =
        snapshot.state.activeGenerationIdentifier;
    if (generationIdentifier.length == 0) return;
    // Only an authored mask or overlay repaints every icon. The system-mask
    // image set is a carrier for authored static icons and never changes stock
    // icons, so treating it as global would needlessly purge every App icon on
    // each ordinary theme switch.
    BOOL appliesGlobalMask =
        (MTIconMaskSnapshotIsReadyForGeneration(generationIdentifier) &&
         !MTIconMaskSnapshotUsesSystemMask()) ||
        MTIconOverlaySnapshotIsReadyForGeneration(generationIdentifier);
    if (refreshSnapshot.subjectCount == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (MTRuntimeRefreshSnapshotIsCurrent(
                    kernel, sequence, generationIdentifier, YES)) {
                MTRuntimeActiveRefreshIdentifiers = [NSSet set];
            }
        });
        return;
    }
    MTRuntimeRefreshReadyBatch(kernel, refreshSnapshot, sequence,
                               generationIdentifier, appliesGlobalMask, 0);
}
