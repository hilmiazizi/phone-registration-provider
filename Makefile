# iPhone 7 (A10) is arm64-only; build against the theos-managed SDK/toolchain on
# Linux. The upstream rootful branch hardcodes a macOS Xcode 11.7 path that does
# not exist here, so derive everything from TARGET like idsbaa/MGSpoof do.
ARCHS = arm64

ifeq ($(THEOS_PACKAGE_SCHEME), rootless)
	TARGET := iphone:clang:latest:15.0
else
	TARGET := iphone:clang:latest:14.0
endif

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += IdentityServices
SUBPROJECTS += Controller
SUBPROJECTS += NotificationHelper
SUBPROJECTS += Application

include $(THEOS_MAKE_PATH)/aggregate.mk

# try to apply the patches that will make it work. If it exits with non-zero, that just means
# the patches are already applied, so we can safely ignore it with `|| :`
#
# The version of libroot included with Theos is not compatible
# with the arm64e ABI we use so we have to compile it ourselves
before-all::
	cd SocketRocket && git apply -q ../SocketRocket.patch || :
	cd libroot && git apply -q ../libroot.patch || :

after-install::
		install.exec "uicache -a"
		install.exec "sbreload"
		
after-stage::
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	$(ECHO_NOTHING) rm $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd-rootful.plist $(ECHO_END)
	$(ECHO_NOTHING) mv $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd-rootless.plist $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd.plist $(ECHO_END)
else
	$(ECHO_NOTHING) rm $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd-rootless.plist $(ECHO_END)
	$(ECHO_NOTHING) mv $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd-rootful.plist $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd.plist $(ECHO_END)
endif
	$(ECHO_NOTHING) mv $(THEOS_STAGING_DIR)/usr/libexec/BeepservController $(THEOS_STAGING_DIR)/usr/libexec/beepservd $(ECHO_END)
	$(ECHO_NOTHING) $(FAKEROOT) chown 0:0 $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.beeper.beepservd.plist $(ECHO_END)