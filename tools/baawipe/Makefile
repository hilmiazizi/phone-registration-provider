TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = baawipe
baawipe_FILES = Tweak.xm
baawipe_CFLAGS = -fobjc-arc
baawipe_FRAMEWORKS = Foundation Security
baawipe_LIBRARIES = dl

include $(THEOS_MAKE_PATH)/tweak.mk
