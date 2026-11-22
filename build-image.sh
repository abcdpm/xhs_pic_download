#!/usr/bin/env bash
#
# 构建主服务 Docker 镜像：<IMAGE>:<版本> + <IMAGE>:latest
#
# 用法：
#   ./build-image.sh                    # 版本取自 package.json（当前 1.0.1）
#   ./build-image.sh 1.0.2              # 指定版本
#   ./build-image.sh --push             # 构建后推送两个标签（需先 docker login）
#   ./build-image.sh --no-cache 1.0.2   # 不用缓存重建
#   ./build-image.sh --no-smoke         # 跳过容器冒烟测试
#   IMAGE=yourhub/xhs_pic_download ./build-image.sh
#
# 版本号优先级：命令行参数 > .env 里的 APP_VERSION > package.json 的 version
#
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-llllalex/xhs_pic_download}"
DOCKERFILE="Dockerfile"
VERSION_FILE="package.json"

VERSION=""
PUSH=0
NO_CACHE=0
SMOKE=1

log() { printf '\033[1;34m[image]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "\033[1;31m[error]\033[0m 构建失败（第 %s 行，退出码 %s）\n" "$LINENO" "$rc" >&2' ERR

usage() {
  cat <<'EOF'
构建主服务 Docker 镜像：<IMAGE>:<版本> + <IMAGE>:latest

用法：
  ./build-image.sh                    版本取自 package.json（当前 1.0.1）
  ./build-image.sh 1.0.2              指定版本
  ./build-image.sh --push             构建后推送两个标签（需先 docker login）
  ./build-image.sh --no-cache 1.0.2   不用缓存重建
  ./build-image.sh --no-smoke         跳过容器冒烟测试
  IMAGE=yourhub/xhs_pic_download ./build-image.sh

版本号优先级：命令行参数 > .env 的 APP_VERSION > package.json 的 version
EOF
}

# ---------- 参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    --no-smoke) SMOKE=0; shift ;;
    --image)
      [[ $# -ge 2 ]] || die "--image 需要一个值，如 yourhub/xhs_pic_download"
      IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "未知参数：$1（用 --help 查看用法）" ;;
    *)
      [[ -z "$VERSION" ]] || die "只能指定一个版本号（已给：$VERSION，又收到：$1）"
      VERSION="$1"; shift ;;
  esac
done

# ---------- 环境预检 ----------
command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 \
  || die "docker 守护进程不可用，请先启动 Docker（Docker Desktop 或 systemctl start docker）"
[[ -f "$DOCKERFILE" ]] || die "缺少 $DOCKERFILE（请在仓库根目录运行）"
[[ -f "$VERSION_FILE" ]] || die "缺少 $VERSION_FILE"

# ---------- 版本号 ----------
if [[ -z "$VERSION" && -f .env ]]; then
  VERSION="$(sed -n 's/^APP_VERSION[[:space:]]*=[[:space:]]*//p' .env 2>/dev/null | head -n 1 | xargs || true)"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE" 2>/dev/null | head -n 1)"
fi
VERSION="${VERSION:-1.0.1}"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*([-.+][0-9A-Za-z.-]+)?$ ]] || die "版本号格式不合法：$VERSION（应形如 1.0.1）"

PKG_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE" 2>/dev/null | head -n 1)"
if [[ -n "$PKG_VERSION" && "$PKG_VERSION" != "$VERSION" ]]; then
  warn "版本号 ${VERSION} 与 ${VERSION_FILE} 里的 ${PKG_VERSION} 不一致：只影响镜像标签与 OCI 标签，容器内的 package.json 仍是 ${PKG_VERSION}"
fi

REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERVER_VERSION="$(docker info --format '{{.ServerVersion}}')"

log "镜像：${IMAGE}"
log "版本：${VERSION}（revision ${REVISION}）"
log "Docker：${SERVER_VERSION}"

# ---------- 构建 ----------
BUILD_ARGS=()
if (( NO_CACHE )); then
  BUILD_ARGS+=(--no-cache)
