"""
mitmproxy 插件：抓小红书 App 流量时，只高亮「音频相关」的请求 / 响应字段。

用法（在仓库根目录）：
    brew install mitmproxy
    mitmweb  -s livephoto/tools/mitm-audio-logger.py --listen-port 8080
    # 或纯命令行
    mitmdump -s livephoto/tools/mitm-audio-logger.py --listen-port 8080

效果：
    - 请求 URL 含 audio/music/bgm/mp3/m4a/aac/sound → 打印出来（含 Query 与 body）
    - 任意 JSON 响应里出现 music / musicUrl / audioBitrate / audioUrl / bgm /
      originVideoKey 等字段 → 打印字段路径与值

抓到形如 http://sns-audio-*.xhscdn.com/xxx.mp3?sign=... 的直链后，
直接喂给 worker 的 bgmUrl 即可合成带声音的 Live Photo。
"""

import json
import re

from mitmproxy import http

AUDIO_URL_RE = re.compile(r"(audio|music|bgm|mp3|m4a|aac|sound|ringtone)", re.I)
INTERESTING_API_RE = re.compile(
    r"/api/sns/(app|web|h5)/v?\d*/(feed|note|music|audio|note_detail)", re.I
)
FIELD_KEYS = (
    "music",
    "musicurl",
    "musicid",
    "audio",
    "audiourl",
    "audiobitrate",
    "audiochannels",
    "originvideokey",
    "bgm",
    "livephoto",
)

MAX_BODY = 4000
MAX_HITS = 40
MAX_DEPTH = 6


def _scan(node, path="", depth=0):
    hits = []
    if depth > MAX_DEPTH:
        return hits
    if isinstance(node, dict):
        for key, value in node.items():
            key_text = str(key)
            if any(field in key_text.lower() for field in FIELD_KEYS):
                hits.append((f"{path}.{key_text}", value))
            hits.extend(_scan(value, f"{path}.{key_text}", depth + 1))
    elif isinstance(node, list):
        for index, value in enumerate(node[:20]):
            hits.extend(_scan(value, f"{path}[{index}]", depth + 1))
    return hits


def _short(value, limit=300):
    if isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, ensure_ascii=False)
        except Exception:
            text = str(value)
    return text if len(text) <= limit else text[:limit] + "…"


def request(flow: http.HTTPFlow) -> None:
    url = flow.request.pretty_url
    if not (AUDIO_URL_RE.search(url) or INTERESTING_API_RE.search(url)):
        return
    print(f"\n[AUDIO-URL] {flow.request.method} {url}", flush=True)
    body = flow.request.get_text(strict=False) or ""
    if body and len(body) <= MAX_BODY:
        print(f"[REQUEST-BODY] {body}", flush=True)


def response(flow: http.HTTPFlow) -> None:
    content_type = flow.response.headers.get("content-type", "").lower()
    if "json" not in content_type:
        return
    try:
        payload = json.loads(flow.response.get_text(strict=False) or "")
    except Exception:
        return
    hits = _scan(payload)
    if not hits:
        return
    print(f"\n[API] {flow.request.pretty_url}", flush=True)
    for path, value in hits[:MAX_HITS]:
        print(f"  {path} = {_short(value)}", flush=True)
