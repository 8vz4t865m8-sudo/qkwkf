ARCHS = arm64
TARGET = iphone:clang:16.0:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = T3Bypass_IBOX
T3Bypass_IBOX_FILES = Tweak.xm
T3Bypass_IBOX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
