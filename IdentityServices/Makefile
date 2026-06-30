ARCHS = arm64

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
	TARGET := iphone:clang:latest:15.0
else
	TARGET := iphone:clang:latest:14.0
endif

include $(THEOS)/makefiles/common.mk

INSTALL_TARGET_PROCESSES = identityservicesd

TWEAK_NAME = BeepservIdentityServices

$(TWEAK_NAME)_FILES = $(wildcard *.x) ../Shared/BPTimer.m ../Shared/Logging.m ../libroot/src/dyn.c
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_LIBRARIES = MobileGestalt

include $(THEOS_MAKE_PATH)/tweak.mk