fi

log "开始构建（首次需要下载 node:22-alpine 并 npm ci，耐心等）"
docker build "${BUILD_ARGS[@]}" \
  --label "org.opencontainers.image.title=xhs_pic_download" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.revision=${REVISION}" \
  --label "org.opencontainers.image.created=${BUILD_DATE}" \
  --label "org.opencontainers.image.source=https://github.com/abcdpm/xhs_pic_download" \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:latest" \
  -f "$DOCKERFILE" .

# ---------- 冒烟测试 ----------
# 用 docker exec 在容器内请求 /healthz：不依赖宿主网络，Mac / NAS / DinD 都可靠
if (( SMOKE )); then
  PORT="${SMOKE_PORT:-17776}"
  NAME="xhs-pic-download-smoke-$$"
  log "冒烟测试：启动临时容器并请求 /healthz"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if ! docker run -d --rm --name "$NAME" -p "127.0.0.1:${PORT}:7776" "${IMAGE}:${VERSION}" >/dev/null; then
    warn "临时容器启动失败，跳过冒烟测试"
  else
    OK=0
    for _ in $(seq 1 20); do
      if docker exec "$NAME" node -e "fetch('http://127.0.0.1:7776/healthz').then(r=>r.text()).then(t=>process.exit(t.trim()==='ok'?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
        OK=1
        break
      fi
      sleep 0.5
    done
    INNER_VERSION="$(docker exec "$NAME" node -p "require('./package.json').version" 2>/dev/null | tr -d '\r' || true)"
    if (( ! OK )); then
      docker logs "$NAME" 2>&1 | tail -20 >&2 || true
      docker stop "$NAME" >/dev/null 2>&1 || true
      die "容器内 /healthz 无响应，镜像不可用"
    fi
    docker stop "$NAME" >/dev/null 2>&1 || true
    if [[ -n "$INNER_VERSION" && "$INNER_VERSION" != "$PKG_VERSION" ]]; then
      warn "镜像内 package.json 版本为 ${INNER_VERSION}，与工作区 ${VERSION_FILE}(${PKG_VERSION}) 不一致（构建上下文可能不是最新）"
    fi
    log "冒烟测试通过：/healthz → ok，镜像内版本 ${INNER_VERSION:-unknown}"
  fi
fi

# ---------- 推送 ----------
if (( PUSH )); then
  log "推送 ${IMAGE}:${VERSION} 与 ${IMAGE}:latest"
  docker push "${IMAGE}:${VERSION}" || die "推送 ${IMAGE}:${VERSION} 失败（先 docker login）"
  docker push "${IMAGE}:latest" || die "推送 ${IMAGE}:latest 失败（先 docker login）"
  log "推送完成"
else
  log "未推送（需要发布时加 --push）"
fi

# ---------- 结果 ----------
SIZE_BYTES="$(docker image inspect -f '{{.Size}}' "${IMAGE}:${VERSION}")"
SIZE_HUMAN="$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.1f MB", b/1024/1024}')"
IMAGE_ID="$(docker image inspect -f '{{.Id}}' "${IMAGE}:${VERSION}" | cut -c8-19)"

cat <<EOF

────────────────────────────────────────────────────────
 镜像      ${IMAGE}:${VERSION}
 别名      ${IMAGE}:latest
 image id   ${IMAGE_ID}
 大小      ${SIZE_HUMAN}
 版本      ${VERSION}（revision ${REVISION}）
────────────────────────────────────────────────────────

部署（容器要调 Mac 上的 worker 时带上 LIVEPHOTO_WORKER_URL）：
  docker rm -f xhs_pic_download
  docker run -d -p 7776:7776 --name xhs_pic_download \\
    -e LIVEPHOTO_WORKER_URL=http://<Mac 的局域网 IP>:7777 \\
    -e LIVEPHOTO_ALBUM=小红书Live \\
    ${IMAGE}:${VERSION}

自检：
  curl -s http://127.0.0.1:7776/healthz
  docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' ${IMAGE}:${VERSION}
EOF
