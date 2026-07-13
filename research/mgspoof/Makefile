TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MGSpoof
MGSpoof_FILES := Tweak.xm
MGSpoof_CFLAGS := -fobjc-arc
MGSpoof_FRAMEWORKS := Foundation
MGSpoof_LDFLAGS := -lMobileGestalt
MGSpoof_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 identityservicesd apsd imagent IMDPersistenceAgent akd || true"
