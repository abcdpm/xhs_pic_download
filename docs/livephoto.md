# 小红书 Live Photo 自动合成方案（基于 master @ d3f627f）

> 目标：粘贴小红书分享链接后，**无需任何手工操作**，Live Photo 直接出现在 iPhone 的「照片」里，可长按播放。

## 1. 现状分析（最新代码）

### 1.1 数据流

```
iOS 快捷指令 ──(shareText)──> GET|POST /getXhsPicUrl
                                   │
   main.js:
     assertAllowed()      只允许 xhslink.com / xhslink.cn / xiaohongshu.com，重定向也校验（防 SSRF）
     getHeaders()         iPhone Safari UA —— 桌面 UA 会被重定向到 /login 登录墙
     findDom()            JSON.parse 解析 window.__INITIAL_STATE__（已不再 eval 远程内容）
     findNote()           移动版 state.noteData.data.noteData / 桌面版 note.noteDetailMap[id].note
     图片                 https://ci.xiaohongshu.com/<picId>（原图；带 imageView2 参数已 404）
     Live 视频            imageList[i].stream.h264[0].masterUrl
     普通视频             note.video.media.stream（streamType 不匹配时回退 h265/h264/av1）
                                   ↓
                picUrlArray: [原图..., Live视频..., 普通视频]   ← 扁平、无配对信息
```

### 1.2 上游 5 个新提交对「Live Photo 合成」的影响

| 提交 | 内容 | 对本方案的影响 |
|---|---|---|
| `b200484` | iPhone UA + 移动版页面结构；图片改为裸原图 URL | ✅ 利好：原图保留完整分辨率与 EXIF；⚠️ 但原图可能是 **webp/heic**，静止帧必须由服务端转 JPEG（`format/jpg` 参数已失效） |
| `143bb64` | `assertAllowed` + `beforeRedirect` 域名白名单，取消 `eval` | ⚠️ **架构约束**：`sns-video-hw.xhscdn.com` 不在白名单内，主服务不能替客户端下载视频 → 下载必须发生在 Mac 的 worker 里 |
| `6f5ec2c` | Docker 改 Node 22 + `npm ci` | worker 侧同样按 Node 18+/22 部署 |
| `400f3c4` | 支持 `xhslink.cn` 短链 | 无影响 |
| `d3f627f` | `/healthz`、JSON body 限 16KB、隐藏 `x-powered-by` | 转发给 worker 的 body 很小，不受影响；后续若加批量接口要注意 16KB 限制 |

### 1.3 仍然缺失、必须补的能力

| # | 缺口 | 现状 | 处理 |
|---|---|---|---|
| 1 | **图片与 Live 视频没有配对关系** | 两者被拍平进同一个数组，客户端只知道"有几段视频" | 新增 `items[]`，逐图携带 `livePhotoVideoUrl` / `isLivePhoto` |
| 2 | **没有合成能力** | 返回的是两个独立文件；iOS 快捷指令只能「存储图像 / 存储视频」 | Mac 上用 Photos.framework 合成 |
| 3 | 原图格式不固定 | 可能是 jpeg / webp / heic | worker 统一转 baseline JPEG（ffmpeg，失败回退 macOS `sips`） |

`picUrlArray` 的内容与顺序**与上游完全一致**，旧版快捷指令零改动可用。

### 1.4 技术硬约束（实测结论）

1. Live Photo = 静止帧（JPEG/HEIC）+ 约 3 秒 H.264 MOV，靠同一个 UUID 关联：
   - MOV：QuickTime `Keys` → `com.apple.quicktime.content.identifier`（exiftool 名 `Keys:ContentIdentifier`）
   - 静止帧：Apple MakerNote → `ContentIdentifier`（0x0011）
