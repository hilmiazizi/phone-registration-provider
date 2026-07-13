TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = dcrtforce
dcrtforce_FILES = Tweak.xm
dcrtforce_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
dcrtforce_FRAMEWORKS = Foundation Security
dcrtforce_LIBRARIES = dl

include $(THEOS_MAKE_PATH)/tweak.mk
