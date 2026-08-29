include ../Config.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = marktheme-helper

# State publication is not visible to client runtimes until IconServices has
# loaded the same Generation and completed its native type-2 whole-cache clear.
MARKTHEME_ICON_SERVICE_BARRIER_REQUIRED ?= 1

marktheme-helper_FILES = main.m \
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
    ../platform/MTBootstrapPaths.m \
    ../runtime/MTRuntimeInvalidation.m \
    ../store/MTRuntimeState.m \
    ../store/MTRuntimeStoreController.m
marktheme-helper_LIBRARIES = $(MARKTHEME_PATH_LIBRARIES)
marktheme-helper_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror \
    $(MARKTHEME_PATH_CFLAGS) \
    -DMARKTHEME_RUNTIME_BUILD_NUMBER=$(MARKTHEME_RUNTIME_BUILD_NUMBER) \
    -DMARKTHEME_ICON_SERVICE_BARRIER_REQUIRED=$(MARKTHEME_ICON_SERVICE_BARRIER_REQUIRED) \
    -I../core -I../compiler -I../ingestion -I../platform -I../runtime -I../store
marktheme-helper_CODESIGN_FLAGS = -Sentitlements.plist
marktheme-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