2. **iOS 侧无法合成**：没有原生 action，第三方 App 也要人工操作。
3. 实测（ffmpeg 6.x/7.x、exiftool 13.64）：
   - `exiftool -Keys:ContentIdentifier=<UUID> x.mov` ✅
   - `ffmpeg -movflags use_metadata_tags -metadata com.apple.quicktime.content.identifier=<UUID>` ✅
   - `exiftool -MakerApple:ContentIdentifier=<UUID> x.jpg` ❌ `MakerApple` 无法对没有 Apple MakerNote 的图片新建（先写 `-Make=Apple` 也不行）
   → 常见教程里"打标 + 两文件丢给 iPhone"的路线在本项目**走不通**。

## 2. 方案选型

| 方案 | 做法 | 自动化 | 可靠性 | 结论 |
|---|---|---|---|---|
| A 维持现状 | 返回图 + 视频，用户在 iPhone 用第三方 App 手动合成 | ❌ | 取决于 App | 不满足需求 |
| B 纯打标 | exiftool 写 ContentIdentifier，AirDrop 两文件 | 半自动 | ❌ 静止帧写入受限，iOS 不保证配对 | 放弃 |
| **C Mac 合成工作站** | Mac 上 ffmpeg 规范化 → Swift `PHAssetCreationRequest(.photo + .pairedVideo)` 写入照片图库 → iCloud 照片同步到 iPhone | ✅ | ✅ Apple 官方 API | **推荐** |

关键点：`PHAssetCreationRequest` 由 Photos 自己生成并写入 Asset Identifier（连静止帧的 MakerNote 也由系统补齐），**绕开了"无法新建 MakerNote"的限制**。

## 3. 推荐架构

```
┌────────────────┐   shareText        ┌──────────────────────────────┐
│ iPhone 快捷指令 │ ─────────────────> │ 主服务 web.js (Node 22)      │
│                │ <───────────────── │  /getXhsPicUrl → items[]     │
└───────┬────────┘  items(含配对信息)  └──────────────────────────────┘
        │
        │ POST /livephoto { imageUrl(原图), videoUrl(Live视频), album }
        ▼
┌───────────────────── Mac mini（macOS 宿主机，不能进容器）────────────────┐
│  livephoto/worker.js（Express + 队列，默认并发 1）                      │
│    1) 下载原图 + Live 视频（带 UA/Referer，CDN 直连）                   │
│    2) ffmpeg 转静态帧 → baseline JPEG（webp/heic 兜底：macOS sips）     │
│    3) ffmpeg 规范化视频 → H.264 High + yuv420p + 3.000s + ContentId     │
│    4) bin/lpimport（Swift + Photos.framework）                          │
│         .photo + .pairedVideo → 相簿「小红书」                          │
│    5) 清理临时文件，返回 localIdentifier                                │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │ iCloud 照片
                                   ▼
                          iPhone「照片」中的 Live Photo
```

要点：

- worker **必须在 macOS 宿主机**（`Photos.framework` + TCC 只对宿主机进程生效）。
- 主服务与 worker 可同机可异机；Docker 里用 `host.docker.internal:7777` 访问 worker。
- 上游的 SSRF 白名单不包含 `xhscdn.com`，所以**下载只能由 worker 完成**，主服务只负责解析出 URL。
- 导入走异步队列，快捷指令提交即返回。

## 4. 接口

### 4.1 主服务（向后兼容）

`GET|POST /getXhsPicUrl?shareText=...`

```json
{
  "picUrlArray": [
    "https://ci.xiaohongshu.com/1040g2t0aaa",
    "https://ci.xiaohongshu.com/1040g2t0bbb",
    "https://sns-video-hw.xhscdn.com/live-1.mov",
    "https://sns-video-hw.xhscdn.com/note-video.mp4"
  ],
  "items": [
    {
      "index": 0,
      "type": "image",
      "imageUrl": "https://ci.xiaohongshu.com/1040g2t0aaa",
      "originalUrl": "https://ci.xiaohongshu.com/1040g2t0aaa",
      "livePhotoVideoUrl": "https://sns-video-hw.xhscdn.com/live-1.mov",
      "isLivePhoto": true
    },
    {
      "index": 1,
      "type": "image",
      "imageUrl": "https://ci.xiaohongshu.com/1040g2t0bbb",
      "originalUrl": "https://ci.xiaohongshu.com/1040g2t0bbb",
      "livePhotoVideoUrl": null,
      "isLivePhoto": false
    }
  ]
}
```

