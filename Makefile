ARCHS = arm64
TARGET = iphone:clang:15.0:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IBOXBypass
IBOXBypass_FILES = Tweak.m fishhook.c
IBOXBypass_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
