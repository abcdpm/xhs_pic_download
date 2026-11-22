const doGetUrl = require("./main");

var express = require("express");
const bodyParser = require('body-parser');
const axios = require('axios');
var app = express();

app.disable("x-powered-by");
app.use(bodyParser.json({ limit: "16kb" }));

// 可选：配置 LIVEPHOTO_WORKER_URL 后，请求带 ?import=1 会把 Live Photo 任务直接投递给 Mac 上的合成 worker
const LIVEPHOTO_WORKER_URL = process.env.LIVEPHOTO_WORKER_URL || '';
const LIVEPHOTO_ALBUM = process.env.LIVEPHOTO_ALBUM || '小红书';
const LIVEPHOTO_TIMEOUT = Number(process.env.LIVEPHOTO_TIMEOUT || 10000);
const WORKER_ENDPOINT = LIVEPHOTO_WORKER_URL
  ? `${LIVEPHOTO_WORKER_URL.replace(/\/+$/, '')}/livephoto`
  : null;

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
    // 兼容 ?import=1 / ?import=true / body {"import": true|"true"|"1"}
    const importFlag = req.query.import;
    const bodyFlag = req.body ? req.body.import : undefined;
    const shouldImport =
      importFlag === '1' ||
      importFlag === 'true' ||
      bodyFlag === true ||
      bodyFlag === 'true' ||
      bodyFlag === '1';

    if (shouldImport && !result.error) {
      if (!LIVEPHOTO_WORKER_URL) {
        // 没配 worker 地址时不算错误，但要明确告诉调用方"没有转发"，避免以为已合成
        console.warn('[livephoto] 请求带 import=1，但未配置 LIVEPHOTO_WORKER_URL，已跳过转发');
        rememberForward({
          target: null,
          attempted: 0,
          ok: 0,
          failed: 0,
          lastError: 'LIVEPHOTO_WORKER_URL 未配置',
        });
        result.livePhotoJobs = [];
        result.livePhotoWarning = '未配置 LIVEPHOTO_WORKER_URL，Live Photo 未转发（不影响图片/视频下载）';
      } else {
        result.livePhotoJobs = await forwardToLivePhotoWorker(result.items);
        result.livePhotoForward = lastForward;
      }
    } else if (shouldImport && result.error) {
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
    },
    lastForward,
    hint:
      LIVEPHOTO_WORKER_URL
        ? '请求带 ?import=1 才会触发转发'
        : '未配置 LIVEPHOTO_WORKER_URL：请用 -e LIVEPHOTO_WORKER_URL=http://<Mac IP>:7777 重建容器',
  });
});

app.listen(7776);