> `imageUrl` 就是**原图**（上游已去掉 `imageView2` 参数），格式可能是 jpeg/webp/heic，worker 会统一转 JPEG。

**自动合成**：只要配置了 `LIVEPHOTO_WORKER_URL`，解析到 Live Photo 就会**自动**投递给 worker，**不需要任何额外参数**。
需要单次关闭用 `?import=0`，全局关闭用 `LIVEPHOTO_AUTO_IMPORT=0`。

```json
{ "picUrlArray": [], "items": [],
  "livePhotoJobs": [{ "ok": true, "jobId": "uuid", "imageUrl": "..." }],
  "livePhotoForward": { "at": "…", "target": "http://192.168.0.88:7777/livephoto",
                        "attempted": 1, "ok": 1, "failed": 0, "lastError": null } }
```

`import` 参数可省略（默认自动）；`?import=0` / body `{"import": false}` 表示本次不转发。

**排查转发没生效**：`GET /status` 会直接告诉你配置与最近一次结果

```bash
curl -s http://<主服务>:7776/status | python3 -m json.tool
```

```json
{
  "livePhoto": { "workerUrl": "http://192.168.0.88:7777",
                 "workerEndpoint": "http://192.168.0.88:7777/livephoto",
                 "forwardingEnabled": true, "album": "小红书", "timeoutMs": 10000 },
  "lastForward": { "attempted": 1, "ok": 0, "failed": 1,
                   "lastError": "connect ECONNREFUSED 192.168.0.88:7777" },
  "hint": "解析到 Live Photo 会自动转发；可用 ?import=0 单次关闭"
}
```

- `forwardingEnabled: false` → 容器没配 `LIVEPHOTO_WORKER_URL`，或改了环境变量但没重建容器；
- `lastForward` 为 `null` → 还没有解析到过 Live Photo（自动转发没被触发过）；
- `lastForward.lastError` 有值 → 网络/权限问题，错误原文会写在里面。

关于这几个环境变量的默认行为：

| 变量 | 不配置时 | 结论 |
|---|---|---|
| `LIVEPHOTO_ALBUM` | 默认就是 `小红书`（worker 侧 `ALBUM` 也是同一默认值） | **不配等于配成这个名字**，只有想换相簿名时才需要设 |
| `LIVEPHOTO_WORKER_URL` | 为空 → 不自动合成 | 服务功能完全正常（图片/视频/items 都在），只是不会转发给 Mac；配置后**自动生效** |
| `LIVEPHOTO_AUTO_IMPORT` | 默认开启 | 置 `0` 时变成"只有显式 `?import=1` 才转发" |

> 相簿默认名已从 `小红书Live` 改为 `小红书`。之前用旧名字导入的照片不会被删除或迁移，
> 新导入的 Live Photo 会落到「小红书」相簿；若想继续沿用旧相簿，把 worker 的 `ALBUM` 和
> 容器的 `LIVEPHOTO_ALBUM` 都显式设成 `小红书Live`。

没配 `LIVEPHOTO_WORKER_URL` 但解析到 Live Photo 时**不会报错**，只是明确告诉你没合成：

```json
{ "picUrlArray": [...], "items": [...],
  "livePhotoWarning": "检测到 Live Photo，但未配置 LIVEPHOTO_WORKER_URL，未自动合成（不影响图片/视频下载）" }
```

服务端日志同时打印：`[livephoto] 检测到 Live Photo，但未配置 LIVEPHOTO_WORKER_URL，未自动合成`。
配了但连不上时，`livePhotoJobs` 里每项会是 `{ "ok": false, "error": "connect ECONNREFUSED ..." }`。
如果你走的是「快捷指令直连 worker」（方案 A），这个变量本来就不需要配。

