const test = require('node:test')
const assert = require('node:assert')

const { buildItems, extractPicId, findNote } = require('../main')

function makeImageItem(picId, liveVideoUrl) {
  const item = {
    infoList: [
      { url: `https://sns-webpic-qc.xhscdn.com/202409/abc123/${picId}!nd_dft_wlteh_webp_3` },
    ],
    urlDefault: `https://sns-webpic-qc.xhscdn.com/202409/abc123/${picId}!nd_prv_wlteh_webp_3`,
  }
  if (liveVideoUrl) {
    item.stream = { h264: [{ masterUrl: liveVideoUrl }] }
  }
  return item
}

test('findNote 兼容移动版 / 桌面版两种页面结构', () => {
  const mobile = { noteData: { data: { noteData: { imageList: [{}, {}] } } } }
  const desktop = { note: { firstNoteId: 'n1', noteDetailMap: { n1: { note: { imageList: [{}] } } } } }
  assert.equal(findNote(mobile).imageList.length, 2)
  assert.equal(findNote(desktop).imageList.length, 1)
  assert.equal(findNote({}), null)
  assert.equal(findNote(undefined), null)
})

test('extractPicId 兼容 sns-webpic 地址与兜底规则', () => {
  assert.equal(extractPicId(makeImageItem('1040g2t0abc')), '1040g2t0abc')
  assert.equal(
    extractPicId({ urlDefault: 'https://ci.xiaohongshu.com/1040g00831abcdefg?imageView2/2/w/1080' }),
    '1040g00831abcdefg'
  )
  assert.equal(extractPicId({}), null)
})

test('buildItems 保留图片与 Live Photo 视频的配对关系（原图 URL）', () => {
  const imageList = [
    makeImageItem('1040g2t0aaa', 'https://sns-video-hw.xhscdn.com/live-1.mov'),
    makeImageItem('1040g2t0bbb'),
    makeImageItem('1040g2t0ccc', 'https://sns-video-hw.xhscdn.com/live-3.mov'),
  ]
  const note = {}

  const { picUrlArray, items } = buildItems(imageList, note)

  assert.equal(items.length, 3)
  assert.deepEqual(
    items.map((item) => item.isLivePhoto),
    [true, false, true]
  )
  assert.equal(items[0].livePhotoVideoUrl, 'https://sns-video-hw.xhscdn.com/live-1.mov')
  assert.equal(items[1].livePhotoVideoUrl, null)
  assert.equal(items[2].imageUrl, 'https://ci.xiaohongshu.com/1040g2t0ccc')
  assert.equal(items[2].originalUrl, 'https://ci.xiaohongshu.com/1040g2t0ccc')

  // 与上游一致：先所有图片，再所有 Live Photo 视频
  assert.deepEqual(picUrlArray, [
    'https://ci.xiaohongshu.com/1040g2t0aaa',
    'https://ci.xiaohongshu.com/1040g2t0bbb',
    'https://ci.xiaohongshu.com/1040g2t0ccc',
    'https://sns-video-hw.xhscdn.com/live-1.mov',
    'https://sns-video-hw.xhscdn.com/live-3.mov',
  ])
})

test('buildItems 支持视频笔记，并把视频追加在末尾（含 streamType 兜底）', () => {
  const imageList = [makeImageItem('1040g2t0aaa')]
  const note = {
    video: {
      media: {
        video: { streamTypes: [1] },
        stream: {
          h264: [
            { streamType: 1, masterUrl: 'https://sns-video-hw.xhscdn.com/note-video.mp4' },
            { streamType: 2, masterUrl: 'https://sns-video-hw.xhscdn.com/other.mp4' },
          ],
        },
      },
    },
  }

  const { picUrlArray, items } = buildItems(imageList, note)

  assert.equal(items.length, 2)
  assert.equal(items[1].type, 'video')
  assert.equal(items[1].videoUrl, 'https://sns-video-hw.xhscdn.com/note-video.mp4')
  assert.equal(picUrlArray[picUrlArray.length - 1], 'https://sns-video-hw.xhscdn.com/note-video.mp4')
})

test('buildItems 在没有匹配 streamType 时回退到可用编码', () => {
  const note = {
    video: {
      media: {
        video: { streamTypes: [9] },
        stream: { h265: [{ streamType: 4, masterUrl: 'https://sns-video-hw.xhscdn.com/h265.mp4' }] },
      },
    },
  }
  const { picUrlArray } = buildItems([], note)
  assert.deepEqual(picUrlArray, ['https://sns-video-hw.xhscdn.com/h265.mp4'])
})

test('buildItems 优先 h264，缺 h264 时退回其它编码', () => {
  const h264List = [
    {
      infoList: [{ url: 'https://sns-webpic-qc.xhscdn.com/202409/abc123/1040g2t0aaa!x' }],
      stream: {
        h264: [{ masterUrl: 'https://sns-video-hw.xhscdn.com/h264.mp4' }],
        h265: [{ masterUrl: 'https://sns-video-hw.xhscdn.com/h265.mp4' }],
      },
    },
    {
      infoList: [{ url: 'https://sns-webpic-qc.xhscdn.com/202409/abc123/1040g2t0bbb!x' }],
      stream: { h265: [{ masterUrl: 'https://sns-video-hw.xhscdn.com/only-h265.mp4' }] },
    },
  ]

  const { items } = buildItems(h264List, {})

  assert.equal(items[0].livePhotoVideoUrl, 'https://sns-video-hw.xhscdn.com/h264.mp4')
  assert.equal(items[1].livePhotoVideoUrl, 'https://sns-video-hw.xhscdn.com/only-h265.mp4')
})

