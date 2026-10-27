# 交互预览与 Web UI

模型把 JavaScript、HTML 或 SVG 写进工作区，再调用 `publish_preview` 准备预览快照，最后在回复中插入工具返回的引用；turn 成功结束后，聊天在引用位置挂载隔离的 ArkWeb 页面。这页说明发布参数、从读取到截图的完整生命周期、快照如何随会话保存，以及它和独立浏览器为什么是两套东西。预览对应的源文件如需下载或分享，使用 `present_files` 交付，见[文件与工作区](/guide/files)。

## publish_preview 参数

| 参数 | 必填 | 默认 | 约束 |
| --- | --- | --- | --- |
| `path` | 是 | 无 | 已存在的工作区相对路径，扩展名必须是 `.js`、`.html` 或 `.svg` |
| `title` | 否 | 文件名 | 1–160 字符；文件名部分也截到 160 |
| `library` | 否 | `none` | `none` 或 `three` |
| `height` | 否 | JS 为 400 | 200–800；HTML/SVG 省略时按内容自适应，实际渲染限制在 48–800 |

`.jsonl` 会被直接拒绝并返回 `UNSUPPORTED_PREVIEW_FORMAT`，提示改写普通 `.js` 或自包含 HTML/SVG，不会暂存旧格式再建议无效重试。工具只读取一次源文件，后续校验、预检、截图都针对这一次的内容。

## 发布生命周期

```text
workspaceRelativePath(path)        校验相对路径与扩展名
  → files.read(path)               读取一次，得到 content 与 version
  → 构造 WebUiSpec                  html / css / js / library / height / autoHeight
  → UiCompiler + validateUiAnswer   生成内部 tinybot-ui 记录并校验
  → WebUiPreflight.validate()       设备上的启动检查（30 秒超时）
  → PreviewCapture.capture()        同一卡片、聊天宽度截图
  → 写入 execution.previewContent 与 previewScreenshot
  → 返回 { published, previewId, reference, path, title, nodes, version, verification, screenshot }
```

- JS 文件被放进 `js` 字段，`html` 为空；HTML/SVG 放进 `html`，`js` 为空。CSS 让 `html,body` 至少填满视口，SVG 居中并按宽度缩放。
- HTML/SVG 未指定 `height` 时 `autoHeight` 为真，由页面测量内容高度并回传；显式指定则固定高度。
- 预检与截图都在发布前完成。任一步失败都不会产生“已发布”回执，源文件保持不变。
- 成功回执包含路径、标题、节点数、源版本、验证状态与截图尺寸，不含源码；模型不会因为发布而再次收到整份文件。`verification.startup=passed` 表示启动检查通过，`screenshot=captured` 表示获得截图，`interaction=not_checked` 明确表示后续交互尚未验证。
- 截图作为一条独立的 user 消息附在工具结果之后，明确标注为“不可信的视觉输出”，用于检查间距、裁切与可读性；不支持图片的模型会收到文字说明。

## 最终回复中的引用

成功回执包含 `previewId` 及可原样复制的 `reference`，格式为 `[[tinybot-preview:pv_…]]`。引用必须独占一行，位于最终回复希望插入预览的位置，不能放在代码块、引用块或普通段落内部。前后可以写普通 Markdown。每个源文件最后一次成功发布的版本必须被引用；也可以显式引用本轮较早的成功版本，重复引用同一 ID 会被拒绝。引用仅解析本条回复工具记录里的成功快照，不接收任意路径或其他会话的 ID。

工具阶段仍在隐藏容器中进行启动检查和截图，成功快照保存在工具记录中，正文不自动追加预览。最终文字可以流式显示，iframe 只在整个 turn 成功完成后挂载；中间回复、修复尝试、失败或取消均不挂载新预览。漏写、格式错误、重复或不存在的引用会反馈给模型修复最终回复，最多三次，不重复已经完成的写入或发布。

新引用预览没有额外的标题、白底、边框与内边距；页面自身决定布局。截图同样使用无外框容器。旧回执没有 `previewId`，继续按历史卡片方式展示，不需要改写存档。静态图片导出把截图放在引用位置；Markdown 导出把引用转换为预览标题，不泄露内部标记或过程记录。

## 快照与恢复

