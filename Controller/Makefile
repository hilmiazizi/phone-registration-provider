ARCHS = arm64

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
	TARGET := iphone:clang:latest:15.0
else
	TARGET := iphone:clang:latest:14.0
endif

include $(THEOS)/makefiles/common.mk

TOOL_NAME = BeepservController

LINK_DIRS := $(shell sh -c "find ../SocketRocket/SocketRocket -type d | xargs -I % echo -I%")
M_FILES := $(shell find ../SocketRocket/SocketRocket -type f -name '*.m')

$(TOOL_NAME)_FILES = $(wildcard *.x) $(wildcard *.m) ../Shared/Logging.m ../Shared/BPState.m ../Shared/BPPrefs.m ../Shared/BPTimer.m $(M_FILES) ../libroot/src/dyn.c
$(TOOL_NAME)_CFLAGS = -fobjc-arc -I../SocketRocket -Wno-deprecated $(LINK_DIRS)
$(TOOL_NAME)_LIBRARIES = MobileGestalt
$(TOOL_NAME)_CODESIGN_FLAGS = -Sentitlements.plist
$(TOOL_NAME)_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk