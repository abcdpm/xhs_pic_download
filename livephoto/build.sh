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
DIAGNOSE=0

usage() {
  cat <<'EOF'
编译 Live Photo 导入器 lpimport（仅限 macOS + Xcode Command Line Tools）

用法：
  ./build.sh                     # 版本取自 package.json，构建号取自 git 提交数
  VERSION=1.0.2 ./build.sh       # 临时指定版本
  ./build.sh --version 1.0.2     # 同上
  ./build.sh --build 42          # 指定构建号
  ./build.sh --clean             # 先清空 bin/ 再编译
  ./build.sh --diagnose          # 只打印工具链诊断信息（编译失败时先跑这个）
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
    --diagnose) DIAGNOSE=1; shift ;;
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

# ---------- 目标架构 / 部署版本 ----------
# 常见坑：swiftc 找不到标准库时只会报
#   error: unable to load standard library for target 'arm64-apple-macosx…'
# 可能原因有两种，这里都处理：
#   1) 没有显式 -sdk，驱动自己探测不到 SDK（CLT 目录残缺时很常见）
#   2) 新 SDK 的 stdlib 模块不再支持过低的部署目标（如 macOS 11）
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *) die "未知的 CPU 架构：$HOST_ARCH（可用 SWIFT_TARGET 手动指定）" ;;
esac
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
SWIFT_TARGET="${SWIFT_TARGET:-${HOST_ARCH}-apple-macosx${MIN_MACOS}}"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
SDK_ARGS=()
[[ -n "$SDK_PATH" ]] && SDK_ARGS=(-sdk "$SDK_PATH")

PROBE_DIR="$(mktemp -d)"
PROBE_SRC="${PROBE_DIR}/probe.swift"
printf 'print("ok")\n' > "$PROBE_SRC"
cleanup_probe() { rm -rf "$PROBE_DIR" 2>/dev/null || true; }
trap 'cleanup_probe' EXIT

probe_compile() {
  "$SWIFTC" "${SDK_ARGS[@]}" -target "$1" -typecheck "$PROBE_SRC" 2>&1
}

# 候选部署目标：用户指定 → 11 → 12 … → 宿主系统主版本
TARGET_CANDIDATES=("$SWIFT_TARGET")
for v in 12.0 13.0 14.0 15.0 16.0 26.0; do
  t="${HOST_ARCH}-apple-macosx${v}"
  [[ " ${TARGET_CANDIDATES[*]} " == *" ${t} "* ]] || TARGET_CANDIDATES+=("$t")
done
HOST_MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || true)"
if [[ -n "$HOST_MAJOR" ]]; then
  t="${HOST_ARCH}-apple-macosx${HOST_MAJOR}.0"
  [[ " ${TARGET_CANDIDATES[*]} " == *" ${t} "* ]] || TARGET_CANDIDATES+=("$t")
fi
# 再补一个「SDK 主版本」候选：某些机器 sw_vers 拿不到版本号，但 SDK 版本是已知的
if [[ "$SDK_VERSION" =~ ^([0-9]+)\.[0-9]+$ ]]; then
  t="${HOST_ARCH}-apple-macosx${BASH_REMATCH[1]}.0"
  [[ " ${TARGET_CANDIDATES[*]} " == *" ${t} "* ]] || TARGET_CANDIDATES+=("$t")
fi