发布工具也可在 `orchestrate` 中调用，效果与直接发布一致：子调用的卡片、截图、版本与源码快照保存到会话，截图进入下一次模型请求；外层编排后续失败不会删除已发布成果。图表与文件交付同样支持编排内调用。参见[工具编排](/internals/tools#可视化与交付编排)。

成功发布时，渲染内容作为不可变快照（snapshot）保存在工具记录的 `previewContent` 中，截图的宽、高、卡片宽度与图片一起保存。这些字段都是本地展示元数据，不进入模型上下文。

| 行为 | 结果 |
| --- | --- |
| 修改或删除源文件 | 已发布预览不变，仍显示发布时的快照 |
| 再次发布同一路径 | 产生新版本；旧版本在历史消息中保留，但不再是最新 |
| 发布另一个文件 | 两个预览互不影响，各自独立取最新版本 |
| 会话重启、切换或分支 | 直接使用保存的快照，不重新读取源文件 |
| 截图失败 | 整个发布失败，不写入预览 |

`previewContent` 上限为 96100 字符，截图宽高必须在 1–1600 之间且为 JPEG；`validateSteps()` 在加载历史时校验这些约束，损坏的记录会让本地工具记录整体失败并保留原文件。历史卡片只把“同一路径最后一次成功发布”标为最新；新引用按明确的快照展示，不随源文件编辑或其他消息的新版发布而改变。

## 隔离的 ArkWeb 卡片

预览由 `WebUiView` 承载。外层是一份受信任的宿主文档，模型生成的代码只在内层 `iframe` 中运行，该 iframe 使用 `sandbox="allow-scripts"` 且没有同源权限。

| 边界 | 实现 |
| --- | --- |
| 脚本来源 | 只执行发布时写入的 `js` 与内置库，不加载外部脚本 |
| 网络 | CSP `connect-src 'none'`，页面内不能发请求 |
| 资源 | `img-src data: blob:`；不支持本地文件、嵌套页面或外部依赖 |
| 设备能力 | `allow` 关闭摄像头、麦克风、定位与剪贴板；无通知、存储或文件权限 |
| 导航 | `base-uri`、`form-action`、`frame-src` 均受限 |
| 数据 | WebUi JSON 最多 64000 字符；桥接消息最多 18000 字符；保存状态最多 12000 字符 |

页面运行时提供 `tinybot` 对象：`state` 读取当前状态副本，`active` 表示当前是否可交互，`onState()` 订阅状态变化，`animate(callback)` 注册逐帧回调，`save(values)` 提交状态。只读、离屏或后台时 `active` 为假；预检期间会临时置为真以执行首帧检查，但 `save()` 被明确拒绝，避免把初始化当成用户操作。首帧动画在预检时会被主动执行一次，用来提前暴露错误。

生命周期按可见性收敛：聊天滚动期间不创建新的 Web 视图，停止滚动后才加载当前可见的预览；已加载且可见的视图继续绘制。短暂离屏会保留并暂停实例，前台连续离屏 5 秒后释放；进入后台只暂停，保留原生 Web 与已就绪状态，回到前台恢复同一实例；组件卸载时释放，局部变量与 DOM 状态随之重建。

## 与独立浏览器会话的区别

| 项目 | 预览卡片 | 应用内浏览器 |
| --- | --- | --- |
| 入口 | `publish_preview` | `browser_open` 等 5 个工具 |
| 承载 | 聊天消息内的 `WebUiView` + 隔离 iframe | 独立浏览器面板与 `BrowserSession` |
| 内容 | 工作区里的 JS/HTML/SVG | 外部 HTTP/HTTPS 网页 |
| 网络 | 禁止 | 允许，受浏览器启用策略约束 |
| 控制权 | 无接管概念，只区分是否可交互 | 在 Agent 与用户之间转移，可等待交还 |
| 存储 | 不持久化网页存储；仅工具记录里的快照 | 继承网页自身行为，按浏览器会话管理 |
| 关闭 | 随消息存在，视图可释放后重建 | 关闭会结束会话与页面 |

发布预览不会申请、获取或改变浏览器会话，也不继承其 Cookie、存储、权限或控制权。反过来，关闭浏览器不影响已发布的预览。

## Three.js 与内置资源

`library: "three"` 会在页面脚本之前注入两个全局对象：`THREE` 与独立的 `OrbitControls`。后者不是 `THREE.OrbitControls`，必须直接 `new OrbitControls(camera, canvas)`；运行时会针对这个常见错误给出专门提示。

资源来自应用包内的 rawfile，不访问 CDN，也不需要 import：

| 文件 | 作用 |
| --- | --- |
| `entry/src/main/resources/rawfile/interactive-web/host.js` | 宿主运行时、iframe 创建、桥接与 `tinybot` API |
| `entry/src/main/resources/rawfile/interactive-web/three.bundle.js` | Three.js 与 OrbitControls 的打包产物 |
| `entry/src/main/resources/rawfile/interactive-web/THREE-LICENSE.txt` | 第三方授权 |

`WebUiAssets` 用 `resourceManager.getRawFileContent()` 读取，严格 UTF-8 解码，并在模块级缓存：宿主运行时只读一次，Three.js 仅在需要时读取一次。打包脚本 `scripts/build-web-ui-vendor.cjs` 对 `three@0.186.1` 归档做 SHA-512 校验，再用已安装的 DevEco webpack 生成产物；不在构建期下载包或执行包内脚本。

## 发布校验与错误

| 代码 | 触发 | 附加信息 |
| --- | --- | --- |
| `INVALID_ARGUMENTS` | 参数缺失、字段多余、标题或高度越界、扩展名不支持 | 修复参数即可 |
| `UNSUPPORTED_PREVIEW_FORMAT` | `.jsonl` 或回答里直接输出 `tinybot-ui` | 改为源文件 + 工具发布 |
| `PREVIEW_INVALID` | 编译、启动检查或截图失败 | `path`、`version`、`category`、`location`、`locationScope`、`excerpt`、`repair` |

`category` 来自诊断错误本身；本工具设置的阶段值为 `INVALID_FIELD`、`WEB_STARTUP_FAILED` 与 `SCREENSHOT_FAILED`，编译阶段也可能给出其他字段级诊断码。`locationScope` 固定为 `generated_wrapper`，表示位置来自内部包装协议，不能冒充原始 JS/HTML 行号；运行时错误会附浏览器堆栈。重试保留 `path/title/library/height`，模型应读取源文件、局部修复后重新发布。

回答正文里直接出现 `tinybot-ui` 或 JSONL 会被循环判为 UI 校验失败：该步工具全部标为 `NOT_EXECUTED`，模型收到修复说明；连续 3 次失败或到达轮次上限时终止本轮。

## WebUiAssets 与启动预检

`WebUiPreflight` 是全局单探针队列：同一个时间只渲染一个待检查页面，聊天与团队运行时共用。预检（preflight）不写入会话或工具记录。每次检查有 30 秒启动超时，超时或取消都会清理队列；没有挂载检查宿主时直接报“预检宿主不可用”，不会把未验证的内容当作已发布。

校验入口遍历内容中的每个 UI 片段与每个 `web` 节点，逐个调用检查。失败会包装为 `WEB_STARTUP_FAILED`，带上 `surface`、`node` 与字段位置。启动检查覆盖初始动画回调、未处理的 Promise 拒绝、资源加载与 CSP 违规；它只证明页面能启动，不保证后续所有交互都正确。

截图由 `PreviewCapture` 完成，同样是单队列、30 秒超时、按聊天卡片与聊天宽度渲染。最长边不超过 1600 像素，以 JPEG 保存。截图只代表一个画面，不能替代交互测试；设备能力不足或截图失败时，发布不会发生。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/PreviewTools.ets` | 参数校验、读取一次、组装规格、预检与截图、发布回执 |
| `entry/src/main/ets/model/WebUi.ets` | `WebUiSpec` 校验、宿主文档与 CSP、桥接消息限制 |
| `entry/src/main/ets/views/WebUiView.ets` | ArkWeb 承载、可见性与前后台生命周期、自适应高度 |
| `entry/src/main/ets/services/WebUiAssets.ets` | 读取并缓存宿主运行时与 Three.js 包 |
| `entry/src/main/ets/services/WebUiPreflight.ets` | 单探针启动检查、超时与诊断包装 |
| `entry/src/main/ets/views/WebUiPreflightHost.ets` | 隐藏的预检宿主视图 |
| `entry/src/main/ets/services/PreviewCapture.ets` | 同卡片宽度截图与超时 |
| `entry/src/main/ets/model/PublishedPreview.ets` | 最新版本判定、已取代标记与展示内容 |
| `entry/src/main/ets/model/Agent.ets` | 预览快照与截图的持久化校验 |
| `entry/src/main/ets/services/AgentLoop.ets` | 拒绝内联 UI 与 JSONL、限制修复次数 |
| `entry/src/main/ets/services/BrowserSession.ets` | 独立浏览器会话、控制权与接管 |
| `scripts/build-web-ui-vendor.cjs` | Three.js 归档校验与打包 |

## 图表与数据交付

新图表、表格及指标卡统一采用工作区 HTML/JS/SVG 文件与 `publish_preview`，不再注册 `publish_data_view`。先计算并校验，再写入页面，显示来源、单位、时间范围和原始数值；需要下载时生成实际 CSV/JSON，以 `present_files` 交付。预览沙箱不能直接读写工作区文件。

历史 `publish_data_view` 回执保留原生卡片、查看数据、CSV 导出和会话导出，包括编排子调用中的旧图表；无需迁移或改写已有消息。
