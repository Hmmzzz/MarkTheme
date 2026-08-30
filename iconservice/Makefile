include ../Config.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeIconServiceRuntime

# 0 = disabled, 1 = pass-through observation, 2 = service source. The official
# package makes IconServices the sole ordinary application-icon pixel source.
MARKTHEME_ICON_SERVICE_RUNTIME_MODE ?= 2
# One exact reference request remains available only for an explicit
# diagnostic build; the official source policy is the live-ABI rollout below.
MARKTHEME_ICON_SERVICE_PROVEN_CANARY ?= 0
# Admit every exact bundle-backed application-icon request and let the
# immutable resolver decide whether that source has themed pixels.
MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT ?= 1
# Diagnostic bisection only; shipping candidates keep service control enabled.
MARKTHEME_ICON_SERVICE_STORE_CONTROL ?= 1

MarkThemeIconServiceRuntime_FILES = \
    MTIconServiceABI.m \
    MTIconServiceBootstrap.m \
    MTIconServiceGenerationAdapter.m \
    MTIconServiceImageResolver.m \
    MTIconServiceProvenCanary.m \
    MTIconServiceRuntimeMode.m \
    MTIconServiceSourcePolicy.m \
    MTIconServiceStoreInvalidator.m \
    ../runtime/MTRuntimeInvalidation.m \
    ../runtime/MTApplicationIconInvalidationScope.m \
    ../runtime/MTRuntimeFeatureState.m \
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
    -DMARKTHEME_ICON_SERVICE_PROVEN_CANARY=$(MARKTHEME_ICON_SERVICE_PROVEN_CANARY) \
    -DMARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT=$(MARKTHEME_ICON_SERVICE_GENERATION_ROLLOUT) \
    -DMARKTHEME_ICON_SERVICE_STORE_CONTROL=$(MARKTHEME_ICON_SERVICE_STORE_CONTROL) \
    -I. -I../core -I../compiler -I../ingestion -I../modules -I../platform \
    -I../runtime -I../store

include $(THEOS_MAKE_PATH)/tweak.mk