# ---------- 工具链诊断 ----------
# 新版工具链布局（Xcode 15+/CLT 新版）：
#   - 标准库「模块」在 SDK 里：$SDK/usr/lib/swift/Swift.swiftmodule
#   - 运行时 dylib 交给系统（/usr/lib/swift 或 dyld 共享缓存）
#   - $DEV/usr/lib/swift/macosx 里只有 libswiftCompatibility*.a 之类的兼容库
# 因此判断依据是「SDK 模块 + swiftc 的 -print-target-info + 真编译一次」。
diagnose() {
  local dev_dir swift_ver mod_dir count
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  swift_ver="$("$SWIFTC" --version 2>&1 | head -1 || true)"
  count="$(pkgutil --pkgs 2>/dev/null | grep -ci 'commandlinetools' || true)"

  log "=== Swift 工具链诊断 ==="
  printf '  macOS         : %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" "$HOST_ARCH"
  printf '  xcode-select  : %s\n' "${dev_dir:-未安装 / 未选择}"
  printf '  CLT 安装记录  : %s 条（0 条说明不是正常安装，或安装记录已损坏）\n' "${count:-0}"
  if [[ -d /Applications/Xcode.app ]]; then
    printf '  Xcode.app     : 已安装（可 sudo xcode-select -s /Applications/Xcode.app）\n'
  else
    printf '  Xcode.app     : 未安装\n'
  fi
  printf '  swiftc        : %s\n' "${SWIFTC:-找不到}"
  printf '  swiftc 版本   : %s\n' "$swift_ver"
  printf '  macOS SDK     : %s (version %s)\n' "${SDK_PATH:-未知}" "$SDK_VERSION"

  mod_dir="${SDK_PATH}/usr/lib/swift/Swift.swiftmodule"
  if [[ -n "$SDK_PATH" && -d "$mod_dir" ]]; then
    printf '  Swift 模块    : OK   %s\n' "$mod_dir"
    ls -1 "$mod_dir" 2>/dev/null | head -6 | sed 's/^/                     /'
  else
    printf '  Swift 模块    : 缺失 %s\n' "$mod_dir"
  fi

  printf '  swiftc -print-target-info（前 20 行）:\n'
  "$SWIFTC" -print-target-info 2>&1 | head -20 | sed 's/^/    /' || true
  echo

  printf '  编译探测（-sdk 已显式传入）:\n'
  local t err chosen=""
  for t in "${TARGET_CANDIDATES[@]}"; do
    if err="$(probe_compile "$t")"; then
      printf '    OK   %s\n' "$t"
      chosen="$t"
      break
    fi
    printf '    失败 %s → %s\n' "$t" "$(printf '%s' "$err" | head -1 | cut -c1-110)"
  done
  echo

  if [[ -n "$chosen" ]]; then
    log "结论：可用。最低部署版本 = ${chosen#*-apple-macosx}（build.sh 会自动选它）"
    log "      ./build.sh 直接用即可；想固定可用 MACOSX_DEPLOYMENT_TARGET=${chosen#*-apple-macosx} ./build.sh"
  else
    warn "结论：所有候选目标都编译不了，属于工具链本身的问题（与项目代码无关）"
    warn "原因 A：这套 Command Line Tools 不是正常安装（你这台 CLT 安装记录为 0 条）"
    warn "        修复：sudo rm -rf /Library/Developer/CommandLineTools"
    warn "              softwareupdate --list | grep -i 'command line'   # 看有没有可装的 CLT"
    warn "              sudo softwareupdate -i '<上面列出的名字>'         # 或用系统设置 > 通用 > 软件更新"
    warn "原因 B：装了完整 Xcode 但 xcode-select 指向 CLT"
    warn "        修复：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
}

if (( DIAGNOSE )); then
  diagnose
  exit 0
fi

# ---------- 工具链自检：自动挑选可用的最低部署版本 ----------
log "自检 Swift 工具链（-typecheck）"
CHOSEN_TARGET=""
LAST_PROBE_ERR=""
for t in "${TARGET_CANDIDATES[@]}"; do
  if ERR="$(probe_compile "$t")"; then
    CHOSEN_TARGET="$t"
    break
  fi
  LAST_PROBE_ERR="$ERR"
done
if [[ -z "$CHOSEN_TARGET" ]]; then
  printf '%s\n' "$LAST_PROBE_ERR" | head -20 >&2
  die "Swift 工具链无法编译任何目标（与项目代码无关）。先运行：./build.sh --diagnose"
fi
SWIFT_TARGET="$CHOSEN_TARGET"
log "工具链自检通过（目标 ${SWIFT_TARGET}）"

# ---------- 生成带版本的 Info.plist ----------
PLIST_BUILD="${BUILD_DIR}/Info.plist"
cp "$PLIST_TEMPLATE" "$PLIST_BUILD"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_BUILD"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST_BUILD"
plutil -lint "$PLIST_BUILD" >/dev/null || die "生成的 Info.plist 不合法：$PLIST_BUILD"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST_BUILD")"

log "版本 ${VERSION}（build ${BUILD_NUMBER}），bundle id：${BUNDLE_ID}"
log "编译器：${SWIFTC}"
log "目标：${SWIFT_TARGET}（macOS SDK ${SDK_VERSION}）"

# ---------- 编译 ----------
# Info.plist 必须用 __info_plist 段嵌进二进制，否则 TCC 拿不到
# NSPhotoLibraryAddUsageDescription，请求照片权限会被直接拒绝。
log "编译 ${SRC} → ${BIN}"
"$SWIFTC" -O -swift-version 5 "${SDK_ARGS[@]}" -target "$SWIFT_TARGET" \
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
