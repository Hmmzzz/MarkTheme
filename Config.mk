ARCHS := arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME ?= rootless

ifeq ($(filter $(THEOS_PACKAGE_SCHEME),rootless roothide),)
$(error MarkTheme64e supports only THEOS_PACKAGE_SCHEME=rootless or roothide)
endif

# Only the platform target may know how a stable logical bootstrap path maps
# into the selected package namespace.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
MARKTHEME64E_PATH_LIBRARIES := roothide
MARKTHEME64E_PATH_CFLAGS :=
else
MARKTHEME64E_PATH_LIBRARIES :=
# The RootHide-compatible rootless stub exposes the same jbroot API while its
# internal jbrootat fd is intentionally unused.
MARKTHEME64E_PATH_CFLAGS := -Wno-unused-parameter
endif

# Keep symbols while the project is under active development.
DEBUG := 1
# Keep both scheme artifacts on the same Debian version. Without an explicit
# value Theos increments its local build counter once per package, which would
# make a single dual-scheme build produce mismatched versions.
BASE_VERSION ?= 0.1.9-64e
BUILD_NUMBER ?= 1
PACKAGE_VERSION ?= $(BASE_VERSION)-b$(BUILD_NUMBER)

# The Helper and mapped Runtime use this exact protocol generation in their
# one-shot Apply acknowledgement name. App-only releases may advance
# CFBundleVersion independently; increment this value only when Runtime
# behavior/source changes so an older mapped image cannot acknowledge a newer
# Runtime generation.
MARKTHEME64E_RUNTIME_BUILD_NUMBER := 106

# Keep Theos metadata normalization byte-oriented on the macOS host.
export LC_ALL := C
