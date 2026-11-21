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

test('buildItems 容忍空 imageList / 无 note.video', () => {
  assert.deepEqual(buildItems([], {}), { picUrlArray: [], items: [] })
  assert.deepEqual(buildItems(undefined, undefined), { picUrlArray: [], items: [] })
})
