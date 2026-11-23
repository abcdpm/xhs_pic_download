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

最省事的验证方式是浏览器打开 **http://127.0.0.1:7777/** ，把小红书「复制链接」拿到的分享文本粘进去 —— 它会调用 `/livephoto/from-link`，自动解析该笔记并把所有 Live Photo 一次性合成（需要先在仓库根目录 `npm install`，worker 会复用 `main.js` 的解析逻辑）：

```bash
curl -s -X POST http://127.0.0.1:7777/livephoto/from-link \
  -H 'content-type: application/json' \
  -d '{"shareText":"<小红书分享文本>"}'
# => {"ok":true,"livePhotoCount":2,"totalItems":3,"jobs":[{...}]}
```

`./build.sh` 会做这些事（任何一步失败都会明确报错退出）：

1. 预检：macOS、`xcrun`/`swiftc`、`plutil`、源文件与 `Info.plist`
2. 解析版本号（默认取 `package.json` 的 `version`）与构建号（默认取 git 提交数）
3. 复制并注入版本到 `bin/.build/Info.plist`，再以 `__info_plist` 段嵌入二进制
4. `swiftc` 编译 + ad-hoc 签名
5. 冒烟测试 `--version` / `--help`（这步能挡住"编译过了但跑不起来"）
6. 打印架构、大小、sha256，并写入 `bin/VERSION`

> 版本号只在 `livephoto/package.json` 里改（当前 `1.0.1`），脚本自动读取，不用改 build.sh。
> 需要临时构建别的版本：`./build.sh --version 1.0.2 --build 43`；清空重建：`./build.sh --clean`。

## 版本

| 位置 | 内容 |
|---|---|
| `package.json` → `version` | 唯一版本来源（worker 也会上报） |
| `./bin/lpimport --version` | `lpimport 1.0.1 (build <git 提交数>)` |
| `./bin/VERSION` | 与上面一致的文本 |
| `curl -s 127.0.0.1:7777/health \| jq .importerVersion` | `"lpimport 1.0.1 (build 42)"` |
| 启动日志 | `[xhs-livephoto] v1.0.1 listening on 0.0.0.0:7777` |

成功返回：

```json
{ "jobId": "…", "status": "done", "step": "done",
  "result": { "localIdentifier": "…/L0/001", "album": "小红书" } }
```

打开「照片」应能看到新 Live Photo（左下角圆环标识），几秒后 iPhone 同步出现。

## 让容器 / 局域网设备访问 7777（macOS 防火墙）

macOS 自带防火墙是**按应用放行，不按端口**，所谓「开放 7777」就是允许 `node` 接受传入连接。

**先看防火墙是否开着**（默认是关的，关着就什么都不用做）：

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
# Firewall is disabled. (State = 0)      →  不用处理
# Firewall is enabled. (State = 1)       →  继续下面
```

**方式 A：弹窗点允许（最省事）**

第一次有外部设备连 `7777` 时，macOS 会弹「是否允许 “node” 接受传入网络连接」，点**允许**即可。

**方式 B：图形界面**

系统设置 → 网络 → 防火墙 → 选项… → 允许以下应用接受传入连接 → 点 `+`，按 `⌘⇧G` 输入 `/opt/homebrew/bin/node`（Intel 是 `/usr/local/bin/node`）→ 添加后设为「允许传入连接」。

**方式 C：命令行**

```bash
NODE_BIN="$(readlink "$(command -v node)")"        # 解析到真实路径
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$NODE_BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$NODE_BIN"

# 确认结果
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps | grep -A2 -i node
```

> 注意：Homebrew 升级 node 后真实路径会变（`…/Cellar/node/26.x/bin/node`），规则可能失效，重新执行上面的 `--add/--unblockapp` 即可；也可以直接把 `/opt/homebrew/bin/node` 这个软链加进去。

**验证（换一台设备或容器里执行）**

```bash
curl -s http://192.168.0.88:7777/health
# 或在容器里（镜像没有 curl）：
docker exec xhs_pic_download node -e "fetch('http://192.168.0.88:7777/health').then(r=>r.json()).then(console.log)"
```

排查顺序：`127.0.0.1` 自测通 → 同网段另一台机器不通，就是防火墙/AP 隔离；`ECONNREFUSED` 多是 IP 端口写错，`timeout` 多是防火墙或跨网段。

> 不建议把整个防火墙关掉（`--setglobalstate off`）当长期方案。真要按端口放行只能用 pf 写锚点规则，比按应用放行麻烦得多。

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `HOST` | 0.0.0.0 | 监听地址。要跨机器/容器访问必须保持 `0.0.0.0` |
| `PORT` | 7777 | 监听端口；启动日志会打印可用的局域网地址 |
| `ALBUM` | 小红书 | 目标相簿（不存在会自动创建） |
| `TRIM_SECONDS` | 3 | Live 视频裁剪时长 |
| `STILL_MAX_EDGE` | 0 | >0 时按最长边缩放静止帧（如 `1440`，让尺寸贴近 1080p 级视频） |
| `MATCH_STILL_TO_VIDEO` | 0 | 置 1 时把静止帧按视频宽高居中裁剪（仅在非配对模式兜底用；3302 已由标识 + still-image-time 轨解决） |
| `PAIR_IDENTIFIER` | 1 | 置 1 时生成 UUID，写进视频的 `content.identifier`，并由 lpimport 用 ImageIO 写进静止帧的 Apple MakerNote tag 17（两端一致 Photos 才认这对资源）。置 0 退回旧行为 |
| `VIDEO_CODEC` | libx264 | 视频编码器。真机 Live Photo 是 HEVC(hvc1)，若配对仍失败可试 `VIDEO_CODEC=libx265` 或 `VIDEO_CODEC=hevc_videotoolbox`（会带 `-tag:v hvc1`） |
| `TAG_CONTENT_ID` | 0 | 仅在 `PAIR_IDENTIFIER=0` 时生效：单独给视频写标识（导出散文件用） |
| `EMBED_COVER` | auto | 视频封面：`auto`（≤20MB 画到第一帧，大视频跳过重编码保原画质）/ `first-frame` / `attached-pic` / `skip` |
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
| `unable to load standard library for target 'arm64-apple-macosx…'` | build.sh 现在会：① 显式传 `-sdk "$(xcrun --sdk macosx --show-sdk-path)"`（工具链探测不到 SDK 时救命）；② 自动逐个探测部署目标（11 → 12 … → 宿主主版本 → SDK 主版本），取第一个能编译的，日志会打印 `工具链自检通过（目标 …）`。仍失败就跑 `./build.sh --diagnose`：它会打印 `swiftc -print-target-info`、SDK 里 `Swift.swiftmodule` 清单，以及每个候选目标的成败。若全部失败说明 CLT 是残缺安装（`pkgutil --pkgs \| grep -ci commandlinetools` 为 0）：`sudo rm -rf /Library/Developer/CommandLineTools` 后用 `softwareupdate --list \| grep -i "command line"` 找到条目安装，或改用完整 Xcode（`sudo xcode-select -s /Applications/Xcode.app`） |
| 下载 0 字节 / 403 | CDN 防盗链，确认带了 UA/Referer（worker 已内置） |
| 容器里连不上 worker | 用启动日志打印的局域网 IP（不要用 `127.0.0.1`）；`HOST` 保持 `0.0.0.0`；macOS 防火墙放行 `node` |
| Mac 上有了但 iPhone 没有 | Mac「照片」需开启 iCloud 照片，且与 iPhone 同 Apple ID |
