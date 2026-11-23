/**
 * xhs-livephoto worker
 *
 * 把 main.js 解析出的「静止帧 + Live Photo 视频」合成为真正的 Live Photo 并写入 macOS 照片图库，
 * 之后由 iCloud 照片自动同步到 iPhone。必须在 macOS 宿主机运行（不能进 Docker，
 * 因为 Photos.framework / TCC 权限只对宿主机进程生效）。
 *
 * 依赖：ffmpeg（brew install ffmpeg）、./bin/lpimport（./build.sh 编译）
 * 启动：node worker.js
 */
const crypto = require('crypto')
const fs = require('fs')
const fsp = require('fs/promises')
const os = require('os')
const path = require('path')
const { execFile } = require('child_process')

const axios = require('axios')
const express = require('express')

const PORT = Number(process.env.PORT || 7777)
const HOST = process.env.HOST || '0.0.0.0'
const WORKER_VERSION = require('./package.json').version
const FFMPEG = process.env.FFMPEG || 'ffmpeg'
const IMPORTER = process.env.IMPORTER || path.join(__dirname, 'bin', 'lpimport')
const DEFAULT_ALBUM = process.env.ALBUM || '小红书'
const WORK_DIR = process.env.WORK_DIR || path.join(os.tmpdir(), 'xhs-livephoto')
const TRIM_SECONDS = Number(process.env.TRIM_SECONDS || 3)
// 视频编码器：默认 libx264；真机 Live Photo 是 HEVC(hvc1)，
// 若 Photos 对编码有要求，可用 VIDEO_CODEC=libx265 或 hevc_videotoolbox 做 A/B
const VIDEO_CODEC = process.env.VIDEO_CODEC || 'libx264'
const IS_HEVC = /265|hevc/i.test(VIDEO_CODEC)
const CONCURRENCY = Number(process.env.CONCURRENCY || 1)
const KEEP_FAILED = process.env.KEEP_FAILED === '1'
// PhotoKit 配对要求「静止帧的 Apple MakerNote tag 17」与「视频的
// com.apple.quicktime.content.identifier」两个标识一致。
// PAIR_IDENTIFIER=1（默认）时：worker 生成 UUID，写进视频，并让 lpimport
// 用 ImageIO 写进静止帧（exiftool 做不到这件事）。
// 设为 0 可退回旧行为（不写标识、静止帧由 ffmpeg/sips 预先转码）。
const PAIR_IDENTIFIER = process.env.PAIR_IDENTIFIER !== '0'
// 仅在没有开启配对时生效：是否仍单独给视频写标识（导出散文件用）
const TAG_CONTENT_ID = process.env.TAG_CONTENT_ID === '1'
// 把静止帧裁剪对齐到视频的宽高（备用开关，配对模式下 lpimport 会用 ImageIO 缩放）
const MATCH_STILL_TO_VIDEO = process.env.MATCH_STILL_TO_VIDEO === '1'
const DOWNLOAD_TIMEOUT = Number(process.env.DOWNLOAD_TIMEOUT || 60000)
const MAX_JOBS_KEPT = Number(process.env.MAX_JOBS_KEPT || 200)

const DOWNLOAD_HEADERS = {
  'user-agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  referer: 'https://www.xiaohongshu.com/',
  accept: '*/*',
}

// MARK: - 基础工具

function run(command, args, timeout = 180000) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        const detail = (stderr || '').trim() || error.message
        reject(new Error(`${path.basename(command)} 执行失败: ${detail}`))
        return
      }
      resolve({ stdout: stdout.trim(), stderr: stderr.trim() })
    })
  })
}

function ensureHttpUrl(value, field) {
  if (typeof value !== 'string' || !/^https?:\/\//i.test(value)) {
    throw new Error(`${field} 必须是 http(s) 地址`)
  }
  return value
}

/** 列出本机的局域网 IPv4 地址，方便把 worker 地址填到容器/快捷指令里 */
function lanUrls(port) {
  const urls = []
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses || []) {
      if (address.family === 'IPv4' && !address.internal) {
        urls.push(`http://${address.address}:${port}`)
      }
    }
  }
  return urls
}

