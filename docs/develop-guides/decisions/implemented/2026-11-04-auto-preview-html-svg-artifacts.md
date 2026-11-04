# HTML/SVG 交付物自动打开预览

状态：implemented
类型：feature
Owner：frontend/src/modules/session/model/artifactPresentation.js

## 问题

Agent 交付 HTML 页面或 SVG 图表后，用户仍需从文件列表手动打开。SVG 当前以图片 Blob URL 预览，且 HTML 源码没有语法高亮。

## 决策

### 实现方案

`artifactPresentation.js` 的纯函数管理已知运行、活动运行和自动预览选择。已处理路径按运行分别记录，因此新运行再次交付相同路径仍会打开；首次观察到已经 streaming 的运行时，当前 HTML、HTM 和 SVG 候选作为该运行的基线，同一运行只打开最新的新路径。没有运行身份的本地发送流式行会暂存为待关联状态；当前行序列末尾首次出现的运行身份继承该状态且不建立基线，避免同一帧出现的完成交付被吞掉。草稿会话转为新线程时保留该状态，已建立线程切换时则清除跟踪；当一帧不再包含匿名流式行时，待关联状态会被清除。`SessionWorkspace` 仅跳过内嵌协作会话，并打开该函数返回的路径。

`AgentFilePreview` 保持 SVG 的 `image` 预览类型和 Blob URL 渲染，源码模式按需从现有 Blob URL 读取文本并按 XML 高亮。HTML 与 SVG 共用“预览 / 代码”切换。Agent 提示明确要求交付这些可视化结果。

`AgentFilePreview` 也由知识库 `FileDetailModal`、扩展 `SkillDetailView`、`WorkspaceView` 和工作区 `WorkspacePreviewPane` 共用；这些页面同样获得 SVG“预览 / 代码”切换。

## 替代方案

- 从 bash 或 `write_file` 工具参数检测文件写入，或轮询文件系统：bash 写入难以可靠识别，轮询会打开中间文件。
- 后端将 SVG 作为文本返回：会破坏现有图片 Blob 预览和下载路径；源码直接从现有 Blob URL 获取。

## 后果

- 未通过 `present_artifacts` 交付的 HTML/SVG 文件不会自动打开；Agent 提示要求其交付 HTML/SVG 可视化结果。
- 首次观察运行时已有的交付物作为该运行的基线，同批多个新交付物只自动打开最新一个；同一运行关闭后的路径不会重开，新运行交付同路径会再次打开。
- 如果运行的完整历史首次以 finished 状态出现，且本页没有待关联的本地发送状态，该运行不会自动打开。
- SVG 的预览与下载路径保持不变，源码查看仅在用户切换到“代码”时读取。

## 验证

- `frontend/test/unit/artifactPresentation.test.js` 覆盖同路径跨运行重开、本地发送的同帧与终态身份继承、草稿转新线程、待身份期间不继承到较早历史、历史行抑制、多文件最新优先、刷新基线、线程切换、提示行忽略及扩展名大小写；相关运行身份、线程、历史和路径处理均有负向测试。
- 自动预览的同路径跨运行、本地身份继承、草稿线程切换、末尾身份关联、刷新基线、历史抑制及多文件处理均通过相应 guard 的临时破坏实验验证。
- `AgentFilePreview` 的 HTML/SVG“预览 / 代码”切换、SVG 源码加载与高亮、全屏和深色主题在 Vite 页面中挂载真实组件后由浏览器截图核验；SVG 源码加载失败后的重试和非成功响应处理只经过源码审阅。
- 自动预览未在完整 Compose 栈和真实模型运行下做端到端验证。
- 验证报告记录前端 lint、unit、build，后端 Ruff、工程契约检查和 `git diff --check` 的实际结果。