### 4.2 worker

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 依赖/队列状态（`importerExists` 必须为 true） |
| POST | `/livephoto` | `{ imageUrl, videoUrl, album?, takenAt?, wait? }`：合成 Live Photo |
| POST | `/import-photo` | `{ imageUrl, album?, takenAt?, wait? }`：单张图片直接写入照片图库 |
| POST | `/import-video` | `{ videoUrl, album?, takenAt?, wait? }`：单个视频直接写入照片图库 |
| POST | `/livephoto/from-link` | `{ shareText, album? }`：直接给分享文本，worker 复用 `main.js` 解析后合成该笔记的所有 Live Photo（需在仓库根目录 `npm install`） |
| POST | `/livephoto/batch` | `{ items: [{imageUrl, videoUrl}], album? }` |
| GET | `/jobs` / `/jobs/:id` | `queued/running/done/failed` + `kind` + `step` |
| GET | `/` | 调试页面，粘贴两个地址手动试合成 |

`wait: true` 时同步等待（默认最多 180s）并返回 `result.localIdentifier`。

### 4.3 worker 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HOST` | 0.0.0.0 | 监听地址；跨机器/容器访问必须保持 `0.0.0.0` |
| `PORT` | 7777 | 监听端口（默认仅本机，跨机请加反代/白名单） |
| `ALBUM` | 小红书 | 相簿名（不存在会自动创建） |
| `FFMPEG` | ffmpeg | Apple Silicon 通常是 `/opt/homebrew/bin/ffmpeg` |
| `IMPORTER` | `./bin/lpimport` | Swift 导入器 |
| `TRIM_SECONDS` | 3 | 视频裁剪时长（Apple 约定 3s） |
| `STILL_MAX_EDGE` | 0 | >0 时按最长边缩放静止帧（让尺寸贴近 1080p 级视频，如 1440） |
| `MATCH_STILL_TO_VIDEO` | 0 | 置 1 时把静止帧按视频宽高居中裁剪（`PHPhotosError 3302` 的常见对策） |
| `PAIR_IDENTIFIER` | 1 | 生成 UUID 并写入视频 `content.identifier` + 静止帧 Apple MakerNote tag 17（PhotoKit 配对要求两端一致）；置 0 退回旧行为 |
| `VIDEO_CODEC` | libx264 | 视频编码器；真机 Live Photo 为 HEVC(hvc1)，可试 `libx265` / `hevc_videotoolbox` 做 A/B |
| `COMPOSE_MOVIE` | 1 | 置 0 时跳过 `AVAssetWriter` 重写视频（默认会补出 `still-image-time` 定时元数据轨） |
| `EMBED_COVER` | auto | 视频封面处理：`auto`（≤20MB 的小视频画到第一帧，大视频跳过重编码保原画质）/ `first-frame` / `attached-pic`（mp4/mov 常被丢弃）/ `skip` |
| `TAG_CONTENT_ID` | 0 | 仅在 `PAIR_IDENTIFIER=0` 时生效：单独给视频写标识（导出散文件用） |
| `SIPS_FALLBACK` | 1 | ffmpeg 转码失败时用 macOS `sips` 兜底（HEIC 场景） |
| `CONCURRENCY` | 1 | 同时合成任务数 |
| `KEEP_FAILED` | 0 | 置 1 保留失败任务临时目录便于排查 |
| `WORK_DIR` | `$TMPDIR/xhs-livephoto` | 临时目录 |

### 4.4 全远程模式：`/getXhsPicRemote`

**手机只发一次请求，图片 / Live Photo / 视频全部由 Mac 下载并写入照片图库**，iPhone 端不保存任何媒体。

```
GET|POST /getXhsPicRemote?shareText=<分享文本>[&album=小红书]
```

处理规则（按 `items` 逐条分发到 worker）：

| item | worker 接口 | 结果 |
|---|---|---|
| `type=image` 且 `isLivePhoto=true` | `POST /livephoto` | 相册里出现 Live Photo |
| `type=image` | `POST /import-photo` | 相册里出现照片 |
| `type=video` | `POST /import-video` | 相册里出现视频 |

