#!/usr/bin/env bash
#
# 构建并推送主服务镜像：<IMAGE>:<APP_VERSION> + <IMAGE>:latest
#
# 版本号只从仓库根目录的 .env 读取（APP_VERSION），首次使用：
#   cp .env.example .env
#   ！发布新版本时改 .env 里的 APP_VERSION，例如 1.0.1 → 1.0.2
#
# 用法：
#   ./build-image.sh
#
# 前置条件：已 docker login（推送到 <IMAGE> 所属账号）
# 可选：IMAGE=yourhub/xhs_pic_download ./build-image.sh（默认 llllalex/xhs_pic_download）
#
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-llllalex/xhs_pic_download}"
DOCKERFILE="Dockerfile"
ENV_FILE=".env"

log() { printf '\033[1;34m[image]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; printf "\033[1;31m[error]\033[0m 构建失败（第 %s 行，退出码 %s）\n" "$LINENO" "$rc" >&2' ERR

# ---------- 预检 ----------
command -v docker >/dev/null 2>&1 || die "找不到 docker 命令"
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 \
  || die "docker 守护进程不可用，请先启动 Docker（Docker Desktop 或 systemctl start docker）"
[[ -f "$DOCKERFILE" ]] || die "缺少 $DOCKERFILE（请在仓库根目录运行）"
[[ -f "$ENV_FILE" ]] || die "缺少 $ENV_FILE：请先 cp .env.example .env，并把 APP_VERSION 设为要发布的版本（如 1.0.1）"

# ---------- 版本号（只从 .env 读取） ----------
VERSION="$(sed -n 's/^[[:space:]]*APP_VERSION[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | head -n 1)"
VERSION="${VERSION%$'\r'}"
VERSION="$(printf '%s' "$VERSION" | tr -d "\"'" | xargs)"
[[ -n "$VERSION" ]] || die "$ENV_FILE 里没有设置 APP_VERSION"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*([-.+][0-9A-Za-z.-]+)?$ ]] \
  || die "APP_VERSION 格式不合法：$VERSION（应形如 1.0.1）"

REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "镜像：${IMAGE}"
log "版本：${VERSION}（revision ${REVISION}）"

# ---------- 构建 ----------
log "开始构建（首次需要下载 node:22-alpine 并 npm ci）"
docker build \
  --label "org.opencontainers.image.title=xhs_pic_download" \
  --label "org.opencontainers.image.version=${VERSION}" \
  --label "org.opencontainers.image.revision=${REVISION}" \
  --label "org.opencontainers.image.created=${BUILD_DATE}" \
  --label "org.opencontainers.image.source=https://github.com/abcdpm/xhs_pic_download" \
  -t "${IMAGE}:${VERSION}" \
  -t "${IMAGE}:latest" \
  -f "$DOCKERFILE" .

# ---------- 推送 ----------
log "推送 ${IMAGE}:${VERSION}"
docker push "${IMAGE}:${VERSION}" || die "推送 ${IMAGE}:${VERSION} 失败，请先 docker login（或确认有该仓库权限）"

log "推送 ${IMAGE}:latest"
docker push "${IMAGE}:latest" || die "推送 ${IMAGE}:latest 失败"

# ---------- 结果 ----------
SIZE_BYTES="$(docker image inspect -f '{{.Size}}' "${IMAGE}:${VERSION}")"
SIZE_HUMAN="$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.1f MB", b/1024/1024}')"

cat <<EOF

────────────────────────────────────────────────────────
 已发布    ${IMAGE}:${VERSION}
           ${IMAGE}:latest
 大小      ${SIZE_HUMAN}
 版本      ${VERSION}（revision ${REVISION}）
────────────────────────────────────────────────────────

部署：
  docker pull ${IMAGE}:${VERSION}
  docker rm -f xhs_pic_download
  docker run -d -p 7776:7776 --name xhs_pic_download \\
    -e LIVEPHOTO_WORKER_URL=http://<Mac 的局域网 IP>:7777 \\
    -e LIVEPHOTO_ALBUM=小红书Live \\
    ${IMAGE}:${VERSION}

自检：
  curl -s http://127.0.0.1:7776/healthz
EOF
