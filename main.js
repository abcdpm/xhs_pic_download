const axios = require('axios')
const cheerio = require('cheerio');

// 只请求小红书的域名，避免服务被用来访问任意地址（SSRF）
const ALLOWED_HOSTS = /(^|\.)(xhslink\.(com|cn)|xiaohongshu\.com)$/i
function assertAllowed(url) {
  const u = new URL(url)
  if (!/^https?:$/.test(u.protocol) || !ALLOWED_HOSTS.test(u.hostname)) {
    throw new Error('只支持小红书链接')
  }
  return u.toString()
}
const REQUEST_OPTIONS = {
  timeout: 15000,
  maxContentLength: 5 * 1024 * 1024,
  beforeRedirect: (options) => {
    if (!ALLOWED_HOSTS.test(options.hostname)) {
      throw new Error('不允许跳转到非小红书域名')
    }
  },
}

module.exports = async function (params, context) {
  const shareText = params['shareText']
  const xhsCookie = params['xhsCookie']
  if (!shareText) {
    return {
      error: '缺少shareText参数',
    }
  }

  console.log(`shareText->${shareText}`)
  const fullUrl = await getFullURL(shareText)
  console.log(`fullUrl->${fullUrl}`)

  const result = await getPicUrl(fullUrl, xhsCookie)
  return {
    picUrlArray: result.picUrlArray,
    // 结构化结果：保留「图片 <-> Live Photo 视频」的配对关系，供 Live Photo 合成使用
    items: result.items,
  }
}

async function getHeaders() {
  // 桌面版 UA 现在会被重定向到登录页，移动版（iPhone Safari）页面仍可匿名访问
  return {
    "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "accept-language": "zh-CN,zh-Hans;q=0.9",
    "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
  }
}

async function getFullURL(shortURLWithText) {
  const headers = await getHeaders()
  // 正则表达式提取url
  const urlRegex = /(http[s]?:\/\/[^\s，]+)/;
  const match = shortURLWithText.match(urlRegex)
  if (!match) {
    throw new Error('shareText中没有找到链接')
  }
  const shortURL = assertAllowed(match[0]);
  try {
    const response = await axios.get(shortURL, {
      headers,
      ...REQUEST_OPTIONS,
      maxRedirects: 0
    })
    return shortURL
  } catch (error) {
    if (!error.response || !error.response.headers.location) {
      throw error
    }
    return assertAllowed(new URL(error.response.headers.location, shortURL).toString())
  }
}

async function findDom(htmlContent) {
  const $ = cheerio.load(htmlContent);

  let initialStateScript;
  $('script').each((index, script) => {
    const scriptContent = $(script).html();
    if (scriptContent && scriptContent.includes('window.__INITIAL_STATE__')) {
      initialStateScript = scriptContent;
    }
  });

  // 提取window.__INITIAL_STATE__的值
  let initialState;
  if (initialStateScript) {
    const startIndex = initialStateScript.indexOf('{');
    const endIndex = initialStateScript.lastIndexOf('}');

    if (startIndex !== -1 && endIndex !== -1) {
      const jsonString = initialStateScript.substring(startIndex, endIndex + 1);
      // 不能用 eval 执行远程内容；该对象除了值为 undefined 的字段外就是合法 JSON
      initialState = JSON.parse(jsonString.replace(/([:\[,])\s*undefined(?=\s*[,}\]])/g, '$1null'));
    }
  }
  return initialState
}

async function getPicUrl(fullUrl, xhsCookie) {
  const headers = await getHeaders()
  if (xhsCookie) {
    headers['cookie'] = xhsCookie
  }
  const response = await axios.get(assertAllowed(fullUrl), {
    headers,
    ...REQUEST_OPTIONS,
    maxRedirects: 3
  })
  const responseData = response.data
  const resultObj = await findDom(responseData)

  let note = null
  let imageList = []
  try {
    // 兼容桌面版页面结构和移动版页面结构（state.noteData.data.noteData）
    note = findNote(resultObj)
    if (!note) {
      throw new Error('未找到笔记（需要登录或笔记已删除）')
    }
    imageList = note?.imageList || []
  } catch (error) {
    console.log(error)
    throw new Error('不包含图片')
  }
  return buildItems(imageList, note)
}