async function download(url, filePath) {
  const writer = fs.createWriteStream(filePath)
  const response = await axios.get(url, {
    responseType: 'stream',
    timeout: DOWNLOAD_TIMEOUT,
    maxRedirects: 5,
    headers: DOWNLOAD_HEADERS,
  })
  const contentType = String(response.headers['content-type'] || 'unknown')
  await new Promise((resolve, reject) => {
    response.data.on('error', reject)
    writer.on('error', reject)
    writer.on('finish', resolve)
    response.data.pipe(writer)
  })
  const stat = await fsp.stat(filePath)
  if (stat.size === 0) {
    throw new Error(`下载结果为空: ${url}`)
  }
  return { size: stat.size, contentType }
}

/**
 * 静止帧必须是 JPEG/HEIC：上游现在返回的是不带 imageView2 参数的「原图」，
 * 格式可能是 jpeg / webp / heic，这里统一转成 baseline JPEG。
 * 优先用 ffmpeg；若 ffmpeg 缺少对 HEIC 的支持，macOS 上回退到系统自带 sips。
 *
 * 可选：
 *   STILL_MAX_EDGE=N          按最长边缩放
 *   MATCH_STILL_TO_VIDEO=1    按视频宽高居中裁剪（PHPhotosError 3302 常见对策）
 */
async function prepareStill(input, output, videoSize) {
  const maxEdge = Number(process.env.STILL_MAX_EDGE || 0)
  const filters = []
  if (maxEdge > 0) {
    filters.push(`scale='min(iw,${maxEdge})':-2`)
  }
  let crop = false
  if (MATCH_STILL_TO_VIDEO && videoSize && videoSize.width && videoSize.height) {
    filters.push(
      `scale=${videoSize.width}:${videoSize.height}:force_original_aspect_ratio=increase`
    )
    filters.push(`crop=${videoSize.width}:${videoSize.height}`)
    crop = true
  }

  const args = ['-y', '-hide_banner', '-loglevel', 'error', '-i', input, '-frames:v', '1']
  if (filters.length > 0) {
    args.push('-vf', filters.join(','))
  }
  args.push('-q:v', '2', output)

  try {
    await run(FFMPEG, args)
    return
  } catch (error) {
    if (process.env.SIPS_FALLBACK === '0' || !fs.existsSync('/usr/bin/sips')) {
      throw error
    }
    if (crop) {
      console.warn('[livephoto] ffmpeg 失败且需要裁剪，sips 无法裁剪，将退回普通转换')
    }
    const sipsArgs = []
    if (maxEdge > 0) {
      sipsArgs.push('-Z', String(maxEdge))
    }
    sipsArgs.push('-s', 'format', 'jpeg', input, '--out', output)
    await run('/usr/bin/sips', sipsArgs)
  }
}

/**
 * 把任意来源的 Live Photo 视频规范化为 Photos 能接受的配对视频：
 * H.264 + yuv420p + 3 秒 + mov 容器。
 * tag=true 时写入 com.apple.quicktime.content.identifier（必须与静止帧的
 * Apple MakerNote tag 17 一致，Photos 才会把它们配成 Live Photo）。
 */
async function prepareVideo(input, output, contentIdentifier, tag) {
  const useTag = tag === true
  const videoArgs = IS_HEVC
    ? ['-c:v', VIDEO_CODEC, '-tag:v', 'hvc1', '-pix_fmt', 'yuv420p']
    : ['-c:v', VIDEO_CODEC, '-profile:v', 'high', '-level', '4.1', '-pix_fmt', 'yuv420p']
  if (/videotoolbox/i.test(VIDEO_CODEC)) {
    videoArgs.push('-b:v', '8M')
  } else {
    videoArgs.push('-preset', 'veryfast', '-crf', '20')
  }

  const args = [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    input,
    '-t',
    String(TRIM_SECONDS),
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    ...videoArgs,
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-movflags',
    useTag ? '+faststart+use_metadata_tags' : '+faststart',
  ]
  if (useTag) {
    args.push('-metadata', `com.apple.quicktime.content.identifier=${contentIdentifier}`)
  }
  // 有些实现要求 MOV 里带 still-image-time 键，用于 A/B 测试
  if (process.env.STILL_TIME_METADATA === '1') {
    args.push('-metadata', 'com.apple.quicktime.still-image-time=0')
  }
  args.push('-video_track_timescale', '600')
  args.push(output)
  await run(FFMPEG, args)
}

