const doGetUrl = require("./main");

var express = require("express");
const bodyParser = require('body-parser');
const axios = require('axios');
var app = express();

app.disable("x-powered-by");
app.use(bodyParser.json({ limit: "16kb" }));

// 只要配置了 LIVEPHOTO_WORKER_URL，解析出 Live Photo 就自动投递给 Mac 上的合成 worker；
// 不再需要 ?import=1。可用 ?import=0 单次关闭，或 LIVEPHOTO_AUTO_IMPORT=0 全局关闭。
const LIVEPHOTO_WORKER_URL = process.env.LIVEPHOTO_WORKER_URL || '';
const LIVEPHOTO_ALBUM = process.env.LIVEPHOTO_ALBUM || '小红书';
const LIVEPHOTO_TIMEOUT = Number(process.env.LIVEPHOTO_TIMEOUT || 10000);
const LIVEPHOTO_AUTO_IMPORT = process.env.LIVEPHOTO_AUTO_IMPORT !== '0';
const WORKER_ENDPOINT = LIVEPHOTO_WORKER_URL
  ? `${LIVEPHOTO_WORKER_URL.replace(/\/+$/, '')}/livephoto`
  : null;

/** 读取调用方的 import 开关：true=强制转发，false=本次不转发，null=未表态 */
function readImportFlag(req) {
  const queryFlag = req.query.import;
  const bodyFlag = req.body ? req.body.import : undefined;
  const value = queryFlag !== undefined ? queryFlag : bodyFlag;
  if (value === undefined || value === null) {
    return null;
  }
  const text = String(value).toLowerCase();
  if (text === '1' || text === 'true') {
    return true;
  }
  if (text === '0' || text === 'false') {
    return false;
  }
  return null;
}

function pickLiveItems(result) {
  return (result.items || []).filter(
    (item) => item.isLivePhoto && item.livePhotoVideoUrl && item.imageUrl
  );
}

// 最近一次转发的结果，暴露在 /status 上，便于判断"没触发 / 触发但失败"
let lastForward = null;

function rememberForward(result) {
  lastForward = Object.assign({ at: new Date().toISOString() }, result);
}

async function forwardToLivePhotoWorker(items) {
  const targets = (items || []).filter(
    (item) => item.isLivePhoto && item.livePhotoVideoUrl && item.imageUrl
  );
  if (targets.length === 0) {
    rememberForward({ target: WORKER_ENDPOINT, attempted: 0, ok: 0, failed: 0, lastError: null });
    return [];
  }
  const results = [];
  for (const item of targets) {
    try {
      const response = await axios.post(
        WORKER_ENDPOINT,
        {
          imageUrl: item.imageUrl,
          videoUrl: item.livePhotoVideoUrl,
          album: LIVEPHOTO_ALBUM,
        },
        { timeout: LIVEPHOTO_TIMEOUT }
      );
      results.push({ ok: true, jobId: response.data.jobId, imageUrl: item.imageUrl });
    } catch (error) {
      console.log(`forward livephoto failed (${WORKER_ENDPOINT}): ${error.message}`);
      results.push({ ok: false, error: error.message, imageUrl: item.imageUrl });
    }
  }
  rememberForward({
    target: WORKER_ENDPOINT,
    attempted: targets.length,
    ok: results.filter((item) => item.ok).length,
    failed: results.filter((item) => !item.ok).length,
    lastError: (results.find((item) => !item.ok) || {}).error || null,
  });
  return results;
}

app.all("/getXhsPicUrl", async function (req, res) {
  res.set("Content-Type", "application/json");
  const shareText = req.query.shareText || req.body.shareText;
  const xhsCookie = req.body.xhsCookie;
  if (!shareText) {
    res.send(JSON.stringify({
      error: "缺少shareText参数",
    }));
    return;
  }
  try {
    const result = await doGetUrl(
      {
        shareText: shareText,
        xhsCookie: xhsCookie,
      },
      null
    );
    const importFlag = readImportFlag(req);
    const liveItems = pickLiveItems(result);
    const autoEnabled = LIVEPHOTO_AUTO_IMPORT || importFlag === true;
    const wantForward = !result.error && importFlag !== false && liveItems.length > 0 && autoEnabled;

    if (wantForward && LIVEPHOTO_WORKER_URL) {
      result.livePhotoJobs = await forwardToLivePhotoWorker(result.items);
      result.livePhotoForward = lastForward;
    } else if (wantForward && !LIVEPHOTO_WORKER_URL) {
      // 检测到 Live Photo 但没配 worker：不报错，明确告知即可
      console.warn('[livephoto] 检测到 Live Photo，但未配置 LIVEPHOTO_WORKER_URL，未自动合成');
      rememberForward({
        target: null,
        attempted: 0,
        ok: 0,
        failed: 0,
        lastError: 'LIVEPHOTO_WORKER_URL 未配置',
      });
      result.livePhotoWarning = '检测到 Live Photo，但未配置 LIVEPHOTO_WORKER_URL，未自动合成（不影响图片/视频下载）';
    } else if (importFlag === true && result.error) {
      result.livePhotoWarning = `解析失败，未转发：${result.error}`;
    }
    res.send(JSON.stringify(result));
  } catch (e) {
    res.send(JSON.stringify({
      error: e.message,
    }));
  }
});

app.get("/healthz", (req, res) => res.send("ok"));

// 自检端点：确认转发配置是否生效、最近一次转发的结果
app.get("/status", (req, res) => {
  res.json({
    version: require('./package.json').version,
    livePhoto: {
      workerUrl: LIVEPHOTO_WORKER_URL || null,
      workerEndpoint: WORKER_ENDPOINT,
      album: LIVEPHOTO_ALBUM,
      timeoutMs: LIVEPHOTO_TIMEOUT,
      forwardingEnabled: Boolean(LIVEPHOTO_WORKER_URL),
      autoImport: LIVEPHOTO_AUTO_IMPORT,
    },
    lastForward,
    hint:
      LIVEPHOTO_WORKER_URL
        ? '解析到 Live Photo 会自动转发；可用 ?import=0 单次关闭'
        : '未配置 LIVEPHOTO_WORKER_URL：请用 -e LIVEPHOTO_WORKER_URL=http://<Mac IP>:7777 重建容器',
  });
});

app.listen(7776);
