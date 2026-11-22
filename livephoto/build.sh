#!/usr/bin/env bash
#
# 编译 Live Photo 导入器 lpimport（仅限 macOS + Xcode Command Line Tools）
#
# 用法：
#   ./build.sh                     # 版本取自 package.json，构建号取自 git 提交数
#   VERSION=1.0.2 ./build.sh       # 临时指定版本
#   ./build.sh --version 1.0.2     # 同上
#   ./build.sh --build 42          # 指定构建号
#   ./build.sh --clean             # 先清空 bin/ 再编译
#   ./build.sh --help
#
# 产物：
#   bin/lpimport     带 __info_plist（版本 + 照片用途说明）+ ad-hoc 签名
#   bin/VERSION      版本与构建号
#   bin/.build/      中间产物（注入版本后的 Info.plist）
#
set -euo pipefail
cd "$(dirname "$0")"

readonly SRC="LivePhotoImporter.swift"
readonly PLIST_TEMPLATE="Info.plist"
readonly OUT_DIR="bin"
readonly BIN="${OUT_DIR}/lpimport"
readonly BUILD_DIR="${OUT_DIR}/.build"
# package.json 里的 version 是版本号的唯一来源，改这里即可，不用动脚本
readonly VERSION_FILE="package.json"

CLEAN=0
VERSION=""
BUILD_NUMBER=""

usage() {
  cat <<'EOF'
编译 Live Photo 导入器 lpimport（仅限 macOS + Xcode Command Line Tools）

用法：
  ./build.sh                     # 版本取自 package.json，构建号取自 git 提交数
  VERSION=1.0.2 ./build.sh       # 临时指定版本
  ./build.sh --version 1.0.2     # 同上
  ./build.sh --build 42          # 指定构建号
  ./build.sh --clean             # 先清空 bin/ 再编译
  ./build.sh --help

产物：
  bin/lpimport     带 __info_plist（版本 + 照片用途说明）+ ad-hoc 签名
  bin/VERSION      版本与构建号
  bin/.build/      中间产物（注入版本后的 Info.plist）
EOF
}

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "\033[1;31m[error]\033[0m 构建失败（第 %s 行，退出码 %s）\n" "$LINENO" "$rc" >&2' ERR

# ---------- 参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version 需要一个值，如 1.0.2"
      VERSION="$2"; shift 2 ;;
    --build)
      [[ $# -ge 2 ]] || die "--build 需要一个值，如 42"
      BUILD_NUMBER="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

# ---------- 环境预检 ----------
[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只能在 macOS 上运行（当前：$(uname -s)）"
command -v xcrun >/dev/null 2>&1 || die "缺少 xcrun，请先安装 Xcode Command Line Tools：xcode-select --install"
SWIFTC="$(xcrun -f swiftc 2>/dev/null || true)"
[[ -n "$SWIFTC" && -x "$SWIFTC" ]] || die "找不到 swiftc，请运行 xcode-select --install"
command -v plutil >/dev/null 2>&1 || die "缺少 plutil（正常 macOS 自带）"
[[ -f "$SRC" ]] || die "缺少源文件 $SRC（请在 livephoto/ 目录下运行）"
[[ -f "$PLIST_TEMPLATE" ]] || die "缺少 $PLIST_TEMPLATE"

# ---------- 版本号 / 构建号 ----------
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE" 2>/dev/null | head -n 1)"
fi
VERSION="${VERSION:-1.0.1}"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*([-.+][0-9A-Za-z.-]+)?$ ]] || die "版本号格式不合法：$VERSION（应形如 1.0.1）"

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
[[ "$BUILD_NUMBER" =~ ^[0-9A-Za-z.]+$ ]] || die "构建号格式不合法：$BUILD_NUMBER"

# ---------- 清理 / 准备目录 ----------
if (( CLEAN )); then
  log "清理 $OUT_DIR"
  rm -rf "$OUT_DIR"
fi
mkdir -p "$BUILD_DIR"

# ---------- 生成带版本的 Info.plist ----------
PLIST_BUILD="${BUILD_DIR}/Info.plist"
cp "$PLIST_TEMPLATE" "$PLIST_BUILD"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_BUILD"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST_BUILD"
plutil -lint "$PLIST_BUILD" >/dev/null || die "生成的 Info.plist 不合法：$PLIST_BUILD"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST_BUILD")"

log "版本 ${VERSION}（build ${BUILD_NUMBER}），bundle id：${BUNDLE_ID}"
log "编译器：${SWIFTC}"

# ---------- 编译 ----------
# Info.plist 必须用 __info_plist 段嵌进二进制，否则 TCC 拿不到
# NSPhotoLibraryAddUsageDescription，请求照片权限会被直接拒绝。
log "编译 ${SRC} → ${BIN}"
"$SWIFTC" -O -swift-version 5 \
  -o "$BIN" \
  "$SRC" \
  -framework Foundation \
  -framework Photos \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST_BUILD"
[[ -x "$BIN" ]] || die "编译产物不存在或不可执行：$BIN"

# ---------- 签名 ----------
# ad-hoc 签名给 TCC 一个稳定的身份，重新编译后不会反复弹权限
if codesign --force --sign - --identifier "$BUNDLE_ID" "$BIN" 2>/dev/null; then
  log "ad-hoc 签名完成（identifier：${BUNDLE_ID}）"
else
  warn "codesign 失败，每次重新编译后系统可能再次询问照片权限"
fi

# ---------- 冒烟测试 ----------
log "冒烟测试：--version / --help"
VERSION_OUT="$("$BIN" --version)"
[[ "$VERSION_OUT" == *"$VERSION"* ]] || die "--version 输出不符合预期：${VERSION_OUT}"
"$BIN" --help >/dev/null || die "--help 执行失败"

printf '%s (build %s)\n' "$VERSION" "$BUILD_NUMBER" > "${OUT_DIR}/VERSION"

# ---------- 产物信息 ----------
ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
SIZE="$(du -h "$BIN" | cut -f1)"
SHA="$(shasum -a 256 "$BIN" | awk '{print $1}')"

cat <<EOF

────────────────────────────────────────────────────────
 版本      ${VERSION} (build ${BUILD_NUMBER})
 架构      ${ARCHS}
 大小      ${SIZE}
 sha256     ${SHA}
 产物      $(pwd)/${BIN}
 版本文件  $(pwd)/${OUT_DIR}/VERSION
────────────────────────────────────────────────────────

下一步：  node worker.js        # 首次运行会请求「照片」权限
自检：    curl -s http://127.0.0.1:7777/health
EOF
