#!/usr/bin/env node
/**
 * 探查一条小红书笔记的原始字段，用于确认「声音从哪来」。
 *
 * 用法（在仓库根目录已 npm install 的前提下）：
 *   node livephoto/inspect-note.js "https://xhslink.cn/o/xxxx"
 *   node livephoto/inspect-note.js "复制粘贴整段分享文本"
 *
 * 关注输出里的：
 *   - note keys / music·audio·bgm：笔记是否有独立背景音乐字段
 *   - image[i].stream.*：实况视频流里有没有音频相关地址
 */
const axios = require('axios')
const { findDom, findNote } = require('../main')

const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1'

function preview(value, limit = 600) {
  try {
    const text = typeof value === 'string' ? value : JSON.stringify(value)
    return text && text.length > limit ? `${text.slice(0, limit)}…` : text
  } catch (error) {
    return String(value)
  }
}

async function main() {
  const share = process.argv.slice(2).join(' ').trim()
  if (!share) {
    console.error('用法: node livephoto/inspect-note.js "<小红书分享文本或链接>"')
    process.exit(2)
  }
  const matched = share.match(/https?:\/\/[^\s，]+/)
  if (!matched) {
    console.error('没在参数里找到链接')
    process.exit(2)
  }

  let url = matched[0]
  if (/xhslink/i.test(url)) {
    const redirect = await axios.get(url, {
      headers: { 'user-agent': UA },
      maxRedirects: 0,
      validateStatus: () => true,
    })
    if (redirect.headers.location) {
      url = redirect.headers.location
    }
  }
  console.log('note url:', url)

  const response = await axios.get(url, { headers: { 'user-agent': UA } })
  // 复用主服务的解析（会处理 XHS 里非法的 undefined）
  const state = await findDom(response.data)
  if (!state) {
    console.error('页面里没解析到 window.__INITIAL_STATE__')
    process.exit(1)
  }

  const note = findNote(state)
  if (!note) {
    console.error('页面结构里没找到 note（可能需要登录或笔记已删除）')
    process.exit(1)
  }

  console.log('\n== note 顶层字段 ==')
  console.log(Object.keys(note).join(', '))

  for (const key of ['music', 'audio', 'bgm', 'sound', 'video']) {
    if (note[key]) {
      console.log(`\n== note.${key} ==`)
      console.log(preview(note[key], 1200))
    }
  }

  // 视频笔记：把所有画质变体列出来（判断是否有更高清/无水印的一路）
  const videoStream = note.video?.media?.stream
  if (videoStream) {
    console.log('\n== note.video.media.stream（全部变体）==')
    for (const [codec, list] of Object.entries(videoStream)) {
      if (!Array.isArray(list)) continue
      list.forEach((entry, i) => {
        if (!entry) return
        console.log(
          `  ${codec}[${i}]: streamType=${entry.streamType} streamDesc=${entry.streamDesc || '-'}` +
            ` ${entry.width}x${entry.height} videoBitrate=${entry.videoBitrate}` +
            ` avgBitrate=${entry.avgBitrate} quality=${entry.qualityType || '-'}` +
            ` audioBitrate=${entry.audioBitrate} size=${entry.size}`
        )
      })
    }
  }

  // 有的笔记把视频信息塞在 mediaV2（JSON 字符串）里
  if (typeof note.video?.mediaV2 === 'string') {
    try {
      const mediaV2 = JSON.parse(note.video.mediaV2)
      console.log('\n== note.video.mediaV2.streamTypes ==', JSON.stringify(mediaV2.video?.stream_types))
      const streams = mediaV2.stream || {}
      for (const [codec, list] of Object.entries(streams)) {
        if (!Array.isArray(list)) continue
        list.forEach((entry, i) => {
          if (!entry) return
          console.log(
            `  mediaV2.${codec}[${i}]: streamType=${entry.stream_type} desc=${entry.stream_desc}` +
              ` ${entry.width}x${entry.height} bitrate=${entry.video_bitrate}`
          )
        })
      }
    } catch (error) {
      console.log('  (mediaV2 解析失败:', error.message, ')')
    }
  }
  if (note.video?.consumer?.originVideoKey) {
    const originKey = String(note.video.consumer.originVideoKey).trim()
    console.log('\n== note.video.consumer.originVideoKey ==', originKey)
    console.log('== 原始视频地址（可直接 curl -I 验证）==')
    console.log(`   https://sns-video-bd.xhscdn.com/${originKey}`)
  }

  const images = Array.isArray(note.imageList) ? note.imageList : []
  images.forEach((item, index) => {
    console.log(`\n== imageList[${index}] ==`)
    console.log('keys:', Object.keys(item).join(', '))

    if (item.livePhoto) {
      console.log('livePhoto:', preview(item.livePhoto, 2000))
    }

    const streams = item.stream || {}
    for (const [codec, list] of Object.entries(streams)) {
      if (!Array.isArray(list)) {
        console.log(`stream.${codec}:`, preview(list))
        continue
      }
      list.forEach((entry, i) => {
        if (!entry) {
          console.log(`stream.${codec}[${i}]: null`)
          return
        }
        console.log(
          `stream.${codec}[${i}]: streamDesc=${entry.streamDesc || '-'}` +
            ` audioCodec=${entry.audioCodec || '-'}` +
            ` audioBitrate=${entry.audioBitrate}` +
            ` audioDuration=${entry.audioDuration}` +
            ` volume=${entry.volume}` +
            ` size=${entry.size}`
        )
        if (entry.masterUrl) {
          console.log('    masterUrl:', entry.masterUrl)
        }
      })
    }

    for (const key of Object.keys(item)) {
      if (/audio|music|sound|volume/i.test(key)) {
        console.log(`${key}:`, preview(item[key], 1000))
      }
    }
  })
}

main().catch((error) => {
  console.error('ERR', error.message)
  process.exit(1)
})
