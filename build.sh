#!/bin/bash
# GMInject.dylib 构建脚本（macOS / GitHub Actions macOS runner）
# 产物：build/GMInject.dylib（fat: arm64 + arm64e，ad-hoc 签名）
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CLANG=$(xcrun --sdk iphoneos -f clang)
MIN="-miphoneos-version-min=14.0"
INSTALL_NAME="@executable_path/Frameworks/GMInject.dylib"
OUT=build
mkdir -p "$OUT"
rm -f "$OUT"/GMInject.*.dylib "$OUT"/GMInject.dylib

FLAGS="-dynamiclib -fobjc-arc -fobjc-exceptions -O2 -Wall \
  -framework Foundation \
  -install_name $INSTALL_NAME \
  -isysroot $SDK $MIN"

BUILT=""
for ARCH in arm64 arm64e; do
  echo "==> 编译 $ARCH"
  if $CLANG -arch "$ARCH" $FLAGS -o "$OUT/GMInject.$ARCH.dylib" GMInject.m 2>"$OUT/$ARCH.err"; then
    BUILT="$BUILT $OUT/GMInject.$ARCH.dylib"
  else
    echo "    $ARCH 编译失败，跳过："
    tail -20 "$OUT/$ARCH.err"
  fi
done

if [ -z "$BUILT" ]; then
  echo "没有任何架构编译成功"; exit 1
fi

if [ $(echo $BUILT | wc -w) -gt 1 ]; then
  lipo -create $BUILT -output "$OUT/GMInject.dylib"
else
  cp $BUILT "$OUT/GMInject.dylib"
fi

# ad-hoc 签名，TrollStore 安装时会整体重签
codesign --force --sign - "$OUT/GMInject.dylib" || true
echo "==> 产物"
lipo -info "$OUT/GMInject.dylib" || true
ls -lh "$OUT/GMInject.dylib"
