TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = idsbaa
idsbaa_FILES = Tweak.xm
idsbaa_CFLAGS = -fobjc-arc
idsbaa_FRAMEWORKS = Foundation Security

include $(THEOS_MAKE_PATH)/tweak.mk
