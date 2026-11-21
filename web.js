const doGetUrl = require("./main");

var express = require("express");
const bodyParser = require('body-parser');
const axios = require('axios');
var app = express();

app.disable("x-powered-by");
app.use(bodyParser.json({ limit: "16kb" }));

// 可选：配置 LIVEPHOTO_WORKER_URL 后，请求带 ?import=1 会把 Live Photo 任务直接投递给 Mac 上的合成 worker
const LIVEPHOTO_WORKER_URL = process.env.LIVEPHOTO_WORKER_URL || '';
const LIVEPHOTO_ALBUM = process.env.LIVEPHOTO_ALBUM || '小红书Live';
const LIVEPHOTO_TIMEOUT = Number(process.env.LIVEPHOTO_TIMEOUT || 10000);

async function forwardToLivePhotoWorker(items) {
  const targets = (items || []).filter(
    (item) => item.isLivePhoto && item.livePhotoVideoUrl && item.imageUrl
  );
  const results = [];
  for (const item of targets) {
    try {
      const response = await axios.post(
        `${LIVEPHOTO_WORKER_URL.replace(/\/+$/, '')}/livephoto`,
        {
          imageUrl: item.imageUrl,
          videoUrl: item.livePhotoVideoUrl,
          album: LIVEPHOTO_ALBUM,
        },
        { timeout: LIVEPHOTO_TIMEOUT }
      );
      results.push({ ok: true, jobId: response.data.jobId, imageUrl: item.imageUrl });
    } catch (error) {
      console.log(`forward livephoto failed: ${error.message}`);
      results.push({ ok: false, error: error.message, imageUrl: item.imageUrl });
    }
  }
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
    const shouldImport = req.query.import === '1' || req.body.import === true;
    if (shouldImport && LIVEPHOTO_WORKER_URL && !result.error) {
      result.livePhotoJobs = await forwardToLivePhotoWorker(result.items);
    }
    res.send(JSON.stringify(result));
  } catch (e) {
    res.send(JSON.stringify({
      error: e.message,
    }));
  }
});

app.get("/healthz", (req, res) => res.send("ok"));

app.listen(7776);
