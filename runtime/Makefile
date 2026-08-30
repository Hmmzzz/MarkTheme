include ../Config.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeRuntime

MarkThemeRuntime_FILES = MTRuntimeBootstrap.m \
    MTRuntimeABIReport.m \
    MTApplicationIconInvalidationScope.m \
    MTRuntimeFeatureState.m \
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
    MTRuntimeWeakObjectMapSnapshot.m \
    adapters/MTApplicationIconNativeInvalidation.m \
    adapters/MTIconServicesClientCacheInvalidation.m \
    adapters/MTCalendarUIKitSourceAdapter.m \
    adapters/MTCalendarApplicationIconAdapter.m \
    adapters/MTIconMorphCarrierAdapter.m \
    adapters/MTIconShadowViewAdapter.m \
    adapters/MTBadgeBackgroundImageAdapter.m \
    adapters/MTClockImageSetAdapter.m \
    adapters/MTDialerButtonAdapter.m \
    adapters/MTFolderBackgroundImageAdapter.m \
    adapters/MTPreferencesUIResourceImageAdapter.m \
    adapters/MTPreferencesABI.m \
    adapters/MTMobilePhoneDialerABI.m \
    adapters/MTShareSheetActivityIdentity.m \
    adapters/MTShareSheetActivityGlyphAdapter.m \
    adapters/MTSearchUICalendarIconAdapter.m \
    adapters/MTStatusBarSignalImageAdapter.m \
    adapters/MTStatusBarSurfaceABI.m \
    adapters/MTShareSheetABI.m \
    adapters/MTSearchUIABI.m \
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
    modules/MTIconOverlaySnapshotModule.m \
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
    ../modules/MTIconOverlayContract.m \
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

# The overlay resolver now records bounded geometry-rich rejection evidence in
# addition to composing pixels. Size-optimize this self-contained ModuleRuntime
# so the dual-slice diagnostic build stays within the injected-image ceiling.
modules/MTIconOverlaySnapshotModule.m_CFLAGS = -Oz
# Static-icon resolution is now used only by live Calendar/Clock adapters in
# display processes. Keep this self-contained unit compact; ordinary app-icon
# composition lives in the separate IconServices source image.
modules/MTStaticIconSnapshotModule.m_CFLAGS = -Oz
# Folder rendering now maintains both its optional themed background and one
# final global-overlay view. Keep that lifecycle-only ModuleRuntime compact in
# both slices; image decoding and composition remain in the shared modules.
modules/MTFolderIconSnapshotModule.m_CFLAGS = -Oz
# SBIconView contributes only lifecycle tracking and exact ABI probes. Keep
# that bridge size-optimized as well so both debug-symbol packages remain
# below the 2 MiB injected Runtime ceiling.
adapters/MTIconShadowViewAdapter.m_CFLAGS = -Oz
# The morph carrier retains only the exact IconServices-produced square image
# while SpringBoard performs its return-home geometry transition.
adapters/MTIconMorphCarrierAdapter.m_CFLAGS = -Oz
# Registry work runs only while one Runtime profile is being configured; it
# is not on an icon render path. Size-optimize that coordination unit so the
# dual-slice symbolized Runtime retains its strict injection ceiling as adapters
# gain independently ABI-probed OS routes.
adapters/MTRuntimeAdapterRegistry.m_CFLAGS = -Oz
# The remaining activity hook is scoped to non-application glyphs; native
# application image providers are intentionally absent from the target.
adapters/MTShareSheetActivityGlyphAdapter.m_CFLAGS = -Oz
# Native owner discovery and invalidation run only on theme-state changes.
adapters/MTApplicationIconNativeInvalidation.m_CFLAGS = -Oz
# Process-local IconServices invalidation is a low-frequency transaction with
# exact runtime ABI gates; keep that control-plane unit compact.
adapters/MTIconServicesClientCacheInvalidation.m_CFLAGS = -Oz
# CalendarUIKit is the single process-local producer for dynamic Calendar
# pixels. Keep its exact ABI gate/source bridge compact in both display hosts.
adapters/MTCalendarUIKitSourceAdapter.m_CFLAGS = -Oz
# The existing Preferences cache bridge is also probe-heavy and off the hot
# render path. Size-optimize it together with the new application-icon bridge.
adapters/MTPreferencesUIResourceImageAdapter.m_CFLAGS = -Oz
# ABI reporting serializes small diagnostic dictionaries and is size-optimized
# inside injected system processes.
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
# process and loaded-ShareSheet image gates rather than spending Runtime
# budget on constructor-only control flow.
MTRuntimeProfile.m_CFLAGS = -Oz
# Share identity traversal is a short, exact-getter chain off the render path.
# Keep the iOS 16 remote-activity fallback compact in both Runtime slices.
adapters/MTShareSheetActivityIdentity.m_CFLAGS = -Oz
# Generated process profiles are immutable bootstrap metadata read once per
# injected host. Size-optimize this table so adding one exact compatibility
# host does not consume the symbolized Runtime's strict injection budget.
MTRuntimeProfiles.generated.m_CFLAGS = -Oz

include $(THEOS_MAKE_PATH)/tweak.mk