/** 读取图片尺寸（macOS 用 sips，跨平台回退 ffmpeg） */
async function probeImage(input) {
  if (fs.existsSync('/usr/bin/sips')) {
    try {
      const { stdout } = await run('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', input], 20000)
      const width = /pixelWidth:\s*(\d+)/.exec(stdout)
      const height = /pixelHeight:\s*(\d+)/.exec(stdout)
      if (width && height) {
        return { width: Number(width[1]), height: Number(height[1]) }
      }
    } catch (error) {
      // 交给下面的 ffmpeg 兜底
    }
  }
  return probeVideo(input)
}

/**
 * 把封面图写进视频：作为 attached_pic 轨道（视频流不重新编码）。
 * 注意：mp4/mov 容器对 attached_pic 支持有限，ffmpeg 常会静默丢弃，
 * 默认使用下面的 embedCoverFirstFrame。
 */
async function embedCoverAttachedPic(videoInput, coverInput, output) {
  await run(FFMPEG, [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    videoInput,
    '-i',
    coverInput,
    '-map',
    '0',
    '-map',
    '1',
    '-c',
    'copy',
    '-disposition:v:1',
    'attached_pic',
    output,
  ])
}

/**
 * 把封面画到视频第一帧：Photos 的缩略图取自视频第一帧，这样封面就成了"视频封面"。
 * 需要重编码视频轨（CRF 18，肉眼接近无损），音频直接 copy。
 */
async function embedCoverFirstFrame(videoInput, coverInput, output, width, height) {
  const w = Number(width) > 0 ? width : 1080
  const h = Number(height) > 0 ? height : 1920
  const filter =
    `[1:v]scale=${w}:${h}:force_original_aspect_ratio=increase,` +
    `crop=${w}:${h},setsar=1[cover];` +
    `[0:v][cover]overlay=0:0:enable='lte(t,0.0334)'[v]`
  await run(FFMPEG, [
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    '-i',
    videoInput,
    '-i',
    coverInput,
    '-filter_complex',
    filter,
    '-map',
    '[v]',
    '-map',
    '0:a:0?',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '18',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'copy',
    '-movflags',
    '+faststart',
    output,
  ])
}

