include ../Config.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeRuntime

MarkThemeRuntime_FILES = MTRuntimeBootstrap.m \
    MTRuntimeInvalidation.m \
    MTRuntimeAsyncObjectCache.m \
    MTRuntimeKernel.m \
    MTRuntimeObjectCache.m \
    MTRuntimeProfile.m \
    MTRuntimePublishedImageLoader.m \
    MTRuntimeProfiles.generated.m \
    MTRuntimeReplacement.m \
    MTRuntimeSnapshot.m \
    MTRuntimeSnapshotLoader.m \
    MTRuntimeTargetedRefresh.m \
    MTRuntimeWeakObjectMapSnapshot.m \
    adapters/MTIconImageCacheAdapter.m \
    adapters/MTIconShadowViewAdapter.m \
    adapters/MTBadgeBackgroundImageAdapter.m \
    adapters/MTClockImageSetAdapter.m \
    adapters/MTDialerButtonAdapter.m \
    adapters/MTFolderBackgroundImageAdapter.m \
    adapters/MTPreferencesIconImageCacheAdapter.m \
    adapters/MTPreferencesABI.m \
    adapters/MTMobilePhoneDialerABI.m \
    adapters/MTShareSheetActivityIdentity.m \
    adapters/MTShareSheetActivityImageAdapter.m \
    adapters/MTSearchUIAppIconImageAdapter.m \
    adapters/MTStatusBarSignalImageAdapter.m \
    adapters/MTStatusBarSurfaceABI.m \
    adapters/MTShareSheetProviderABI.m \
    adapters/MTShareSheetABI.m \
    adapters/MTSearchUIABI.m \
    adapters/MTUIKitCoreApplicationIconABI.m \
    adapters/MTRuntimeImageABI.m \
    adapters/MTSpringBoardHomeABI.m \
    adapters/MTRuntimeAdapterRegistry.m \
    modules/MTCalendarIconContent.m \
    modules/MTCalendarIconRenderer.m \
    modules/MTCalendarIconSnapshotResolver.m \
    modules/MTBadgeSnapshotResolver.m \
    modules/MTBadgeSnapshotModule.m \
    modules/MTClockIconSnapshotModule.m \
    modules/MTDialerSnapshotResolver.m \
    modules/MTDialerSnapshotModule.m \
    modules/MTFolderIconSnapshotModule.m \
    modules/MTIconMaskCompositor.m \
    modules/MTIconMaskSnapshotModule.m \
    modules/MTSystemIconMaskProvider.m \
    modules/MTIconShadowSnapshotResolver.m \
    modules/MTIconShadowSnapshotModule.m \
    modules/MTStaticIconVisualProofContract.m \
    modules/MTStaticIconSnapshotResolver.m \
    modules/MTStaticIconSnapshotModule.m \
    modules/MTStatusBarSnapshotResolver.m \
    modules/MTStatusBarSnapshotModule.m \
    modules/MTSpringBoardDecorationSnapshotResolver.m \
    modules/MTUIResourceSnapshotResolver.m \
    modules/MTUIResourceSnapshotModule.m \
    ../core/MTCanonicalJSON.m \
    ../core/MTDigest.m \
    ../core/MTIdentifier.m \
    ../core/MTModuleConfiguration.m \
    ../core/MTResourceKey.m \
    ../core/MTVersionContracts.m \
    ../modules/MTBadgeContract.m \
    ../modules/MTBadgeConfiguration.m \
    ../modules/MTCalendarIconConfiguration.m \
    ../modules/MTClockIconContract.m \
    ../modules/MTDialerContract.m \
    ../modules/MTFolderIconContract.m \
    ../modules/MTIconMaskContract.m \
    ../modules/MTIconShadowContract.m \
    ../modules/MTIconShadowConfiguration.m \
    ../modules/MTStaticIconConfiguration.m \
    ../modules/MTStatusBarContract.m \
    ../compiler/MTGenerationDescriptor.m \
    ../compiler/MTGenerationIndexCodec.m \
    ../compiler/MTGenerationReader.m \
    ../compiler/MTGenerationReaderFilesystem.m \
    ../compiler/MTGenerationReaderValidation.m \
    ../platform/MTBootstrapPaths.m \
    ../store/MTRuntimeState.m
MarkThemeRuntime_FRAMEWORKS = Foundation CoreGraphics ImageIO QuartzCore UIKit CydiaSubstrate
MarkThemeRuntime_LIBRARIES = $(MARKTHEME_PATH_LIBRARIES)
MarkThemeRuntime_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror \
    $(MARKTHEME_PATH_CFLAGS) \
    -DMARKTHEME_RUNTIME_BUILD_NUMBER=$(MARKTHEME_RUNTIME_BUILD_NUMBER) \
    -I../core -I../compiler -I../ingestion -I../modules -I../platform \
    -I../runtime -I../store

include $(THEOS_MAKE_PATH)/tweak.mk
