TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME := idslog
idslog_FILES := main.mm
idslog_CFLAGS := -fobjc-arc
idslog_FRAMEWORKS := Foundation
idslog_PRIVATE_FRAMEWORKS := LoggingSupport
idslog_INSTALL_PATH := /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
