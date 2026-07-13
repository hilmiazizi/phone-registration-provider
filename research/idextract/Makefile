TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = idextract
idextract_FILES = tweak.xm
idextract_CFLAGS = -fobjc-arc
idextract_FRAMEWORKS = Foundation Security

include $(THEOS_MAKE_PATH)/tweak.mk