/** 用 ffmpeg -i 的 stderr 解析视频/图片的尺寸、时长、编码 */
async function probeVideo(input) {
  let text = ''
  try {
    const { stderr } = await run(FFMPEG, ['-hide_banner', '-i', input, '-f', 'null', '-'], 60000)
    text = stderr
  } catch (error) {
    text = error.message || ''
  }
  const size = /,\s(\d{2,5})x(\d{2,5})[\s,\[]/.exec(text)
  const duration = /Duration:\s(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(text)
  const codec = /Video:\s([a-z0-9]+)/.exec(text)
  return {
    width: size ? Number(size[1]) : null,
    height: size ? Number(size[2]) : null,
    duration: duration
      ? Number(duration[1]) * 3600 + Number(duration[2]) * 60 + Number(duration[3])
      : null,
    codec: codec ? codec[1] : null,
  }
}

/** 按 content-type 给下载文件补上扩展名（Photos 识别资源类型需要） */
const EXT_BY_CONTENT_TYPE = {
  'image/heic': 'heic',
  'image/heif': 'heic',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/x-m4v': 'm4v',
}

async function withExtension(filePath, contentType, fallbackExtension) {
  const key = String(contentType || '')
    .split(';')[0]
    .trim()
    .toLowerCase()
  const extension = EXT_BY_CONTENT_TYPE[key] || fallbackExtension
  const target = `${filePath}.${extension}`
  await fsp.rename(filePath, target)
  return target
}

async function runImporter({ imagePath, videoPath, album, takenAt, identifier, maxPixel }) {
  const args = []
  if (imagePath) {
    args.push('--image', imagePath)
  }
  if (videoPath) {
    args.push('--video', videoPath)
  }
  if (album) {
    args.push('--album', album)
  }
  if (takenAt) {
    args.push('--date', takenAt)
  }
  if (identifier) {
    args.push('--identifier', identifier)
  }
  if (maxPixel && maxPixel > 0) {
    args.push('--max-pixel', String(maxPixel))
  }
  if (process.env.DUMP_META === '1') {
    args.push('--dump')
  }
  if (process.env.COMPOSE_MOVIE === '0') {
    args.push('--no-compose')
  }
  const { stdout, stderr } = await run(IMPORTER, args, 240000)
  if (stderr) {
    stderr
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
      .forEach((line) => {
        console.info(line.startsWith('[lpimport]') ? line : `[lpimport] ${line}`)
      })
  }
  const lastLine = stdout.split('\n').filter(Boolean).pop()
  let parsed = null
  try {
    parsed = JSON.parse(lastLine)
  } catch (error) {
    throw new Error(`lpimport 输出无法解析: ${stdout}`)
  }
  if (!parsed || !parsed.ok) {
    throw new Error(parsed && parsed.error ? parsed.error : 'lpimport 返回失败')
  }
  return parsed
}

// MARK: - 任务队列

const jobs = new Map()
const queue = []
let running = 0

/**
 * 下载后按 job.kind 处理：
 *   livephoto（默认）：静止帧 + 视频 → 合成 Live Photo
 *   photo：单张图片 → 写入照片图库
 *   video：单个视频 → 写入照片图库
 */
async function runJob(job) {
  const jobDir = path.join(WORK_DIR, job.id)
  await fsp.mkdir(jobDir, { recursive: true })
  job.dir = jobDir
  const stillPath = path.join(jobDir, `${job.id}.jpg`)
  const composedPath = path.join(jobDir, `${job.id}.mov`)
  const fmt = (m) =>
    `${m.width || '?'}x${m.height || '?'}${m.duration ? ` ${m.duration.toFixed(2)}s` : ''}${
      m.codec ? ` ${m.codec}` : ''
    }`

  // ---- 下载 ----
  job.step = 'download'
  job.downloads = {}
  let imagePath = null
  let videoPath = null
  if (job.imageUrl) {
    const raw = path.join(jobDir, 'source_image')
    const image = await download(job.imageUrl, raw)
    imagePath = await withExtension(raw, image.contentType, 'jpg')
    job.downloads.image = { bytes: image.size, contentType: image.contentType }
    console.info(`[job ${job.id}] downloaded image=${image.size}B(${image.contentType})`)
  }
  if (job.videoUrl) {
    const candidates = [job.videoUrl]
    if (job.fallbackUrl && job.fallbackUrl !== job.videoUrl) {
      candidates.push(job.fallbackUrl)
    }
    let picked = null
    let lastError = null
    for (let i = 0; i < candidates.length; i += 1) {
      const url = candidates[i]
      try {
        const raw = path.join(jobDir, `source_video_${i}`)
        const info = await download(url, raw)
        picked = {
          url,
          size: info.size,
          contentType: info.contentType,
          path: await withExtension(raw, info.contentType, 'mp4'),
        }
        break
      } catch (error) {
        lastError = error
        console.warn(`[job ${job.id}] 视频下载失败：${url.slice(0, 100)} → ${error.message}`)
      }
    }
    if (!picked) {
      throw lastError || new Error('视频下载失败')
    }
    videoPath = picked.path
    job.downloads.video = {
      bytes: picked.size,
      contentType: picked.contentType,
      source: picked.url,
    }
    console.info(
      `[job ${job.id}] downloaded video=${picked.size}B(${picked.contentType}) ← ${picked.url.slice(0, 80)}`
    )
  }

  // ---- 单张图片 ----
  if (job.kind === 'photo') {
    job.step = 'import'
    const result = await runImporter({ imagePath, album: job.album, takenAt: job.takenAt })
    return finishJob(job, jobDir, {
      localIdentifier: result.localIdentifier,
      album: result.album,
      imageBytes: job.downloads.image ? job.downloads.image.bytes : null,
    })
  }

  // ---- 单个视频 ----
  if (job.kind === 'video') {
    let videoForImport = videoPath
    const coverMode = process.env.EMBED_COVER || 'first-frame'
    if (job.coverUrl && coverMode !== 'skip') {
      try {
        const rawCover = path.join(jobDir, 'source_cover')
        const cover = await download(job.coverUrl, rawCover)
        const coverPath = await withExtension(rawCover, cover.contentType, 'jpg')
        const media = await probeVideo(videoPath)
        const extension = path.extname(videoPath) || '.mp4'
        const posterPath = path.join(jobDir, `${job.id}.poster${extension}`)
        if (coverMode === 'attached-pic') {
          await embedCoverAttachedPic(videoPath, coverPath, posterPath)
        } else {
          await embedCoverFirstFrame(videoPath, coverPath, posterPath, media.width, media.height)
        }
        videoForImport = posterPath
        job.downloads.cover = { bytes: cover.size, contentType: cover.contentType }
        console.info(`[job ${job.id}] 封面已写入视频（${coverMode}）→ ${path.basename(posterPath)}`)
      } catch (error) {
        console.warn(`[job ${job.id}] 封面写入失败，改用原视频：${error.message}`)
      }
    }
    job.step = 'import'
    const result = await runImporter({ videoPath: videoForImport, album: job.album, takenAt: job.takenAt })
    return finishJob(job, jobDir, {
      localIdentifier: result.localIdentifier,
      album: result.album,
      videoBytes: job.downloads.video ? job.downloads.video.bytes : null,
      coverEmbedded: videoForImport !== videoPath,
    })
  }

  // ---- Live Photo ----
  job.step = 'probe'
  const videoMedia = await probeVideo(videoPath)
  job.media = { video: videoMedia }
  console.info(`[job ${job.id}] media video=${fmt(videoMedia)}`)

  job.step = 'transcode'
  if (!PAIR_IDENTIFIER) {
    try {
      const stillMedia = await probeImage(imagePath)
      job.media.still = stillMedia
      console.info(`[job ${job.id}] media still=${fmt(stillMedia)}`)
      await prepareStill(imagePath, stillPath, videoMedia)
    } catch (error) {
      throw new Error(
        `静止帧转码失败（content-type=${job.downloads.image ? job.downloads.image.contentType : '?'}）: ${error.message}`
      )
    }
  }
  try {
    // 配对模式下 ffmpeg 不写标识（由 AVAssetWriter 写），只做纯视频转码
    await prepareVideo(
      videoPath,
      composedPath,
      job.contentIdentifier,
      PAIR_IDENTIFIER ? false : TAG_CONTENT_ID
    )
  } catch (error) {
    throw new Error(`视频转码失败: ${error.message}`)
  }

  const outVideo = await probeVideo(composedPath)
  job.media.output = { video: outVideo }
  console.info(
    `[job ${job.id}] output video=${fmt(outVideo)} identifier=${job.contentIdentifier}` +
      (PAIR_IDENTIFIER ? '（静止帧由 lpimport 用 ImageIO 写入同一标识）' : '')
  )

  job.step = 'import'
  const result = await runImporter({
    imagePath: PAIR_IDENTIFIER ? imagePath : stillPath,
    videoPath: composedPath,
    album: job.album,
    takenAt: job.takenAt,
    identifier: PAIR_IDENTIFIER ? job.contentIdentifier : null,
    maxPixel: Number(process.env.STILL_MAX_EDGE || 0),
  })

  return finishJob(job, jobDir, {
    localIdentifier: result.localIdentifier,
    album: result.album,
    identifier: result.identifier || null,
  })
}

async function finishJob(job, jobDir, result) {
  job.step = 'done'
  job.result = result
  if (!KEEP_FAILED) {
    await fsp.rm(jobDir, { recursive: true, force: true })
  }
  return job.result
}

function pump() {
  while (running < CONCURRENCY && queue.length > 0) {
    const jobId = queue.shift()
    const job = jobs.get(jobId)
    if (!job) {
      continue
    }
    running += 1
    job.status = 'running'
    job.startedAt = new Date().toISOString()
    console.info(`[job ${job.id}] start kind=${job.kind} ${job.imageUrl || job.videoUrl || ''}`)
    runJob(job)
      .then(() => {
        job.status = 'done'
        job.finishedAt = new Date().toISOString()
        console.info(`[job ${job.id}] done -> ${job.result && job.result.localIdentifier}`)
      })
      .catch(async (error) => {
        job.status = 'failed'
        job.error = error.message
        job.finishedAt = new Date().toISOString()
        console.error(`[job ${job.id}] failed: ${error.message}`)
        if (!KEEP_FAILED && job.dir) {
          await fsp.rm(job.dir, { recursive: true, force: true }).catch(() => {})
        }
      })
      .finally(() => {
        running -= 1
        pruneJobs()
        pump()
      })
  }
}

function pruneJobs() {
  if (jobs.size <= MAX_JOBS_KEPT) {
    return
  }
  const finished = [...jobs.values()]
    .filter((job) => job.status === 'done' || job.status === 'failed')
    .sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)))
  for (const job of finished.slice(0, jobs.size - MAX_JOBS_KEPT)) {
    jobs.delete(job.id)
  }
}

