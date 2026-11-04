import assert from 'node:assert/strict'
import test from 'node:test'

import { normalizeArtifacts } from '../../src/modules/session/model/artifacts.js'
import {
  buildArtifactItems,
  createAutoPreviewTracker,
  pickAutoPreviewPath,
  visibleArtifactItems
} from '../../src/modules/session/model/artifactPresentation.js'
import { isSvgPreview } from '../../src/shared/lib/file_preview.js'

const messageGroupRow = ({ key, status, run, messages = [], artifacts = [] }) => ({
  type: 'message-group',
  key,
  group: { status, run, messages },
  artifacts
})

test('交付物字符串路径保序去重', () => {
  assert.deepEqual(normalizeArtifacts([' /a.png ', '/a.png', '/b.png', '']), ['/a.png', '/b.png'])
})

test('不兼容旧交付物对象', () => {
  assert.throws(() => normalizeArtifacts([{ path: '/a.png', type: 'image' }]), TypeError)
})

test('字符串交付物倒序展示为文件项并按展开状态截断', () => {
  const items = buildArtifactItems(['/image.png', '/a.md', '/b.md', '/c.md'])

  assert.deepEqual(items, [
    { path: '/c.md', name: 'c.md' },
    { path: '/b.md', name: 'b.md' },
    { path: '/a.md', name: 'a.md' },
    { path: '/image.png', name: 'image.png' }
  ])
  assert.deepEqual(visibleArtifactItems(items, false), items.slice(0, 3))
  assert.deepEqual(visibleArtifactItems(items, true), items)
  assert.deepEqual(buildArtifactItems([]), [])
})

test('历史已完成交付不会自动打开', () => {
  const tracker = createAutoPreviewTracker()
  const rows = [
    messageGroupRow({
      key: 'history-run',
      status: 'finished',
      run: { id: 'history-run' },
      artifacts: ['/history.html']
    })
  ]

  assert.equal(pickAutoPreviewPath(rows, 'thread-a', tracker), '')
})

test('流式后同一轮完成时新交付仍自动打开', () => {
  const tracker = createAutoPreviewTracker()
  const streamingRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const finishedRow = messageGroupRow({
    key: 'run-1',
    status: 'finished',
    run: { id: 'run-1' },
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([streamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([finishedRow], 'thread-a', tracker), '/a.html')
})

test('AI 消息 run_id 在终态 Run 出现前保持运行身份', () => {
  const tracker = createAutoPreviewTracker()
  const streamingRow = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'ai', run_id: 'run-from-message' }]
  })
  const finishedRow = messageGroupRow({
    key: 'history-0',
    status: 'finished',
    run: { id: 'run-from-message' },
    messages: [{ type: 'ai', run_id: 'run-from-message' }],
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([streamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([finishedRow], 'thread-a', tracker), '/a.html')
})

test('同一路径在不同运行中都自动打开', () => {
  const tracker = createAutoPreviewTracker()
  const run1Streaming = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const run1Delivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/chart.html']
  })
  const run1Finished = messageGroupRow({
    key: 'run-1',
    status: 'finished',
    run: { id: 'run-1' },
    artifacts: ['/chart.html']
  })
  const run2Streaming = messageGroupRow({
    key: 'run-2',
    status: 'streaming',
    run: { id: 'run-2' }
  })
  const run2Delivery = messageGroupRow({
    key: 'run-2',
    status: 'streaming',
    run: { id: 'run-2' },
    artifacts: ['/chart.html']
  })

  assert.equal(pickAutoPreviewPath([run1Streaming], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([run1Delivery], 'thread-a', tracker), '/chart.html')
  assert.equal(pickAutoPreviewPath([run1Finished], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([run1Finished, run2Streaming], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([run1Finished, run2Delivery], 'thread-a', tracker), '/chart.html')
})

test('同一批多文件只打开最新一个并统一标记已处理', () => {
  const tracker = createAutoPreviewTracker()
  const streamingRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const deliveredRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/r.html', '/c.svg']
  })

  assert.equal(pickAutoPreviewPath([streamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([deliveredRow], 'thread-a', tracker), '/c.svg')
  assert.equal(pickAutoPreviewPath([deliveredRow], 'thread-a', tracker), '')
})

test('关闭后不重开旧交付且能打开后续新文件', () => {
  const tracker = createAutoPreviewTracker()
  const streamingRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const firstDelivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/a.html']
  })
  const laterDelivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/a.html', '/d.svg']
  })

  assert.equal(pickAutoPreviewPath([streamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([firstDelivery], 'thread-a', tracker), '/a.html')
  assert.equal(pickAutoPreviewPath([firstDelivery], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([laterDelivery], 'thread-a', tracker), '/d.svg')
})

test('本地发送后同帧出现 AI 身份和交付仍自动打开', () => {
  const tracker = createAutoPreviewTracker()
  const anonymousStreamingRow = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'human' }]
  })
  const identifiedDelivery = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'human' }, { type: 'ai', run_id: 'run-1' }],
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([anonymousStreamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([identifiedDelivery], 'thread-a', tracker), '/a.html')
})

