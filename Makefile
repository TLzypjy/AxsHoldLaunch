DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include AxsHoldLaunchBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsHoldLaunch
AxsHoldLaunch_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsHoldLaunch_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsHoldLaunch_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsHoldLaunch_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