function enqueue(payload) {
  const job = {
    id: crypto.randomUUID(),
    status: 'queued',
    createdAt: new Date().toISOString(),
    contentIdentifier: crypto.randomUUID().toUpperCase(),
    album: payload.album || DEFAULT_ALBUM,
    takenAt: payload.takenAt || null,
    kind: payload.kind || 'livephoto',
    imageUrl: payload.imageUrl || null,
    videoUrl: payload.videoUrl || null,
    fallbackUrl: payload.fallbackUrl || null,
    coverUrl: payload.coverUrl || null,
  }
  jobs.set(job.id, job)
  queue.push(job.id)
  pump()
  return job
}

function publicJob(job) {
  return {
    jobId: job.id,
    status: job.status,
    step: job.step || null,
    kind: job.kind,
    album: job.album,
    imageUrl: job.imageUrl,
    videoUrl: job.videoUrl,
    fallbackUrl: job.fallbackUrl || null,
    coverUrl: job.coverUrl || null,
    downloads: job.downloads || null,
    media: job.media || null,
    result: job.result || null,
    error: job.error || null,
    createdAt: job.createdAt,
    startedAt: job.startedAt || null,
    finishedAt: job.finishedAt || null,
  }
}

function waitForJob(job, timeoutMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + timeoutMs
    const timer = setInterval(() => {
      if (job.status === 'done' || job.status === 'failed' || Date.now() > deadline) {
        clearInterval(timer)
        resolve(job)
      }
    }, 300)
  })
}

