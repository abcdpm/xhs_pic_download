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

可选：设置 `LIVEPHOTO_WORKER_URL` 后，请求带 `?import=1`（或 body `{"import": true}`）时服务端自动把 `isLivePhoto` 的条目投递给 worker：

```json
{ "picUrlArray": [], "items": [],
  "livePhotoJobs": [{ "ok": true, "jobId": "uuid", "imageUrl": "..." }] }
```

关于这两个环境变量的默认行为：

| 变量 | 不配置时 | 结论 |
|---|---|---|
| `LIVEPHOTO_ALBUM` | 默认就是 `小红书`（worker 侧 `ALBUM` 也是同一默认值） | **不配等于配成这个名字**，只有想换相簿名时才需要设 |
| `LIVEPHOTO_WORKER_URL` | 为空，`?import=1` 不生效 | 服务功能完全正常（图片/视频/items 都在），只是不会转发给 Mac |

> 相簿默认名已从 `小红书Live` 改为 `小红书`。之前用旧名字导入的照片不会被删除或迁移，
> 新导入的 Live Photo 会落到「小红书」相簿；若想继续沿用旧相簿，把 worker 的 `ALBUM` 和
> 容器的 `LIVEPHOTO_ALBUM` 都显式设成 `小红书Live`。

不配 `LIVEPHOTO_WORKER_URL` 但请求带了 `import=1` 时**不会报错**，而是明确告诉你没转发：

```json
{ "picUrlArray": [...], "items": [...],
  "livePhotoJobs": [],
  "livePhotoWarning": "未配置 LIVEPHOTO_WORKER_URL，Live Photo 未转发（不影响图片/视频下载）" }
```

服务端日志同时打印：`[livephoto] 请求带 import=1，但未配置 LIVEPHOTO_WORKER_URL，已跳过转发`。
配了但连不上时，`livePhotoJobs` 里每项会是 `{ "ok": false, "error": "connect ECONNREFUSED ..." }`。
如果你走的是「快捷指令直连 worker」（方案 A），这个变量本来就不需要配。

### 4.2 worker

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 依赖/队列状态（`importerExists` 必须为 true） |
| POST | `/livephoto` | `{ imageUrl, videoUrl, album?, takenAt?, wait? }` |
| POST | `/livephoto/from-link` | `{ shareText, album? }`：直接给分享文本，worker 复用 `main.js` 解析后合成该笔记的所有 Live Photo（需在仓库根目录 `npm install`） |
| POST | `/livephoto/batch` | `{ items: [{imageUrl, videoUrl}], album? }` |
| GET | `/jobs` / `/jobs/:id` | `queued/running/done/failed` + `step` |
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
| `TAG_CONTENT_ID` | 0 | 仅在 `PAIR_IDENTIFIER=0` 时生效：单独给视频写标识（导出散文件用） |
| `SIPS_FALLBACK` | 1 | ffmpeg 转码失败时用 macOS `sips` 兜底（HEIC 场景） |
| `CONCURRENCY` | 1 | 同时合成任务数 |
| `KEEP_FAILED` | 0 | 置 1 保留失败任务临时目录便于排查 |
| `WORK_DIR` | `$TMPDIR/xhs-livephoto` | 临时目录 |

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

1. `获取 URL 内容` → `.../getXhsPicUrl?shareText=<剪贴板>`，得到 JSON。
2. `重复` 遍历 `items`：
   - `isLivePhoto` 为真 → `获取 URL 内容`（`POST`，JSON：`imageUrl = imageUrl`、`videoUrl = livePhotoVideoUrl`）请求 `http://<mac-mini>:7777/livephoto`；
   - `type = image` → `存储图像`（用 `imageUrl`）；
   - `type = video` → `存储视频`（用 `videoUrl`）。
3. Mac 有固定地址时可省略循环，直接用 `?import=1`。

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

> 关于"没有声音"：小红书很多实况视频本身就是静音的。worker 现在会在日志里标明
> `video=… h264 +aac` 或 `video=… h264 无音轨`，可据此区分"源无声"与"处理丢音"。

## 10. 关于「没有声音」

实测（笔记 `6aeb2c4b…`）：`imageList[0].stream` 里只有一条流

```
streamDesc=WEB_LIVEPHOTO_19  audioCodec=""  audioBitrate=0  audioDuration=0  volume=0
```

