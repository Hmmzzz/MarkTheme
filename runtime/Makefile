include ../Config.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeRuntime

MarkThemeRuntime_FILES = MTRuntimeBootstrap.m \
    MTRuntimeABIReport.m \
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
    adapters/MTPreferencesApplicationIconAdapter.m \
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

# Keep the live icon producer/cache hot path symbolized for development while
# compiling this one diagnostic-heavy translation unit for minimum code size.
# The rest of the debug Runtime remains at Theos' default -O0.
adapters/MTIconImageCacheAdapter.m_CFLAGS = -Oz
# SBIconView contributes only lifecycle tracking and exact ABI probes. Keep
# that bridge size-optimized as well so both debug-symbol packages remain
# below the 2 MiB injected Runtime ceiling.
adapters/MTIconShadowViewAdapter.m_CFLAGS = -Oz
# Registry work runs only while one Runtime profile is being configured; it
# is not on an icon render path. Size-optimize that coordination unit so the
# dual-slice debug Runtime retains its strict injection ceiling as adapters
# gain independently ABI-probed OS routes.
adapters/MTRuntimeAdapterRegistry.m_CFLAGS = -Oz
# Share hooks keep detailed ABI probes but only execute small original-first
# replacements on the data plane. Size-optimize this translation unit so its
# split late-image routes fit the dual-slice debug Runtime ceiling.
adapters/MTShareSheetActivityImageAdapter.m_CFLAGS = -Oz
# Preferences' application-icon bridge contains ABI probes and one small
# original-first producer Hook. Keep it compact under the injected Runtime's
# strict dual-slice size ceiling.
adapters/MTPreferencesApplicationIconAdapter.m_CFLAGS = -Oz
# The existing Preferences cache bridge is also probe-heavy and off the hot
# render path. Size-optimize it together with the new application-icon bridge.
adapters/MTPreferencesIconImageCacheAdapter.m_CFLAGS = -Oz
# ABI reporting serializes small diagnostic dictionaries and does not benefit
# from debug O0 code generation inside injected system processes.
MTRuntimeABIReport.m_CFLAGS = -Oz
# Bootstrap performs profile selection and one-time module wiring before its
# constructor returns. Keep that control plane compact; image render paths do
# not execute this unit after startup.
MTRuntimeBootstrap.m_CFLAGS = -Oz
# Snapshot loading and validation runs only at startup or after a generation
# notification. Optimize that control-plane unit for size; resolved images
# remain cached and render hooks never enter it per frame.
MTRuntimeSnapshotLoader.m_CFLAGS = -Oz
# Profile resolution runs once at dylib bootstrap. Size-optimize its exact
# process and loaded-ShareSheet image gates rather than spending debug Runtime
# budget on constructor-only control flow.
MTRuntimeProfile.m_CFLAGS = -Oz
# Share identity traversal is a short, exact-getter chain off the render path.
# Keep the iOS 16 remote-activity fallback compact in both Runtime slices.
adapters/MTShareSheetActivityIdentity.m_CFLAGS = -Oz
# Generated process profiles are immutable bootstrap metadata read once per
# injected host. Size-optimize this table so adding one exact compatibility
# host does not consume the debug Runtime's strict injection budget.
MTRuntimeProfiles.generated.m_CFLAGS = -Oz

include $(THEOS_MAKE_PATH)/tweak.mk