// MARK: - HTTP 接口

let importerVersion = null

/** 读取 lpimport 的版本号（build.sh 注入），失败不影响服务启动 */
async function detectImporterVersion() {
  if (!fs.existsSync(IMPORTER)) {
    return null
  }
  try {
    const { stdout } = await run(IMPORTER, ['--version'], 15000)
    const firstLine = stdout.split('\n').map((line) => line.trim()).filter(Boolean)[0]
    return firstLine || null
  } catch (error) {
    return null
  }
}

const app = express()
app.use(express.json({ limit: '1mb' }))

app.get('/health', (req, res) => {
  res.json({
    ok: true,
    platform: process.platform,
    host: HOST,
    port: PORT,
    urls: lanUrls(PORT),
    importer: IMPORTER,
    importerExists: fs.existsSync(IMPORTER),
    importerVersion,
    ffmpeg: FFMPEG,
    album: DEFAULT_ALBUM,
    concurrency: CONCURRENCY,
    trimSeconds: TRIM_SECONDS,
    videoCodec: VIDEO_CODEC,
    stillMaxEdge: Number(process.env.STILL_MAX_EDGE || 0),
    tagContentId: TAG_CONTENT_ID,
    pairIdentifier: PAIR_IDENTIFIER,
    matchStillToVideo: MATCH_STILL_TO_VIDEO,
    running,
    queued: queue.length,
    jobs: jobs.size,
  })
})

app.post('/livephoto', async (req, res) => {
  try {
    const body = req.body || {}
    const imageUrl = ensureHttpUrl(body.imageUrl, 'imageUrl')
    const videoUrl = ensureHttpUrl(body.videoUrl, 'videoUrl')
    const job = enqueue({
      kind: 'livephoto',
      imageUrl,
      videoUrl,
      album: body.album,
      takenAt: body.takenAt,
    })
    if (body.wait === true) {
      await waitForJob(job, Number(body.waitTimeoutMs) || 180000)
      res.json(publicJob(job))
      return
    }
    res.json(publicJob(job))
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message })
  }
})

