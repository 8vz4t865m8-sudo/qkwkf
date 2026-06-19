# 自动检测 SDK 路径，不硬编码版本
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CC := $(shell xcrun --sdk iphoneos -f clang 2>/dev/null)
LDID := $(shell which ldid 2>/dev/null)

all:
	@echo "SDK 路径: $(SDK)"
	@echo "编译器: $(CC)"
	$(CC) -arch arm64 -isysroot $(SDK) -dynamiclib \
		-o IBOXBypass.dylib \
		Tweak.m fishhook.c \
		-fobjc-arc \
		-framework Foundation \
		-framework UIKit \
		-miphoneos-version-min=15.0
	$(LDID) -S IBOXBypass.dylib
	ls -lh IBOXBypass.dylib
	@echo "✅ 编译完成"

clean:
	rm -f IBOXBypass.dylib
