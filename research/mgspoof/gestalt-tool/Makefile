TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME := gestalt
gestalt_FILES := main.m
gestalt_CFLAGS := -fobjc-arc
gestalt_FRAMEWORKS := Foundation
gestalt_LDFLAGS := -lMobileGestalt
gestalt_INSTALL_PATH := /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
