# XhsPicDownload

## 简介

结合iOS的“快捷指令”，一键从小红书下载无水印图片/视频

> Live Photo 现在支持**自动合成**：在 Mac 上跑一个合成 worker，粘贴链接后 Live Photo 会自动写入照片图库并同步到 iPhone，详见 [docs/livephoto.md](docs/livephoto.md)。
>
> 未部署 worker 时，Live Photo 依旧会被拆分为封面图片（原图）+ 一段视频，可自行使用其他 App 进行合并。

## 使用教程

### Docker

```sh
# 构建镜像
docker build -t nfew/xhs_pic_download:latest .

# 启动容器
docker run -d -p 7776:7776 --name xhs_pic_download nfew/xhs_pic_download:latest
```

也可以用仓库自带的 `build-image.sh`（读了 `.env` 的版本号后构建并推送）：

```sh
cp .env.example .env    # 首次：内容是 APP_VERSION=1.0.1
./build-image.sh        # 构建并推送 <IMAGE>:1.0.1 与 <IMAGE>:latest

# 发新版本：改 .env 里的 APP_VERSION（1.0.1 → 1.0.2），再跑一次 ./build-image.sh
# 换镜像名：IMAGE=yourhub/xhs_pic_download ./build-image.sh
```

#### 1. 部署

请使用 docker 自行部署

#### 2. 添加 iPhone 快捷指令

(1) 在 iPhone 的浏览器中，打开以下链接。

https://www.icloud.com/shortcuts/fef496ed540e42949e8154ddbf6ac8f9


(2) 在打开的页面中点击「获取捷径」按钮，然后在弹出的窗口中点击「添加快捷指令」。

(3) 点击刚刚添加成功的快捷指令右上角的三个点，打开快捷指令的编辑页面。将服务器部署的 URL 填入「文本」区域，点击右上角「完成」。

> 注意：类似 `https://1.2.3.4/getXhsPicUrl` 这样的格式。

#### 3. 使用

在小红书客户端，点击动态详情，右上角的箭头分享按钮，点击「复制链接」，打开「快捷指令」App，单击「一键保存小红书图片/视频」即可（会自动获取剪切板）。

## Live Photo 自动合成（可选）

Live Photo 需要「静止帧 + 3 秒视频」通过同一个 Asset Identifier 配对，而 iOS 快捷指令没有合成能力（只有「存储图像 / 存储视频」），因此合成放在 macOS 上完成：

1. 主服务接口保持兼容（`picUrlArray` 与上游完全一致），响应新增 `items`，逐个图片携带 `livePhotoVideoUrl` / `isLivePhoto`；
2. 在 Mac（mini）上运行 `livephoto/worker.js`：下载原图 + Live 视频 → ffmpeg 规范化（webp/heic → JPEG、视频裁成 3 秒 H.264/yuv420p）→ 调用 `PHAssetCreationRequest` 以 `.photo + .pairedVideo` 写入照片图库；
3. 打开「iCloud 照片」，合成的 Live Photo 会自动出现在 iPhone 上。

```sh
cd livephoto
brew install node ffmpeg
npm install && ./build.sh     # 编译 Swift 导入器
node worker.js                # 首次运行请允许「访问您的照片」
```

快捷指令改造与完整原理见 [docs/livephoto.md](docs/livephoto.md)、[livephoto/README.md](livephoto/README.md)。

## 接口

`GET|POST /getXhsPicUrl?shareText=<分享文本>`

```json
{
  "picUrlArray": ["原图...", "Live Photo 视频...", "普通视频"],
  "items": [
    { "index": 0, "type": "image", "imageUrl": "https://ci.xiaohongshu.com/<id>",
      "originalUrl": "https://ci.xiaohongshu.com/<id>",
      "livePhotoVideoUrl": "https://sns-video-hw.xhscdn.com/xxx.mov", "isLivePhoto": true }
  ]
}
```

> 实况视频为静音版（XHS `WEB_LIVEPHOTO_19`，audio 参数全 0），本项目不做音频处理。

> 上游已改为返回原图（不带 `imageView2` 参数），格式可能是 jpeg/webp/heic；worker 会统一转成 JPEG 后再参与 Live Photo 配对。

只要容器配了 `LIVEPHOTO_WORKER_URL=http://<Mac IP>:7777`，解析到 Live Photo 就会**自动**投递给 Mac 合成，**不需要任何额外参数**；
想单次关闭用 `?import=0`，想改成"必须显式请求才转发"用 `LIVEPHOTO_AUTO_IMPORT=0`。

### 全远程模式：`/getXhsPicRemote`

```sh
curl "http://<主服务>:7776/getXhsPicRemote?shareText=<分享文本>"
```

图片、Live Photo、视频**全部由 Mac 下载并写入照片图库**，iPhone 只发这一个请求、不保存任何媒体：

| item | 处理 |
|---|---|
| `isLivePhoto=true` | 合成为 Live Photo 进相册 |
| `type=image` | 直接存入照片 |
| `type=video` | 直接存入视频 |

返回 `{ ok, itemCount, items, remoteJobs, remoteForward }`；每条任务的进度可在 Mac 上查 `GET <worker>/jobs`。

## 测试

```sh
npm test
```

## 声明:

- 本仓库发布的`xhs_pic_download`项目中涉及的任何脚本，仅用于测试和学习研究，禁止用于商业用途
- `nfe-w` 对任何脚本问题概不负责，包括但不限于由任何脚本错误导致的任何损失或损害
- 以任何方式查看此项目的人或直接或间接使用`xhs_pic_download`项目的任何脚本的使用者都应仔细阅读此声明
- `xhs_pic_download` 保留随时更改或补充此免责声明的权利。一旦使用并复制了任何相关脚本或`xhs_pic_download`项目，则视为已接受此免责声明
- 本项目遵循`MIT LICENSE`协议，如果本声明与`MIT LICENSE`协议有冲突之处，以本声明为准