返回：

```json
{
  "ok": true,
  "itemCount": 3,
  "items": [ ... ],
  "remoteJobs": [
    { "type": "livephoto", "ok": true, "jobId": "…" },
    { "type": "photo",     "ok": true, "jobId": "…" },
    { "type": "video",     "ok": true, "jobId": "…" }
  ],
  "remoteForward": { "attempted": 3, "ok": 3, "failed": 0, "lastError": null }
}
```

未配置 `LIVEPHOTO_WORKER_URL` 时直接返回 `{ "error": "未配置 LIVEPHOTO_WORKER_URL，无法远程处理媒体" }`。
每条任务的进度可查 `GET <worker>/jobs`。

## 5. Mac mini 部署

```bash
# 0) 依赖（worker 用 Node 与主服务的 Node 22 保持一致）
brew install node ffmpeg

# 1) 编译 Swift 导入器（Info.plist 会嵌进二进制，否则 TCC 拿不到用途说明）
#    版本号取自 livephoto/package.json，脚本会自动注入并做冒烟测试
cd livephoto && ./build.sh          # 产物 livephoto/bin/lpimport

# 2) 第一次必须在 Terminal 前台跑一次，完成照片权限授权
cd livephoto && npm install
node worker.js
# 另开窗口验证一张：
curl -s -X POST http://127.0.0.1:7777/livephoto \
  -H 'content-type: application/json' \
  -d '{"imageUrl":"https://.../a.jpg","videoUrl":"https://.../a.mov","wait":true}'
# 首次会弹「lpimport 想访问您的照片」，允许即可

# 3) 常驻（二选一）
#    a. 推荐：tmux/screen 里启动（继承 Terminal 的 TCC 授权，最稳）
tmux new -d -s xhs-livephoto 'cd ~/xhs_pic_download/livephoto && node worker.js'
#    b. launchd（见 com.nfew.xhs-livephoto.plist，需改路径；权限报错就改回 a）
```

验收：

```bash
curl -s http://127.0.0.1:7777/health | jq
curl -s http://<主服务>:7776/healthz     # 上游新增的健康检查，返回 ok
# 合成成功后 Mac「照片」出现新 Live Photo，几秒后 iPhone 同步到位
```

### 5.1 容器如何访问 Mac 上的 worker

worker 默认监听 `0.0.0.0:7777`（可用 `HOST` / `PORT` 改），启动时直接打印可用地址，照抄即可：

```
[xhs-livephoto] listening on 0.0.0.0:7777
[xhs-livephoto] importer: /Users/paccu/Tools/xhs_pic_download/livephoto/bin/lpimport (exists=true)
[xhs-livephoto] 其他设备/容器可用的地址:
    http://192.168.1.23:7777
[xhs-livephoto] 容器里请这样配置（示例）:
    -e LIVEPHOTO_WORKER_URL=http://192.168.1.23:7777
```

主服务用环境变量 `LIVEPHOTO_WORKER_URL` 找 worker，按容器所在位置选：

| 容器位置 | `LIVEPHOTO_WORKER_URL` | 说明 |
|---|---|---|
| 与 worker 同一台 Mac（Docker Desktop） | `http://host.docker.internal:7777` | Docker Desktop 自带该域名，零配置 |
| 局域网内的 NAS / 服务器 | `http://<Mac 局域网 IP>:7777` | 给 Mac 做 DHCP 保留；Linux 上也可 `--add-host=host.docker.internal:host-gateway` 复用同名 |
| 公网服务器 / 不同网络 | Tailscale 的 `100.x.y.z:7777` 或隧道地址 | `tailscale ip -4`；或 Cloudflare Tunnel / frp |

```bash
docker run -d -p 7776:7776 --name xhs_pic_download \
  -e LIVEPHOTO_WORKER_URL=http://192.168.1.23:7777 \
  nfew/xhs_pic_download:latest
```

```yaml
# docker compose / Unraid 模板里的 env 项
environment:
  - LIVEPHOTO_WORKER_URL=http://192.168.1.23:7777
```