test('本地发送后直接收到终态交付仍自动打开', () => {
  const tracker = createAutoPreviewTracker()
  const anonymousStreamingRow = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'human' }]
  })
  const finishedDelivery = messageGroupRow({
    key: 'run-1',
    status: 'finished',
    run: { id: 'run-1' },
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([anonymousStreamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([finishedDelivery], 'thread-a', tracker), '/a.html')
})

test('草稿线程切换到新线程时保留本地运行状态', () => {
  const tracker = createAutoPreviewTracker()
  const anonymousStreamingRow = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'human' }]
  })
  const identifiedDelivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([anonymousStreamingRow], null, tracker), '')
  assert.equal(pickAutoPreviewPath([identifiedDelivery], 'thread-new', tracker), '/a.html')
})

test('本地运行等待身份期间不继承给较早历史行', () => {
  const tracker = createAutoPreviewTracker()
  const olderHistory = messageGroupRow({
    key: 'old',
    status: 'finished',
    run: { id: 'old' },
    artifacts: ['/old.html']
  })
  const anonymousStreamingRow = messageGroupRow({
    key: 'ongoing-message-group',
    status: 'streaming',
    messages: [{ type: 'human' }]
  })
  const newRunDelivery = messageGroupRow({
    key: 'run-new',
    status: 'streaming',
    run: { id: 'run-new' },
    artifacts: ['/n.svg']
  })

  assert.equal(pickAutoPreviewPath([anonymousStreamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([olderHistory, anonymousStreamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([olderHistory, newRunDelivery], 'thread-a', tracker), '/n.svg')
})

test('本地发送被拒后续跑不重开旧交付', () => {
  const tracker = createAutoPreviewTracker()
  const run1Streaming = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const run1Delivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/a.html']
  })
  const run1Finished = messageGroupRow({
    key: 'run-1',
    status: 'finished',
    run: { id: 'run-1' },
    messages: [{ type: 'ai', run_id: 'run-1' }],
    artifacts: ['/a.html']
  })
  const anonymousStreamingRow = messageGroupRow({
    key: 'optimistic-local-send',
    status: 'streaming',
    messages: [{ type: 'human' }]
  })
  const resumedRun = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-2' },
    messages: [{ type: 'ai', run_id: 'run-1' }, { type: 'ai', run_id: 'run-2' }],
    artifacts: ['/a.html']
  })

  assert.equal(pickAutoPreviewPath([run1Streaming], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([run1Delivery], 'thread-a', tracker), '/a.html')
  assert.equal(pickAutoPreviewPath([run1Finished], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([anonymousStreamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([run1Finished], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([resumedRun], 'thread-a', tracker), '')
})

test('刷新后首次观察流式运行会基线已有交付', () => {
  const tracker = createAutoPreviewTracker()
  const existingDelivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/old.html']
  })
  const newDelivery = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/old.html', '/new.svg']
  })

  assert.equal(pickAutoPreviewPath([existingDelivery], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([existingDelivery], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([newDelivery], 'thread-a', tracker), '/new.svg')
})

test('切换线程 A 到 B 时重置追踪', () => {
  const tracker = createAutoPreviewTracker()
  const threadARow = messageGroupRow({
    key: 'run-a',
    status: 'streaming',
    run: { id: 'run-a' },
    artifacts: ['/a.html']
  })
  const threadBRows = [
    messageGroupRow({ key: 'run-b', status: 'streaming', run: { id: 'run-b' } }),
    messageGroupRow({
      key: 'run-b',
      status: 'finished',
      run: { id: 'run-b' },
      artifacts: ['/a.html']
    })
  ]

  assert.equal(pickAutoPreviewPath([threadARow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath(threadBRows, 'thread-b', tracker), '/a.html')
})

test('提示行不参与自动预览', () => {
  const tracker = createAutoPreviewTracker()

  assert.equal(
    pickAutoPreviewPath(
      [{ type: 'notice', key: 'notice-1', artifacts: ['/notice.html'] }],
      'thread-a',
      tracker
    ),
    ''
  )
})

test('HTM 和 SVG 扩展名大小写不敏感', () => {
  const tracker = createAutoPreviewTracker()
  const streamingRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' }
  })
  const deliveredRow = messageGroupRow({
    key: 'run-1',
    status: 'streaming',
    run: { id: 'run-1' },
    artifacts: ['/report.HTM', '/chart.SVG']
  })

  assert.equal(pickAutoPreviewPath([streamingRow], 'thread-a', tracker), '')
  assert.equal(pickAutoPreviewPath([deliveredRow], 'thread-a', tracker), '/chart.SVG')
})

test('SVG 预览扩展名大小写不敏感', () => {
  assert.equal(isSvgPreview('/charts/graph.svg'), true)
  assert.equal(isSvgPreview('/charts/graph.SVG'), true)
  assert.equal(isSvgPreview('/charts/graph.png'), false)
})