/**
 * 从 window.__INITIAL_STATE__ 中取出笔记对象。
 * 移动版页面（iPhone UA 请求）把笔记放在 state.noteData.data.noteData，
 * 桌面版页面放在 state.note.noteDetailMap[firstNoteId].note。
 */
function findNote(resultObj) {
  return (
    resultObj?.note?.noteDetailMap?.[resultObj?.note?.firstNoteId]?.note ||
    resultObj?.noteData?.data?.noteData ||
    null
  )
}

const PIC_ID_REGEX = /https?:\/\/sns-webpic-qc\.xhscdn\.com\/\d+\/[0-9a-z]+\/(\S+)!/
// 兜底：取最后一个路径片段（去掉 ! / ? 后缀）
const FALLBACK_PIC_ID_REGEX = /\/([0-9a-z]{10,})(?:[!?]|$)/i
const CDN_IMAGE_HOST = 'https://ci.xiaohongshu.com'
// 原始上传视频的 CDN（originVideoKey 指向它，通常无水印、画质最高）
const ORIGIN_VIDEO_HOST = 'https://sns-video-bd.xhscdn.com'

/**
 * 从小红书图片地址中抠出 picId。优先 infoList[0].url（桌面/移动页面都是主图地址），
 * 再退回 urlDefault，最后按路径兜底，避免个别笔记缺少 infoList 时整篇失败。
 */
function extractPicId(imageItem) {
  const urls = []
  if (imageItem?.infoList?.[0]?.url) {
    urls.push(imageItem.infoList[0].url)
  }
  if (imageItem?.urlDefault) {
    urls.push(imageItem.urlDefault)
  }
  for (const url of urls) {
    const match = String(url).match(PIC_ID_REGEX)
    if (match && match[1]) {
      return match[1]
    }
  }
  for (const url of urls) {
    const match = String(url).match(FALLBACK_PIC_ID_REGEX)
    if (match && match[1]) {
      return match[1]
    }
  }
  return null
}

/**
 * 挑选视频源：
 * 1) 优先 `note.video.consumer.originVideoKey`（原始上传，通常无水印、画质最高）；
 * 2) 同时给出网页流里码率最高的一条作为兜底（原片取不到时自动回退）。
 */
function pickVideo(note) {
  const bestStream = pickBestStream(note)
  const originKey = note?.video?.consumer?.originVideoKey
  if (typeof originKey === 'string' && originKey.trim()) {
    return {
      url: `${ORIGIN_VIDEO_HOST}/${originKey.trim()}`,
      source: 'origin',
      fallbackUrl: bestStream ? bestStream.url : null,
    }
  }
  return bestStream
}

/** 在 media.stream 的所有变体里挑码率最高的一条 */
function pickBestStream(note) {
  const media = note?.video?.media
  if (!media) {
    return null
  }
  const candidates = []
  Object.entries(media.stream || {}).forEach(([codec, list]) => {
    if (!Array.isArray(list)) {
      return
    }
    list.forEach((entry) => {
      if (!entry || !entry.masterUrl) {
        return
      }
      const bitrate =
        Number(entry.videoBitrate || entry.avgBitrate || 0) || Number(entry.size || 0) * 8
      candidates.push({
        url: entry.masterUrl,
        codec,
        bitrate,
        height: Number(entry.height || 0),
      })
    })
  })
  if (candidates.length === 0) {
    return null
  }
  candidates.sort((a, b) => b.bitrate - a.bitrate || b.height - a.height)
  const best = candidates[0]
  return { url: best.url, source: 'stream', codec: best.codec, bitrate: best.bitrate }
}