> 变量在进程启动时读取，**改完必须重建容器**（`docker rm -f` + 重新 run）。

验证容器到 worker 的连通性（镜像里没装 curl，用 Node 22 自带的 fetch）：

```bash
docker exec xhs_pic_download node -e "fetch(process.env.LIVEPHOTO_WORKER_URL + '/health').then(r=>r.json()).then(j=>console.log('OK', j.urls, 'importerExists=' + j.importerExists)).catch(e=>console.error('FAIL', e.message))"
```

常见失败原因：

| 现象 | 处理 |
|---|---|
| 启动日志只有 `127.0.0.1`，或 `HOST` 被设成 `127.0.0.1` | 改回 `HOST=0.0.0.0`（默认值，不用设） |
| 容器 `ECONNREFUSED` / timeout | macOS 防火墙：系统设置 → 网络 → 防火墙，允许 `node` 接受传入连接；或 `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$(which node)"` 后 `--unblockapp "$(which node)"` |
| 隔一段时间就连不上 | Mac 休眠 / DHCP 换了 IP：关闭自动休眠 + 路由器上做 IP 绑定 |
| 同一台 Mac 却连不上 `host.docker.internal` | 极老版本 Docker Desktop；升级，或直接用局域网 IP |

## 6. iOS 快捷指令改造

**因为转发已经自动化**（只要容器配了 `LIVEPHOTO_WORKER_URL`），快捷指令里**不需要**任何 Live Photo 相关动作：

1. `获取 URL 内容` → `https://<主服务>/getXhsPicUrl?shareText=<剪贴板>`
2. `重复` 遍历 `items`：
   - `type = image` 且 `isLivePhoto = false` → `存储图像`（用 `imageUrl`）
   - `type = video` → `存储视频`（用 `videoUrl`）
   - `isLivePhoto = true` → **跳过**（容器的 `/getXhsPicUrl` 已经把它投递给 Mac，合成后经 iCloud 同步到手机）

> 如果先不接容器，也可以让快捷指令直连 Mac（方案 A）：`isLivePhoto` 为真时
> `获取 URL 内容`（`POST` `http://<mac-mini>:7777/livephoto`，body：`imageUrl` + `videoUrl`）。
>
> 旧的快捷指令仍能工作（`picUrlArray` 未变），但会把 Live 视频当普通视频存一份，建议升级。


## 7. 风险与规避

| 风险 | 说明 | 规避 |
|---|---|---|
| 照片权限（TCC） | launchd 进程是独立 TCC 主体，可能反复被拒或无法弹窗 | 优先 Terminal/tmux 常驻；`build.sh` 已 ad-hoc codesign 固定身份 |
| 前提：iCloud 照片 | 同步到 iPhone 依赖 Mac 的系统照片图库 + iCloud 照片 | 系统设置 → Apple ID → iCloud → 照片；手机同 Apple ID |
| 原图格式 | 上游返回裸原图，可能是 webp/heic | worker 用 ffmpeg 转 JPEG，失败回退 macOS `sips`（`SIPS_FALLBACK=0` 可关闭） |
| 尺寸不一致 | 原图可能是 3024x4032，而 Live 视频是 1080x1920 | `STILL_MAX_EDGE=1440` 之类按最长边缩放；小红书同源的图/视频一般比例一致 |
| 视频时长/编码 | 非 3 秒、非 H.264/yuv420p 会被 Photos 拒绝 | worker 统一 `-t 3` + libx264 + yuv420p 重编码 |
| 竖屏方向 | 源视频常带 rotate 元数据 | ffmpeg 重编码自动应用旋转矩阵 |
| CDN 防盗链 | 直连可能 403 | worker 下载带 `Referer: https://www.xiaohongshu.com/` + 浏览器 UA |
| 上游 SSRF 白名单 | `sns-*.xhscdn.com` 不在 `ALLOWED_HOSTS` 内，主服务不能代下视频 | 保持"主服务只解析、worker 只下载"的分工，别把下载逻辑塞回主服务 |
| Mac 休眠 | 休眠时任务失败 | 电源设置关闭自动休眠；失败重发即可 |
| 端口暴露 | worker 无鉴权 | 仅内网/回环，或前置 nginx + basic auth |

