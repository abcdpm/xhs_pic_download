#!/usr/bin/env bash
# 编译 Live Photo 导入器（macOS + Xcode Command Line Tools）
# 用 -sectcreate __TEXT __info_plist 把 Info.plist 嵌进二进制，
# 否则 TCC 拿不到 NSPhotoLibraryAddUsageDescription，会直接拒绝照片权限。
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "此脚本必须在 macOS 上运行" >&2
  exit 1
fi

mkdir -p bin

xcrun swiftc -O -swift-version 5 \
  -o bin/lpimport \
  LivePhotoImporter.swift \
  -framework Foundation \
  -framework Photos \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

# ad-hoc 签名，让 TCC 对二进制有稳定的身份标识（升级后不会反复弹权限）
codesign --force --sign - --identifier com.nfew.xhs-livephoto.importer bin/lpimport 2>/dev/null || \
  echo "warn: codesign 失败，权限可能在每次重新编译后重新询问" >&2

echo "built: $(pwd)/bin/lpimport"
./bin/lpimport --help