// 单张图片：由 Mac 下载后直接写入照片图库（手机不再保存任何媒体）
app.post('/import-photo', async (req, res) => {
  try {
    const body = req.body || {}
    const imageUrl = ensureHttpUrl(body.imageUrl, 'imageUrl')
    const job = enqueue({
      kind: 'photo',
      imageUrl,
      album: body.album,
      takenAt: body.takenAt,
    })
    if (body.wait === true) {
      await waitForJob(job, Number(body.waitTimeoutMs) || 180000)
      res.json(publicJob(job))
      return
    }
    res.json(publicJob(job))
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message })
  }
})

// 单个视频：由 Mac 下载后直接写入照片图库（可带封面）
app.post('/import-video', async (req, res) => {
  try {
    const body = req.body || {}
    const videoUrl = ensureHttpUrl(body.videoUrl, 'videoUrl')
    let coverUrl = null
    if (body.coverUrl) {
      coverUrl = ensureHttpUrl(body.coverUrl, 'coverUrl')
    }
    let fallbackUrl = null
    if (body.fallbackUrl) {
      fallbackUrl = ensureHttpUrl(body.fallbackUrl, 'fallbackUrl')
    }
    const job = enqueue({
      kind: 'video',
      videoUrl,
      fallbackUrl,
      coverUrl,
      album: body.album,
      takenAt: body.takenAt,
    })
    if (body.wait === true) {
      await waitForJob(job, Number(body.waitTimeoutMs) || 180000)
      res.json(publicJob(job))
      return
    }
    res.json(publicJob(job))
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message })
  }
})

// 直接给一条分享链接就能合成（复用主服务的解析逻辑，方便脱离容器/快捷指令做验证）
app.post('/livephoto/from-link', async (req, res) => {
  try {
    const body = req.body || {}
    const shareText = typeof body.shareText === 'string' ? body.shareText.trim() : ''
    if (!shareText) {
      res.status(400).json({ ok: false, error: '缺少 shareText（小红书分享文本或链接）' })
      return
    }

    let parseShare
    try {
      parseShare = require('../main')
    } catch (error) {
      res.status(501).json({
        ok: false,
        error: `无法加载主服务解析模块（${error.message}）。请先在仓库根目录执行 npm install`,
      })
      return
    }

    const result = await parseShare({ shareText, xhsCookie: body.xhsCookie }, null)
    if (result.error) {
      res.status(400).json({ ok: false, error: result.error })
      return
    }

    const targets = (result.items || []).filter(
      (item) => item.isLivePhoto && item.imageUrl && item.livePhotoVideoUrl
    )
    if (targets.length === 0) {
      res.json({
        ok: true,
        livePhotoCount: 0,
        totalItems: (result.items || []).length,
        message: '这条笔记里没有 Live Photo（items 里没有 isLivePhoto=true 的项）',
        items: result.items || [],
      })
      return
    }

    const jobs = targets.map((item) =>
      enqueue({
        kind: 'livephoto',
        imageUrl: item.imageUrl,
        videoUrl: item.livePhotoVideoUrl,
        album: body.album,
      })
    )
    if (body.wait === true) {
      const timeout = Number(body.waitTimeoutMs) || 240000
      await Promise.all(jobs.map((job) => waitForJob(job, timeout)))
    }
    res.json({
      ok: true,
      livePhotoCount: jobs.length,
      totalItems: (result.items || []).length,
      jobs: jobs.map(publicJob),
    })
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message })
  }
})

app.post('/livephoto/batch', async (req, res) => {
  try {
    const body = req.body || {}
    const items = Array.isArray(body.items) ? body.items : []
    if (items.length === 0) {
      res.status(400).json({ ok: false, error: 'items 不能为空' })
      return
    }
    const created = items.map((item) =>
      enqueue({
        imageUrl: ensureHttpUrl(item.imageUrl, 'imageUrl'),
        videoUrl: ensureHttpUrl(item.videoUrl, 'videoUrl'),
        album: item.album || body.album,
        takenAt: item.takenAt,
      })
    )
    res.json({ ok: true, jobs: created.map(publicJob) })
  } catch (error) {
    res.status(400).json({ ok: false, error: error.message })
  }
})