/**
 * 把 note.imageList 转换成结构化 items，同时生成与上游完全一致的扁平 picUrlArray。
 *
 * items[i] = {
 *   index,
 *   type: 'image' | 'video',
 *   imageUrl,          // 原图（https://ci.xiaohongshu.com/<picId>，不再带 imageView2 参数）
 *   livePhotoVideoUrl, // 该图关联的 Live Photo 视频，没有则为 null
 *   isLivePhoto,
 * }
 */
/**
 * 从 imageList[i].stream 里挑一个最合适的实况视频流：
 * 优先 h264，没有就依次退回 h265 / av1 / h266。
 */
function pickLivePhotoStream(imageItem) {
  const stream = imageItem?.stream || {}
  for (const codec of ['h264', 'h265', 'av1', 'h266']) {
    const list = stream[codec]
    if (!Array.isArray(list)) {
      continue
    }
    const entry = list.find((item) => item && item.masterUrl)
    if (entry) {
      return entry
    }
  }
  return null
}

function buildItems(imageList, note) {
  const items = []
  const picUrlArray = []
  const list = Array.isArray(imageList) ? imageList : []
  const isVideoNote = String(note?.type || '').toLowerCase() === 'video'

  const liveStreams = list.map((item) => pickLivePhotoStream(item))
  const hasLivePhoto = liveStreams.some((stream) => Boolean(stream && stream.masterUrl))

  // 视频：优先原始上传（无水印/最高画质）。
  // 只要笔记里有 Live Photo，就不产出 note.video —— XHS 会为实况笔记自动合成一条
  // 「幻灯片视频」（originVideoKey 形如 slides_simulate_post/...，带 BGM），不是用户要的。
  const slidesVideo = /^slides[_-]?simulate/i.test(
    String(note?.video?.consumer?.originVideoKey || '')
  )
  const shouldIncludeVideo = !hasLivePhoto && !slidesVideo
  const video = shouldIncludeVideo ? pickVideo(note) : null
  // 只有「确实要产出视频」时，imageList[0] 才作为封面（否则封面会被跳过导致丢图）
  const isCoverNote = isVideoNote && Boolean(video)

  list.forEach((imageItem, position) => {
    const picId = extractPicId(imageItem)
    const liveStream = liveStreams[position]
    const livePhotoVideoUrl = liveStream ? liveStream.masterUrl : null
    if (!picId && !livePhotoVideoUrl) {
      return
    }
    const imageUrl = picId ? `${CDN_IMAGE_HOST}/${picId}` : null
    if (imageUrl) {
      picUrlArray.push(imageUrl)
    }
    items.push({
      index: items.length,
      type: 'image',
      imageUrl,
      originalUrl: imageUrl,
      livePhotoVideoUrl,
      isLivePhoto: Boolean(livePhotoVideoUrl),
      // 视频笔记的 imageList[0] 就是视频封面：不再单独存成照片，改为写进视频
      isVideoCover: isCoverNote && position === 0,
    })
  })

  // 兼容旧行为：Live Photo 视频仍然追加在图片之后
  items.forEach((item) => {
    if (item.livePhotoVideoUrl) {
      picUrlArray.push(item.livePhotoVideoUrl)
    }
  })

  // 视频：优先原始上传（无水印/最高画质）
  if (video) {
    picUrlArray.push(video.url)
    const coverItem = isCoverNote ? items.find((item) => item.isVideoCover) : null
    items.push({
      index: items.length,
      type: 'video',
      videoUrl: video.url,
      // 原片取不到时回退到网页最高码率流
      videoFallbackUrl: video.fallbackUrl || null,
      videoSource: video.source || 'stream',
      videoCodec: video.codec || null,
      videoBitrate: video.bitrate || null,
      // 视频封面（视频笔记的 imageList[0]），由 worker 写进视频而不是单独存成照片
      coverUrl: coverItem ? coverItem.imageUrl : null,
      isLivePhoto: false,
    })
  }

  return { picUrlArray, items }
}

module.exports.buildItems = buildItems
module.exports.extractPicId = extractPicId
module.exports.findNote = findNote
module.exports.findDom = findDom
module.exports.pickLivePhotoStream = pickLivePhotoStream