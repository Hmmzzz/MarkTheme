ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:17.0
THEOS_PACKAGE_SCHEME ?= roothide

ifeq ($(filter $(THEOS_PACKAGE_SCHEME),rootless roothide),)
$(error MarkTheme supports only THEOS_PACKAGE_SCHEME=rootless or roothide)
endif

# Only the platform target may know how a stable logical bootstrap path maps
# into the selected package namespace.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
MARKTHEME_PATH_LIBRARIES := roothide
MARKTHEME_PATH_CFLAGS := -DTHEOS_PACKAGE_SCHEME_ROOTHIDE=1
else
MARKTHEME_PATH_LIBRARIES :=
# The RootHide-compatible rootless stub exposes the same jbroot API while its
# internal jbrootat fd is intentionally unused.
MARKTHEME_PATH_CFLAGS := -Wno-unused-parameter \
    -DTHEOS_PACKAGE_SCHEME_ROOTLESS=1
endif

# Keep line tables and symbols for crash diagnosis without shipping -O0 code.
# An explicit non-Debug schema prevents Theos from appending its trailing -O0;
# disabling stripping retains the same symbolization workflow.
THEOS_SCHEMA := DEFAULT
STRIP := 0
OPTFLAG := -O2
# Keep both scheme artifacts on the same Debian version. Without an explicit
# value Theos increments its local build counter once per package, which would
# make a single dual-scheme build produce mismatched versions.
PACKAGE_VERSION ?= 0.2.7

# The Helper and mapped Runtime use this exact protocol generation in their
# one-shot Apply acknowledgement name. App-only releases may advance
# CFBundleVersion independently; increment this value only when Runtime
# behavior/source changes so an older mapped image cannot acknowledge a newer
# Runtime generation.
MARKTHEME_RUNTIME_BUILD_NUMBER := 167

# Keep Theos metadata normalization byte-oriented on the macOS host.
export LC_ALL := C