同时 `livePhoto` 只是布尔 `true`、`note` 里没有 `music` 字段。也就是说：
**XHS 下发给网页端的实况视频就是静音版**，App 里听到的声音走客户端专属通路，
匿名网页抓取拿不到。

代码侧的处理：

- `main.js` 新增 `pickLivePhotoStream()`：**优先挑选 `audioBitrate > 0` 的流变体**
  （若某条笔记/登录态返回带音变体，自动使用带音的；否则退回第一条可用流）；
- `items[]` 如实给出 `livePhotoHasAudio` / `livePhotoAudioBitrate`；
- worker 日志标 `video=… +aac` 或 `无音轨`；`/livephoto/from-link` 遇到静音流会直接提示；
- 源视频**确实带音轨**时（视频笔记、或带音变体），`lpimport` 会「解码 LPCM → 重编码 AAC」，声音会保留。

> 想尝试拿到带音版本：可在请求里传登录态 `xhsCookie`（`main.js` 已支持该参数）。
> 若登录后接口返回 `audioBitrate > 0` 的变体，上述选择逻辑会自动采用。

### 10.1 有没有公开接口能拿到音频？调查结论

- 小红书**没有公开/官方的音频接口**。社区逆向项目（`NanmiCoder/MediaCrawler`、`ReaJason/xhs`、`Spider_XHS`
  等）用的都是同一批私有接口：`https://edith.xiaohongshu.com/api/sns/web/v1/feed`，必须带
  `x-s` / `x-t` / `x-s-common` 签名（由 cookie 里的 `a1` + `md5(时间戳+"test"+uri+body)`
  再经自定义 base64 变换得出）。
- 这些接口返回的内容与我们已经能从 SSR 页面拿到的 `noteData` **是同一份数据**，
  所以「社区 API 能不能拿到音频」≈「登录态下这份数据里有没有音频字段」。
- 已知事实：
  - 实况视频只有一条 `WEB_LIVEPHOTO_19`，`audioCodec=""`、`audioBitrate=0`、`audioDuration=0`、`volume=0`；
  - `note` 里没有 `music` / `audio` / `bgm` 字段，`livePhoto` 只是布尔 `true`；
  - 视频笔记（`type=video`）的 `note.video` 一般自带音轨，不受此影响。

### 10.2 自己验证只需浏览器（不用写代码）

1. Chrome 登录小红书，打开笔记页；
2. F12 → Network → 过滤 `feed`；
3. 刷新页面，点开 `feed`（或 `note/feed`）请求 → Response；
4. 搜索 `music`、`audioBitrate`、`originVideoKey`。

- 若出现 `music` 且带 `musicUrl` → 说明登录态才有，可用 `xhsCookie` + 签名接口取；
- 若仍是 `audioBitrate: 0` 且无 `music` → 网页端确实没有音频，属平台限制。

**如果确实要拿到 App 里的那份音频**，需要抓移动端流量，完整方案（iOS/Android/纯手机三种，
含证书安装、QUIC 回落、pinning 绕过、以及现成的 mitmproxy 插件）见
[`docs/capture-audio.md`](capture-audio.md)。抓到音频直链后直接填到下面的 `bgmUrl` 即可。

### 10.3 已内置「混音」能力（拿到 BGM 地址就能用）

`POST /livephoto` 与 `/livephoto/from-link` 都支持可选 `bgmUrl`：

```bash
curl -s -X POST http://127.0.0.1:7777/livephoto -H 'content-type: application/json' \
  -d '{"imageUrl":"...","videoUrl":"...","bgmUrl":"http://.../bgm.m4a","wait":true}'
```

worker 会下载 BGM，用 ffmpeg 作为第二路音频混进实况视频
（`-i video -i bgm -map 0:v:0 -map 1:a:0 -t 3 -c:a aac`），随后 AVAssetWriter 再把音频
解码重编码成 AAC 保留下来 —— **只要能给出音频地址，合成结果就带声音**。

## 11. 后续可选增强

- 把笔记发布时间作为 `takenAt` 传入，导入时设置 `creationDate`，相册时间线更真实（worker 已支持）。
- 失败重试队列 + Bark / Server 酱推送。
- 静止帧按视频宽高比裁剪/留边（当前只做等比缩放），避免极端比例下"长按"画面被裁切。
- 不依赖 iCloud 的退路：worker 导出「JPEG + MOV」下载链接，iPhone 上用第三方 App 合成（退回半自动）。

