import { normalizeArtifacts } from './artifacts.js'
import { isHtmlPreview, isSvgPreview } from '../../../shared/lib/file_preview.js'
import { getMessageRunId } from './messageDebug.js'

/** 创建自动预览跟踪状态。 */
export function createAutoPreviewTracker() {
  return {
    threadId: undefined,
    knownRunIds: new Set(),
    liveRunIds: new Set(),
    seenPathsByRun: new Map(),
    pendingLocalRun: false
  }
}

/** 返回本次应自动打开的最新 HTML/SVG 交付物路径，没有则返回空串。 */
export function pickAutoPreviewPath(rows, threadId, tracker) {
  if (tracker.threadId !== threadId) {
    // 草稿会话转为新线程时仍是同一段对话，保留本地发送状态。
    if (tracker.threadId) {
      tracker.knownRunIds.clear()
      tracker.liveRunIds.clear()
      tracker.seenPathsByRun.clear()
      tracker.pendingLocalRun = false
    }
    tracker.threadId = threadId
  }

  const groupRows = rows.filter((row) => row.type === 'message-group')
  let picked = ''
  let hasAnonymousStreamingRow = false
  groupRows.forEach((row, index) => {
    const runId = row.group.run?.id || row.group.messages?.map(getMessageRunId).find(Boolean) || ''
    const streaming = row.group.status === 'streaming'
    const candidates = normalizeArtifacts(row.artifacts).filter(
      (path) => isHtmlPreview(path) || isSvgPreview(path)
    )

    if (!runId) {
      if (streaming) {
        hasAnonymousStreamingRow = true
        tracker.pendingLocalRun = true
      }
      return
    }

    if (!tracker.knownRunIds.has(runId)) {
      tracker.knownRunIds.add(runId)
      const isLast = index === groupRows.length - 1
      if (tracker.pendingLocalRun && isLast) {
        // 本地发送的无身份运行继承新身份，不把同帧交付物当作基线。
        tracker.pendingLocalRun = false
        tracker.liveRunIds.add(runId)
        tracker.seenPathsByRun.set(runId, new Set())
      } else if (streaming) {
        // 首次观察时已在运行的会话以已有交付物为基线。
        tracker.liveRunIds.add(runId)
        tracker.seenPathsByRun.set(runId, new Set(candidates))
        return
      } else {
        return
      }
    }
    if (!tracker.liveRunIds.has(runId)) return

    const seen = tracker.seenPathsByRun.get(runId)
    const fresh = candidates.filter((path) => !seen.has(path))
    candidates.forEach((path) => seen.add(path))
    if (fresh.length) picked = fresh.at(-1)
  })

  if (!hasAnonymousStreamingRow) tracker.pendingLocalRun = false

  return picked
}

/** 交付路径倒序展示为文件项，保持原始字符串路径的稳定身份。 */
export function buildArtifactItems(artifacts) {
  return normalizeArtifacts(artifacts)
    .reverse()
    .map((path) => ({ path, name: path.split('/').pop() || path }))
}

/** 折叠时只展示前三项，展开时展示全部。 */
export function visibleArtifactItems(items, expanded) {
  return expanded ? items : items.slice(0, 3)
}
