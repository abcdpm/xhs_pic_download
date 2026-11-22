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
# 不指定 -target 时，swiftc 会按「当前系统版本」去找标准库；当 Command Line Tools
# 比 macOS 旧时就会报
#   error: unable to load standard library for target 'arm64-apple-macosx27.2.0'
# 所以这里显式指定最小部署版本（与 Info.plist 的 LSMinimumSystemVersion 保持一致）。
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|x86_64) ;;
  *) die "未知的 CPU 架构：$HOST_ARCH（可用 SWIFT_TARGET 手动指定）" ;;
esac
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
SWIFT_TARGET="${SWIFT_TARGET:-${HOST_ARCH}-apple-macosx${MIN_MACOS}}"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"

# ---------- 工具链诊断 ----------
# 新版工具链布局（Xcode 15+/CLT 新版）：
#   - 标准库「模块」在 SDK 里：$SDK/usr/lib/swift/Swift.swiftmodule
#   - 运行时 dylib 在系统：  /usr/lib/swift/libswiftCore.dylib
#   - $DEV/usr/lib/swift/macosx 里只有 libswiftCompatibility*.a 之类的兼容库
# 所以判断依据是「SDK 模块 + 系统运行时 + 真编译一次」，而不是找 libswiftCore.dylib。
diagnose() {
  local dev_dir swiftc_path swift_ver sdk_path sdk_from_info
  local modules_ok=0 runtime_ok=0 compile_ok=0
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  swiftc_path="$(xcrun -f swiftc 2>/dev/null || true)"
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "$swiftc_path" ]]; then
    swift_ver="$("$swiftc_path" --version 2>&1 | head -1 || true)"
    sdk_from_info="$("$swiftc_path" -print-target-info 2>/dev/null \
      | sed -n 's/.*"sdkPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  else
    swift_ver="未知"
    sdk_from_info=""
  fi

  log "=== Swift 工具链诊断 ==="
  printf '  macOS         : %s (%s)\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)" "$HOST_ARCH"
  printf '  xcode-select  : %s\n' "${dev_dir:-未安装 / 未选择}"
  if [[ -d /Applications/Xcode.app ]]; then
    printf '  Xcode.app     : 已安装（可 sudo xcode-select -s /Applications/Xcode.app）\n'
  else
    printf '  Xcode.app     : 未安装\n'
  fi
  printf '  swiftc        : %s\n' "${swiftc_path:-找不到}"
  printf '  swiftc 版本   : %s\n' "$swift_ver"
  printf '  macOS SDK     : %s (version %s)\n' "${sdk_path:-未知}" "$SDK_VERSION"
  printf '  SDK(工具链)   : %s\n' "${sdk_from_info:-未知}"
  printf '  编译目标      : %s\n' "$SWIFT_TARGET"

  local mod_dir="${sdk_path}/usr/lib/swift/Swift.swiftmodule"
  if [[ -n "$sdk_path" && -d "$mod_dir" ]]; then
    printf '  Swift 模块    : OK   %s（%s 个文件）\n' "$mod_dir" "$(ls -1 "$mod_dir" 2>/dev/null | wc -l | tr -d ' ')"
    modules_ok=1
  else
    printf '  Swift 模块    : 缺失 %s\n' "$mod_dir"
  fi

  if [[ -f /usr/lib/swift/libswiftCore.dylib ]]; then
    printf '  运行时 stdlib : OK   /usr/lib/swift/libswiftCore.dylib\n'
    runtime_ok=1
  else
    printf '  运行时 stdlib : 缺失 /usr/lib/swift/libswiftCore.dylib\n'
  fi

  local probe_dir
  probe_dir="$(mktemp -d)"
  printf 'print("ok")\n' > "${probe_dir}/probe.swift"
  if "$SWIFTC" -target "$SWIFT_TARGET" "${probe_dir}/probe.swift" -o "${probe_dir}/probe" \
    >"${probe_dir}/out" 2>"${probe_dir}/err"; then
    printf '  编译测试      : OK（hello world 可编译）\n'
    compile_ok=1
  else
    printf '  编译测试      : 失败 → %s\n' "$(head -1 "${probe_dir}/err" | cut -c1-120)"
  fi
  rm -rf "$probe_dir"

  echo
  if (( compile_ok )); then
    log "结论：工具链可以正常编译，直接 ./build.sh 即可"
  elif (( modules_ok && runtime_ok )); then
    warn "结论：SDK 模块和运行时都在，但仍编译失败 → 多半是 SDK 与工具链版本错配"
    warn "建议：若已装 Xcode → sudo xcode-select -s /Applications/Xcode.app；否则重装 CLT 后重试"
  else
    warn "结论：工具链缺标准库（看上面「缺失」项）→ Command Line Tools 安装不完整"
    warn "修复 A：sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    warn "        等安装窗口提示完成，再 xcrun -f swiftc && swiftc --version 验证，然后 ./build.sh"
    warn "修复 B：sudo xcode-select -s /Applications/Xcode.app（已装完整 Xcode 时）"
  fi
}

if (( DIAGNOSE )); then
  diagnose
  exit 0
fi

# ---------- 工具链自检 ----------
# 用一个最小文件做 -typecheck：几秒内就能暴露「标准库缺失」这类环境问题，
# 而不是等长编译到一半才失败。
PROBE_DIR="$(mktemp -d)"
printf 'let probe = 1\nprint(probe)\n' > "${PROBE_DIR}/probe.swift"
log "自检 Swift 工具链（-typecheck，目标 ${SWIFT_TARGET}）"
if ! PROBE_ERR="$("$SWIFTC" -typecheck -target "$SWIFT_TARGET" "${PROBE_DIR}/probe.swift" 2>&1)"; then
  printf '%s\n' "$PROBE_ERR" | head -20 >&2
  rm -rf "$PROBE_DIR"
  die "Swift 工具链不可用（多数是标准库缺失 / Command Line Tools 未装完）。先运行：./build.sh --diagnose"
fi
rm -rf "$PROBE_DIR"
log "工具链自检通过"

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
"$SWIFTC" -O -swift-version 5 -target "$SWIFT_TARGET" \
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