test('buildItems 视频优先使用 originVideoKey，并把最高码率流作为兜底', () => {
  const note = {
    type: 'video',
    imageList: [makeImageItem('1040g2t0cover')],
    video: {
      consumer: { originVideoKey: 'pre_post/110/abc123' },
      media: {
        video: { streamTypes: [1] },
        stream: {
          h264: [
            { streamType: 1, masterUrl: 'https://sns-video-hw.xhscdn.com/low.mp4', videoBitrate: 400000 },
          ],
          h265: [
            { streamType: 2, masterUrl: 'https://sns-video-hw.xhscdn.com/mid.mp4', videoBitrate: 2000000 },
          ],
        },
      },
    },
  }

  const { items } = buildItems(note.imageList, note)
  const videoItem = items.find((item) => item.type === 'video')

  assert.equal(videoItem.videoUrl, 'https://sns-video-bd.xhscdn.com/pre_post/110/abc123')
  assert.equal(videoItem.videoSource, 'origin')
  assert.equal(videoItem.videoFallbackUrl, 'https://sns-video-hw.xhscdn.com/mid.mp4')
})

test('buildItems 没有 originVideoKey 时选码率最高的流', () => {
  const note = {
    type: 'video',
    imageList: [makeImageItem('1040g2t0cover')],
    video: {
      media: {
        video: { streamTypes: [1] },
        stream: {
          h264: [
            { streamType: 1, masterUrl: 'https://sns-video-hw.xhscdn.com/low.mp4', videoBitrate: 400000 },
            { streamType: 2, masterUrl: 'https://sns-video-hw.xhscdn.com/high.mp4', videoBitrate: 4000000 },
          ],
        },
      },
    },
  }

  const { items } = buildItems(note.imageList, note)
  const videoItem = items.find((item) => item.type === 'video')

  assert.equal(videoItem.videoUrl, 'https://sns-video-hw.xhscdn.com/high.mp4')
  assert.equal(videoItem.videoSource, 'stream')
})

test('buildItems 视频笔记的封面被标记 isVideoCover，并挂到视频 item 上', () => {
  const note = {
    type: 'video',
    imageList: [makeImageItem('1040g2t0cover')],
    video: {
      media: {
        video: { streamTypes: [1] },
        stream: { h264: [{ streamType: 1, masterUrl: 'https://sns-video-hw.xhscdn.com/v.mp4' }] },
      },
    },
  }

  const { items } = buildItems(note.imageList, note)

  assert.equal(items[0].isVideoCover, true)
  assert.equal(items[1].type, 'video')
  assert.equal(items[1].coverUrl, 'https://ci.xiaohongshu.com/1040g2t0cover')
})

test('buildItems 的 Live Photo 笔记不再额外产出 note.video', () => {
  const note = {
    type: 'normal',
    imageList: [makeImageItem('1040g2t0live', 'https://sns-video-hw.xhscdn.com/live.mov')],
    video: {
      media: {
        video: { streamTypes: [1] },
        stream: { h264: [{ streamType: 1, masterUrl: 'https://sns-video-hw.xhscdn.com/bgm.mp4' }] },
      },
    },
  }

  const { items, picUrlArray } = buildItems(note.imageList, note)

  assert.equal(items.filter((item) => item.type === 'video').length, 0)
  assert.deepEqual(picUrlArray, [
    'https://ci.xiaohongshu.com/1040g2t0live',
    'https://sns-video-hw.xhscdn.com/live.mov',
  ])
})

test('buildItems：type=video 但含 Live Photo 的笔记不产出幻灯片视频，也不标记封面', () => {
  const note = {
    type: 'video',
    imageList: [
      makeImageItem('1040g2t0live1', 'https://sns-video-hw.xhscdn.com/live1.mov'),
      makeImageItem('1040g2t0live2', 'https://sns-video-hw.xhscdn.com/live2.mov'),
    ],
    video: {
      consumer: {
        originVideoKey: 'slides_simulate_post/1040g3l8327j6dkn3ng005ofd4nhk0ki6oh8c280',
      },
      media: {
        video: { streamTypes: [259] },
        stream: { h264: [{ streamType: 259, masterUrl: 'https://sns-video-hw.xhscdn.com/slides.mp4' }] },
      },
    },
  }

  const { items } = buildItems(note.imageList, note)

  assert.equal(items.length, 2)
  assert.equal(items.some((item) => item.type === 'video'), false)
  assert.equal(items.every((item) => item.isLivePhoto && item.isVideoCover === false), true)
})

test('buildItems：只有 slides 自动合成视频且无 Live Photo 时，封面仍按普通图片处理', () => {
  const note = {
    type: 'video',
    imageList: [makeImageItem('1040g2t0cover')],
    video: {
      consumer: { originVideoKey: 'slides_simulate_post/xxx' },
      media: {
        video: { streamTypes: [259] },
        stream: { h264: [{ streamType: 259, masterUrl: 'https://sns-video-hw.xhscdn.com/slides.mp4' }] },
      },
    },
  }

  const { items } = buildItems(note.imageList, note)

  assert.equal(items.length, 1)
  assert.equal(items[0].isVideoCover, false)
  assert.equal(items[0].isLivePhoto, false)
})

test('buildItems 容忍空 imageList / 无 note.video', () => {
  assert.deepEqual(buildItems([], {}), { picUrlArray: [], items: [] })
  assert.deepEqual(buildItems(undefined, undefined), { picUrlArray: [], items: [] })
})
