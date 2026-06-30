ARCHS = arm64

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
	TARGET := iphone:clang:latest:15.0
else
	TARGET := iphone:clang:latest:14.0
endif

INSTALL_TARGET_PROCESSES = BeepservApplication

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = BeepservApplication

$(APPLICATION_NAME)_FILES = $(wildcard *.m) ../Shared/BPState.m ../Shared/Logging.m ../Shared/BPPrefs.m ../libroot/src/dyn.c
$(APPLICATION_NAME)_FRAMEWORKS = UIKit CoreGraphics
$(APPLICATION_NAME)_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