app.get('/jobs', (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 20, 100)
  const list = [...jobs.values()]
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .slice(0, limit)
    .map(publicJob)
  res.json({ ok: true, running, queued: queue.length, jobs: list })
})

app.get('/jobs/:id', (req, res) => {
  const job = jobs.get(req.params.id)
  if (!job) {
    res.status(404).json({ ok: false, error: 'job 不存在' })
    return
  }
  res.json(publicJob(job))
})

// 极简调试页面：可以直接粘贴小红书分享文本，或手动填「图片地址 + 视频地址」
app.get('/', (req, res) => {
  res.type('html').send(`<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>xhs-livephoto worker</title>
<style>body{font-family:-apple-system,sans-serif;max-width:640px;margin:40px auto;padding:0 16px}
input,textarea,button{width:100%;padding:8px;margin:6px 0;box-sizing:border-box}
pre{background:#f4f4f4;padding:12px;white-space:pre-wrap;word-break:break-all}</style>
</head><body>
<h3>1. 粘贴小红书分享链接（推荐）</h3>
<form id="fl">
  <textarea name="shareText" rows="3" placeholder="粘贴「复制链接」得到的分享文本，如：xxx http://xhslink.com/xxxx 复制本条信息..." required></textarea>
  <input name="album" placeholder="相簿名（默认 ${DEFAULT_ALBUM}）">
  <button>解析并合成全部 Live Photo</button>
</form>
<pre id="out1"></pre>

<h3>2. 手动填图片 + 视频地址</h3>
<form id="f">
  <input name="imageUrl" placeholder="静止帧图片地址 (jpeg/heic)" required>
  <input name="videoUrl" placeholder="Live Photo 视频地址 (mov/mp4)" required>
  <input name="album" placeholder="相簿名（默认 ${DEFAULT_ALBUM}）">
  <button>合成并写入照片图库</button>
</form>
<pre id="out2"></pre>

<script>
async function submit(url, form, out) {
  const data = Object.fromEntries(new FormData(form).entries());
  out.textContent = '提交中…';
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(data),
    });
    out.textContent = JSON.stringify(await res.json(), null, 2);
  } catch (e) {
    out.textContent = '请求失败: ' + e.message;
  }
}
document.getElementById('fl').addEventListener('submit', (e) => {
  e.preventDefault();
  submit('/livephoto/from-link', e.target, document.getElementById('out1'));
});
document.getElementById('f').addEventListener('submit', (e) => {
  e.preventDefault();
  submit('/livephoto', e.target, document.getElementById('out2'));
});
</script>
</body></html>`)
})

async function start() {
  importerVersion = await detectImporterVersion()

  app.listen(PORT, HOST, () => {
    const urls = lanUrls(PORT)
    console.info(`[xhs-livephoto] v${WORKER_VERSION} listening on ${HOST}:${PORT}`)
    console.info(
      `[xhs-livephoto] importer: ${IMPORTER} (exists=${fs.existsSync(IMPORTER)}, version=${importerVersion || 'unknown'})`
    )
    if (HOST === '0.0.0.0' || HOST === '::') {
      if (urls.length > 0) {
        console.info('[xhs-livephoto] 其他设备/容器可用的地址:')
        urls.forEach((url) => console.info(`    ${url}`))
        console.info('[xhs-livephoto] 容器里请这样配置（示例）:')
        console.info(`    -e LIVEPHOTO_WORKER_URL=${urls[0]}`)
      } else {
        console.info(
          `[xhs-livephoto] 没找到局域网 IPv4 地址；若容器和 worker 在同一台 Mac 上，可用 http://host.docker.internal:${PORT}`
        )
      }
    } else {
      console.warn(`[xhs-livephoto] 只监听 ${HOST}，容器可能访问不到；需要跨机器访问请用 HOST=0.0.0.0`)
    }
    if (process.platform !== 'darwin') {
      console.warn('[xhs-livephoto] 警告：当前不是 macOS，写入照片图库会失败（仅能用于联调转码流程）')
    }
  })
}

start().catch((error) => {
  console.error(`[xhs-livephoto] 启动失败: ${error.message}`)
  process.exit(1)
})

