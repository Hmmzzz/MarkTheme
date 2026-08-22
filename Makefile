_THEOS_PLATFORM_DPKG_DEB := $(CURDIR)/scripts/marktheme64e-dpkg-deb
export MARKTHEME64E_UPSTREAM_DM := $(THEOS)/vendor/dm.pl/dm.pl

include Config.mk
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += app
SUBPROJECTS += helper
SUBPROJECTS += runtime

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
PACKAGE_DEPENDS += roothide
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: package-roothide package-rootless package-all test

package-roothide:
	./scripts/build-packages roothide

package-rootless:
	./scripts/build-packages rootless

package-all:
	./scripts/build-packages roothide rootless

test:
	./tests/run