## 8. 已验证项（本仓库可复现）

- `npm test`：**6/6 通过** —— `findNote`（移动版/桌面版/空）、`extractPicId`（含兜底）、`buildItems` 配对与 `picUrlArray` 顺序、视频笔记 + streamType 回退、空数据。
- 全链路解析（stub `axios.get`，绕过 SSRF 白名单限制）：
  - 移动版页面 `noteData.data.noteData` → `items=3 live=1`，`picUrlArray` 与上游顺序一致 ✅
  - 桌面版页面 `note.noteDetailMap` → 同上 ✅
  - 登录墙（无 note）→ 明确报 `不包含图片` ✅
- worker 端到端（Linux + 假 importer + 本地静态服务）：
  - 6 秒源视频 → **3.00s / h264 High / yuv420p / MOV**，`com.apple.quicktime.content.identifier` 写入成功 ✅
  - **webp 3024x4032 → JPEG 3024x4032**；`STILL_MAX_EDGE=1440` → **1440x1920** ✅
  - `album` 透传、404/非法 URL 明确报错、批量接口 2/2 done ✅
- `livephoto/build.sh`：`--help`、版本号解析（`1.0.1` / semver 校验）、非 macOS 预检、
  worker 版本上报（启动横幅 + `/health.importerVersion`）已在本环境验证；
  `swiftc` 编译与 `__info_plist` 注入需在 macOS 上执行。
- `build-image.sh`：只做「读 `.env` 的 `APP_VERSION` → 构建 `<IMAGE>:<版本>` + `:latest` → 推送」；
  OCI 标签（version / revision / created / source）正确，push 已在本地 `registry:2` 上验证成功。
- 仅 `lpimport` 的 Photos 写入需在 macOS 上验证（本环境无 Photos.framework）。

## 9. 已解决：PHPhotosError 3302（生成件不被接受）

排查记录（按时间顺序，结论明确）：

| 尝试 | 结果 |
|---|---|
| 视频写 `content.identifier`、静止帧没有 | ❌ 3302 |
| 两端都不写 | ❌ 3302 |
| 两端写同一个 UUID（ImageIO 写静止帧的 MakerApple tag 17） | ❌ 3302 |
| 静止帧与视频比例对齐（都是 3:4）/ 时长 2.9~3.0s / 换 HEVC | ❌ 3302 |
| 导入 iPhone 原装的一对（HEIC + MOV，未做任何处理） | ✅ 成功 |
| **我们的静止帧 + 真机 MOV** | ✅ **成功** ⇒ 静止帧侧合格，问题在 MOV |
| **我们的静止帧 + 我们重写（补 still-image-time 轨）的 MOV** | ✅ **成功（最终方案）** |

根因（两条同时成立才行）：

1. 静止帧的 Apple MakerNote tag 17 必须与视频的 `content.identifier` **一致**；
2. 视频里必须有 **`mdta/com.apple.quicktime.still-image-time` 定时元数据轨**（ffmpeg 写不出，必须用 `AVAssetWriter`）。

附带发现：这台 macOS 27.2 上，`AVAssetReader` 用 **passthrough**（`outputSettings: nil`）读 ffmpeg 产出的 MOV 会直接返回 nil（`status=reading`、无 error）。所以重写视频时必须走「解码为 32BGRA → 显式 H.264 重编码」，顺带保留 `preferredTransform` 竖屏方向。

最终管线：

```
原图(HEIC/JPEG) ──ImageIO──> JPEG + MakerApple[17]=UUID
原视频(mp4) ──ffmpeg(纯转码/裁 3s)──> MOV ──AVAssetWriter(解码+重编码)──>
    MOV：H.264 + content.identifier + still-image-time 轨
两者 ──PHAssetCreationRequest(.photo + .pairedVideo)──> 真正的 Live Photo
```

