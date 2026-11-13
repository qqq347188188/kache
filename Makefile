# macOS 本地构建：make / make clean
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := $(shell xcrun --sdk iphoneos -f clang)
MIN := -miphoneos-version-min=14.0
INSTALL_NAME := @executable_path/Frameworks/GMInject.dylib
FLAGS := -dynamiclib -fobjc-arc -fobjc-exceptions -O2 -Wall \
         -framework Foundation -install_name $(INSTALL_NAME) \
         -isysroot $(SDK) $(MIN)

.PHONY: all clean
all:
	@bash build.sh

clean:
	rm -rf build
