include ../Config.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = marktheme64e-helper

marktheme64e-helper_FILES = main.m \
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
marktheme64e-helper_LIBRARIES = $(MARKTHEME64E_PATH_LIBRARIES)
marktheme64e-helper_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror \
    $(MARKTHEME64E_PATH_CFLAGS) \
    -DMARKTHEME64E_RUNTIME_BUILD_NUMBER=$(MARKTHEME64E_RUNTIME_BUILD_NUMBER) \
    -I../core -I../compiler -I../ingestion -I../platform -I../runtime -I../store
marktheme64e-helper_CODESIGN_FLAGS = -Sentitlements.plist
marktheme64e-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