## 10. 视频质量 / 水印 / 封面

- **画质与去水印**：优先用 `note.video.consumer.originVideoKey` 拼出
  `https://sns-video-bd.xhscdn.com/<key>`（原始上传，通常无水印、画质最高）；
  同时把网页流里码率最高的一条放进 `videoFallbackUrl`，**原片下载失败会自动回退**
  （worker 会打印 `视频下载失败：… → 404` 然后改用兜底流）。
  没有 `originVideoKey` 时，只按所有变体里 `videoBitrate`（其次 `avgBitrate`/`size`、
  再比分辨率）最高的一条来取，不再盲取 `streamTypes[0]`。
- 实测案例：某视频笔记网页端只有
  `MINI_APP_259`（720×1280，1.84Mbps，小程序版）与 `MP4_WEB_537_h5`（720×1280，1.33Mbps），
  而 `mediaV2.video` 显示原片是 **2160×3840**；此时只有 `originVideoKey` 能拿到高清无水印版本。
- **xsec_token**：分享链接里的 token 已保留（`main.js` 不会丢），不需要额外传参。
  若个别笔记仍只能拿到低清流，可在请求里带登录态 `xhsCookie`
  （`/getXhsPicUrl` 与 `/getXhsPicRemote` 都支持）。
- **封面**：视频笔记的 `imageList[0]` 就是封面，解析时标记为 `isVideoCover`：
  - `/getXhsPicRemote` **不再把封面单独存成一张照片**（原来会出现"视频 + 封面"两个资产）；
  - worker 的 `/import-video` 接收 `coverUrl`，按 `EMBED_COVER` 处理：
    - `auto`（默认）：≤20MB 的小视频把封面画到**视频第一帧**（Photos 缩略图取自第一帧，
      相册里看起来就是"封面是视频封面"）；更大的视频（如 4K 原片）**跳过重编码**，
      只保证"封面不单独入库"，避免为了封面把 50Mbps 原片压掉；
    - `first-frame`：强制画到第一帧（重编码 CRF 18，音频 copy，时长不变）；
    - `attached-pic`：写附图轨（mp4/mov 常被丢弃）；
    - `skip`：完全不动视频。
- **不会产出"幻灯片视频"**：XHS 会为实况笔记自动合成一条视频
  （`originVideoKey` 形如 `slides_simulate_post/…`，带 BGM）。规则是
  **只要笔记里存在 Live Photo，就不产出 `note.video`**；`originVideoKey` 命中
  `slides_simulate_post/` 的也一律跳过。封面标记只在"确实会产出视频"时生效，
  避免封面被跳过导致丢图。

> 注意：`first-frame` 会重编码视频轨（CRF 18，肉眼接近无损），音频直接 copy，时长不变。

## 11. 关于音频

- **不额外下载任何背景音乐**（原先的 `bgmUrl` 混音功能已移除）；
- **源视频自带的音轨会保留**：worker 用 ffmpeg `-map 0:a:0?` 保留音频并转成 AAC，
  `lpimport` 再用 AVAssetReader 解码成 LPCM → AAC 写进重写后的 MOV；
- 小红书网页端下发的实况视频是静音版（`WEB_LIVEPHOTO_19`，`audioCodec=""`、
  `audioBitrate=0`、`volume=0`），这种情况合成结果天然无声，属平台限制；
- 视频笔记（`type=video`）经 `/getXhsPicRemote` 是**原样导入**，音轨完全不受影响。

## 11. 后续可选增强

- 把笔记发布时间作为 `takenAt` 传入，导入时设置 `creationDate`，相册时间线更真实（worker 已支持）。
- 失败重试队列 + Bark / Server 酱推送。
- 静止帧按视频宽高比裁剪/留边（当前只做等比缩放），避免极端比例下"长按"画面被裁切。
- 不依赖 iCloud 的退路：worker 导出「JPEG + MOV」下载链接，iPhone 上用第三方 App 合成（退回半自动）。

