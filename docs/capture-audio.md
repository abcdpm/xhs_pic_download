# 移动端抓包：找小红书的音频接口

> 目标：确认 App 播放实况笔记时，声音是从哪个 API/CDN 取的；拿到地址后直接喂给
> `livephoto` worker 的 `bgmUrl`（已支持混音）。

## 0. 先做最便宜的一步（不抓包）

浏览器**登录**小红书 → 打开笔记 → F12 → Network → 过滤 `feed` → 看 Response 里有没有
`music` / `musicUrl` / `audioBitrate > 0`。

- 有 → 直接用 `xhsCookie` 走签名接口就能取，不必抓包（见 `docs/livephoto.md` 10.1）
- 没有 → 再往下抓 App

## 1. 关键认知：要抓什么

| 目标 | 关键词 |
|---|---|
| 音频文件 | URL 里含 `audio` / `music` / `bgm` / `mp3` / `m4a` / `aac` / `sound` |
| App 接口 | `/api/sns/app/…`、`/api/sns/v1/…`、`/api/sns/web/v1/feed`（App 与 Web 接口不同） |
| 响应字段 | `music`、`musicUrl`、`audioBitrate`、`originVideoKey`、`livePhoto` |

抓到**带 `sign`/`t` 参数的 CDN 直链**是最理想的：这种 URL 一般可以直接 `curl` 复用，
喂给 worker 即可。若是需要设备签名的 API（`X-S`/`shield`/`x-mini-mua` 等），复放难度高，
通常只能"抓到一次、立刻用一次"。

## 2. iOS + Mac（推荐，成功率最高）

### 2.1 装 mitmproxy（或用 Proxyman，界面更友好）

```bash
brew install mitmproxy
# 带插件启动：只打印音频相关的请求/响应
mitmweb -s livephoto/tools/mitm-audio-logger.py --listen-port 8080
```

`mitmweb` 会打开 `http://127.0.0.1:8081` 的界面；插件会在终端打印命中的请求。

### 2.2 iPhone 设置

1. iPhone 与 Mac 连同一个 Wi-Fi；
2. iPhone：设置 → 无线局域网 → 当前网络 → 配置代理 → 手动
   - 服务器：Mac 的局域网 IP（`ipconfig getifaddr en0`）
   - 端口：`8080`
3. iPhone Safari 打开 **http://mitm.it** → 选 iOS → 允许下载描述文件；
4. 设置 → 通用 → VPN与设备管理 → 安装该描述文件；
5. 设置 → 通用 → 关于本机 → **证书信任设置** → 打开 `mitmproxy` 的开关；
6. 回到小红书 App，打开那条笔记、播放一次。

### 2.3 如果抓不到（重要）

- **App 走了 QUIC/HTTP3**：UDP 443 无法解密。解决办法：在路由器/防火墙上屏蔽 UDP 443，
  或 Mac 上只代理 TCP（App 会回落到 HTTPS）；
- **证书固定（pinning）**：表现为 App 里提示"网络异常"、`mitmweb` 里只有 CONNECT 没有明文。
  - 已越狱：装 `SSL Kill Switch 2` / 用 Frida 脚本 hook `SecTrustEvaluate`；
  - 未越狱：改用 Android 方案（见下），或在越狱设备上操作；
- 记得抓完把 iPhone 的代理关掉，否则断网。

## 3. Android（无越狱可行，pinning 也好处理）

### 3.1 系统证书（推荐）

Android 7+ 默认不信任用户证书，需要把 CA 放进系统证书区：

- 有 root（Magisk）：装模块 **Move Certificates**，然后照常装 mitmproxy CA；
- 无 root：用 **apk-mitm** 重打包小红书 APK（它会关闭 `networkSecurityConfig` 的 pinning 与
  用户证书限制），装到手机上再抓：

```bash
npx apk-mitm xhs.apk     # 输出 xhs-patched.apk
adb install -r xhs-patched.apk
```

> 仅供个人研究；重打包与原版不能共存，注意账号风险。

### 3.2 模拟器 + Frida（更干净）

- Android Studio 模拟器（可写系统分区）→ 导入 CA 到 `/system/etc/security/cacerts`
- 或 rooted 设备 + `objection -g com.xingin.xhs explore` → `android sslpinning disable`

## 4. 纯手机方案（不想开电脑）

| App | 平台 | 说明 |
|---|---|---|
| **Stream** | iOS（App Store） | 一键装 CA，界面简单，部分 App 能解 |
| **Thor** | iOS（付费） | 抓包 + 断点，能配合过滤器 |
| **HttpCanary / Reqable** | Android | 需装 CA；对 pinning 的 App 可能无效 |
| **Surge / Loon / Quantumult X** | iOS（付费） | 自带 MITM，能按域名过滤，适合长期用 |

## 5. 抓到之后怎么用

### 5.1 直接是音频直链

```bash
# 先用 curl 验证能下载（带上抓到的 headers）
curl -sS -o /tmp/bgm.m4a '<抓到的音频URL>'

# 直接喂给 worker（已支持 bgmUrl）
curl -s -X POST http://127.0.0.1:7777/livephoto \
  -H 'content-type: application/json' \
  -d '{"imageUrl":"<图>","videoUrl":"<实况视频>","bgmUrl":"<音频URL>","wait":true}'
```

日志会出现 `downloaded bgm=…B` 与 `output video=… +aac`，相册里就有声音了。

### 5.2 是需要签名的接口

把抓到的**完整请求**（URL + headers + body）保存下来，我们可以：

1. 先看它的响应结构，确认音频字段名；
2. 若签名只依赖固定参数（很多 CDN 的 `sign`+`t` 就是），直接复用；
3. 若是设备级签名（`shield`/`x-mini-mua`），只能"现抓现用"——把 URL 手工贴进 `bgmUrl`。

## 6. 合规与风险

- 抓包仅用于**你本人账号、个人备份**场景；不要批量抓取或分发内容；
- 安装第三方 CA 会降低设备安全性，抓完请**及时删除描述文件与代理设置**；
- 重打包 APK / 关闭 pinning 可能触发风控，注意账号安全；
- 平台接口随时可能变化，本方案不保证长期有效。

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| iPhone 装完描述文件仍抓不到明文 | 证书信任开关没开（设置 → 通用 → 关于本机 → 证书信任设置） |
| App 提示网络异常 | 遇到了 pinning，或需要开 QUIC 回落（屏蔽 UDP 443） |
| `mitmweb` 里全是 CONNECT，没有 body | 同上（pinning）；或 App 用了自家协议 |
| 抓到的 URL 几分钟后失效 | CDN 带时效签名，属于正常现象，现抓现用 |
| 手机连不上代理 | Mac 防火墙拦截，或 iPhone 与 Mac 不在同一网段 |
