ARCHS = arm64
# 改成自动适配最新SDK，不用指定具体版本，就不会找不到SDK了
TARGET = iphone:clang:latest:12.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = T3Bypass_IBOX
T3Bypass_IBOX_FILES = Tweak.xm
T3Bypass_IBOX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
