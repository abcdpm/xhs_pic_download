# xhs-livephoto worker

把 `main.js` 解析出的「静止帧 + Live Photo 视频」合成为**真正的 Live Photo**，直接写入 Mac 照片图库，随后由 iCloud 照片同步到 iPhone。

> 完整方案（原理、接口、风险）见 [`../docs/livephoto.md`](../docs/livephoto.md)。

## 为什么需要这台 Mac

iOS 快捷指令只能「存储图像 / 存储视频」，**没有任何原生方式把两个文件合成为 Live Photo**；而且小红书 CDN 的图片没有 Apple MakerNote，exiftool 也无法补写 `ContentIdentifier`。唯一可靠路径是 macOS 上调用官方 Photos API：

```swift
PHAssetCreationRequest.forAsset()
  .addResource(with: .photo, ...)        // 静止帧
  .addResource(with: .pairedVideo, ...)  // Live Photo 视频
```

另外两点必须在这里处理：

- 主服务现在返回的是**原图**（`https://ci.xiaohongshu.com/<id>`，可能是 jpeg/webp/heic），静止帧必须转成 JPEG 才能配对；
- 主服务的 SSRF 白名单不包含 `xhscdn.com`，**视频只能由 worker 自己下载**。

## 目录

| 文件 | 作用 |
|---|---|
| `worker.js` | Express 服务：下载 → ffmpeg 规范化 → 调用导入器，带任务队列 |
| `LivePhotoImporter.swift` | 调用 Photos.framework 合成并写入图库的 CLI |
| `Info.plist` | 嵌入二进制的用途说明（TCC 必需） |
| `build.sh` | 编译 + ad-hoc 签名 `bin/lpimport` |
| `com.nfew.xhs-livephoto.plist` | launchd 自启模板（路径需自行修改） |

## 快速开始

```bash
brew install node ffmpeg
npm install
./build.sh                       # 需要 Xcode Command Line Tools

# 首次务必在 Terminal 前台运行，完成照片权限授权
node worker.js

# 另一个窗口
curl -s http://127.0.0.1:7777/health
curl -s -X POST http://127.0.0.1:7777/livephoto \
  -H 'content-type: application/json' \
  -d '{"imageUrl":"https://example.com/a.jpg","videoUrl":"https://example.com/a.mov","wait":true}'
```

成功返回：

```json
{ "jobId": "…", "status": "done", "step": "done",
  "result": { "localIdentifier": "…/L0/001", "album": "小红书Live" } }
```

打开「照片」应能看到新 Live Photo（左下角圆环标识），几秒后 iPhone 同步出现。

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `ALBUM` | 小红书Live | 目标相簿（不存在会自动创建） |
| `TRIM_SECONDS` | 3 | Live 视频裁剪时长 |
| `STILL_MAX_EDGE` | 0 | >0 时按最长边缩放静止帧（如 `1440`，让尺寸贴近 1080p 级视频） |
| `SIPS_FALLBACK` | 1 | ffmpeg 转换失败时用 macOS `sips` 兜底（HEIC 常见） |
| `CONCURRENCY` | 1 | 同时合成数 |
| `KEEP_FAILED` | 0 | 置 1 保留失败任务产物 |
| `FFMPEG` / `IMPORTER` / `PORT` / `WORK_DIR` | 见 `worker.js` | 路径与端口 |

## 常驻运行

推荐 tmux（继承 Terminal 的照片权限，最稳）：

```bash
tmux new -d -s xhs-livephoto 'cd ~/xhs_pic_download/livephoto && node worker.js'
tmux attach -t xhs-livephoto   # 查看日志
```

或使用 launchd（改好 plist 内路径与 ffmpeg 位置后）：

```bash
cp com.nfew.xhs-livephoto.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nfew.xhs-livephoto.plist
tail -f /tmp/xhs-livephoto.err.log
```

若 launchd 方式报「照片图库权限未授予」，说明该进程没有拿到 TCC 授权，改回 tmux 方式，或在 Terminal 中执行一次 `node worker.js` 完成授权后再试。

## 排查

| 现象 | 处理 |
|---|---|
| `/health` 里 `importerExists: false` | 未编译，先跑 `./build.sh` |
| `照片图库权限未授予 (status=…)` | 系统设置 → 隐私与安全性 → 照片，勾选 `lpimport` / Terminal |
| `Photos 拒绝了该 Live Photo` | 视频超 3 秒或编码异常；调小 `TRIM_SECONDS`，或用 `KEEP_FAILED=1` 保留产物用 ffprobe 检查 |
| 下载 0 字节 / 403 | CDN 防盗链，确认带了 UA/Referer（worker 已内置） |
| Mac 上有了但 iPhone 没有 | Mac「照片」需开启 iCloud 照片，且与 iPhone 同 Apple ID |
