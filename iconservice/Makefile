include ../Config.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeIconServiceRuntime

# 0 = disabled (default), 1 = pass-through observation, 2 = service source.
# This target is intentionally not in the root aggregate while source delivery,
# persistent invalidation, and every outer-cache owner are still under rollout.
MARKTHEME_ICON_SERVICE_RUNTIME_MODE ?= 0

MarkThemeIconServiceRuntime_FILES = \
    MTIconServiceABI.m \
    MTIconServiceBootstrap.m \
    MTIconServiceGenerationAdapter.m \
    MTIconServiceImageResolver.m \
    MTIconServiceRuntimeMode.m \
    MTIconServiceStoreIndex.m \
    MTIconServiceStoreInvalidator.m \
    ../runtime/MTRuntimeInvalidation.m \
    ../runtime/MTRuntimeKernel.m \
    ../runtime/MTRuntimePublishedImageLoader.m \
    ../runtime/MTRuntimeSnapshot.m \
    ../runtime/MTRuntimeSnapshotLoader.m \
    ../runtime/modules/MTIconMaskCompositor.m \
    ../runtime/modules/MTSpringBoardDecorationSnapshotResolver.m \
    ../runtime/modules/MTStaticIconSnapshotResolver.m \
    ../core/MTCanonicalJSON.m \
    ../core/MTDigest.m \
    ../core/MTIdentifier.m \
    ../core/MTModuleConfiguration.m \
    ../core/MTResourceKey.m \
    ../core/MTVersionContracts.m \
    ../compiler/MTGenerationDescriptor.m \
    ../compiler/MTGenerationIndexCodec.m \
    ../compiler/MTGenerationReader.m \
    ../compiler/MTGenerationReaderFilesystem.m \
    ../compiler/MTGenerationReaderValidation.m \
    ../modules/MTFolderIconContract.m \
    ../modules/MTIconMaskConfiguration.m \
    ../modules/MTIconMaskContract.m \
    ../modules/MTIconOverlayContract.m \
    ../modules/MTStaticIconConfiguration.m \
    ../platform/MTBootstrapPaths.m \
    ../store/MTRuntimeState.m

MarkThemeIconServiceRuntime_FRAMEWORKS = \
    Foundation CoreGraphics ImageIO CydiaSubstrate
MarkThemeIconServiceRuntime_LIBRARIES = $(MARKTHEME_PATH_LIBRARIES)
MarkThemeIconServiceRuntime_CFLAGS = \
    -fobjc-arc -fblocks -Wall -Wextra -Werror \
    $(MARKTHEME_PATH_CFLAGS) \
    -DMARKTHEME_RUNTIME_BUILD_NUMBER=$(MARKTHEME_RUNTIME_BUILD_NUMBER) \
    -DMARKTHEME_ICON_SERVICE_RUNTIME_MODE=$(MARKTHEME_ICON_SERVICE_RUNTIME_MODE) \
    -I. -I../core -I../compiler -I../ingestion -I../modules -I../platform \
    -I../runtime -I../store

include $(THEOS_MAKE_PATH)/tweak.mk
