# 网页、搜索与 Skills

Tinybot 能读网页、查资料，也能按导入的 Skill 改变工作方式。这页说明五种容易混淆的能力各自做什么、需要打开哪个开关、有哪些固定预算，以及它们与聊天内交互预览的分界。

## 五类能力的边界

| 能力 | 工具 | 前置条件 | 不做什么 |
| --- | --- | --- | --- |
| 网页读取 | `read_web` | 允许联网 | 不执行 JavaScript、不登录、不绕过验证码、不搜索 |
| 联网搜索 | `search_web` | 允许联网 + 搜索服务已启用（默认必应） | 不把搜索服务的自由生成回答当作来源 |
| 应用内浏览器 | `browser_open` 等 | 浏览器权限已启用 | 不代替用户输入密码或验证码，不跨站继承登录 |
| 交互预览 | `publish_preview` | 工作区中存在 `.js`/`.html`/`.svg` 文件 | 不联网、不读本地文件、不写存储、不使用浏览器会话 |
| 本地小程序 | `list_mini_apps`、`publish_mini_app` | 实验室中开启“小程序” | 不联网、不读本地文件；只通过 `tinybot.storage` 读写自身数据 |

关闭 **设置 → 允许网页读取与搜索** 后，网页与搜索工具既不提供给模型，也不接受这类调用；它不影响模型服务与浏览器权限。

## 网页读取

在聊天中给出地址后，模型可调用 `read_web` 获取静态正文、标题与链接。它只支持 HTTP/HTTPS GET，地址不能包含空白、控制字符、反斜杠、用户名或密码。

| 项目 | 值 |
| --- | --- |
| 单跳连接超时 | 10 秒（取剩余总时限与 10 秒的较小值） |
| 总读取时限 | 30 秒，含全部重定向 |
| 重定向 | 最多 5 次，每一跳重新校验协议；循环、缺少 `Location` 或超过 5 次都会报错 |
| 响应体积 | 最多 1 MiB |
| 正文返回 | 默认 8000 字符；`offset` 与 `maxChars` 可翻页，单页最多 20000 字符 |
| 链接 | 最多 30 个，超出时单独标记 `linksTruncated` |
| 请求头 | 固定的 `User-Agent: Tinybot-Harmony/0.1` 与 `Accept`；不携带模型密钥、Cookie 或自定义认证头 |

- HTML 会去掉注释与 `script`、`style`、`template`、`svg`、`noscript`，优先取 `main` 或 `article` 区域，再转为纯文本；`<br>` 与块级结束标签转为换行。
- 文本、Markdown、JSON 按文本返回；`application/xml`、`application/*+xml`、`application/*+json` 按结构化文本读取。
- PDF、图片、二进制内容、无法解析的编码会返回明确失败；空正文提示“可能需要登录或 JavaScript”。
- 网页结果带来源 URL 与 `trust: untrusted`，作为资料交给模型；引用时应保留来源并说明截断。
- 正文被截断时返回 `totalChars` 与 `nextOffset`，继续读取使用 `nextOffset`。SEC 财报这类长文档应先从 FilingSummary 定位目标表，再按需取表，不必把脚注全部放进上下文。
- 网站声明的 favicon 地址只作为界面元数据保存在工具回执上，不放进发给模型的工具结果；未声明时使用站点根目录的 `/favicon.ico`。加载失败、旧记录没有图标信息或关闭联网时显示通用图标，不会重新读取网页，也不查询第三方图标服务。

停止生成会销毁正在进行的网络请求并阻止后续工具。

## 应用内浏览器

`read_web` 读不到动态内容、需要登录或必须点击筛选时，模型可使用应用内浏览器。它在 **设置 → 工具与权限 → 应用内浏览器** 中默认开启；关闭后助手不会再次请求启用，需要时可在设置里重新打开。

| 工具 | 作用 | 关键参数 |
| --- | --- | --- |
| `browser_open` | 获取或复用本会话的浏览器操作权；也可打开本条会话已发布的预览快照 | `url` 或 `previewId` 二选一、`reason`（最多 1000 字符） |
| `browser_snapshot` | 读取整份文档正文与当前视口的可操作元素 | 无 |
| `browser_action` | 点击、输入、选择、滚动、后退、前进、刷新 | `action`、`snapshotId`、`elementId`、`text`（最多 10000 字符）、`deltaY`（绝对值不超过 10000）、可选 `capture` |
| `browser_capture` | 不重新加载页面，连续截取 1–6 帧 | `count`、`intervalMs`（250–10000，总间隔不超过 10000） |
| `browser_wait` | 在本地等待正文、元素或输入值出现 | `condition`（`text`/`element`/`value`）、`timeoutMs`（0–10000） |
| `browser_handoff` | 把浏览器交给用户完成登录或验证 | `reason` |
| `browser_close` | 关闭本任务获取的浏览器 | 无 |

- 浏览器只支持 HTTP/HTTPS，与浏览器会话绑定的登录状态只属于该会话。
- 快照的正文来自整份文档，可操作元素只来自当前视口；正文提到的链接可能还没滚进视口，应滚动后重新快照，而不是判定链接缺失。
- 需要确认动画或过渡时用 `browser_capture` 或 `browser_action.capture` 连续采样；需要等页面状态变化时用 `browser_wait`，超时会明确失败。两者都只在浏览器可见且应用位于前台时工作。
- 助手可以打开本条会话已发布的预览快照做实际页面检查：`browser_open({previewId, reason})`，再用快照、点击、等待与截图验证交互，不需要重新发布或另起网页服务。
- 滚动、缩放、窗口尺寸变化，或目标控件的内容与位置变化后，旧快照不能再用于点击或输入，必须重新读取页面。
- 密码与验证码控件会被遮蔽，涉及它们的操作需要用户接管，不能尝试绕过。
- 点击网页、编辑输入、修改或提交地址、后退/前进/刷新，或点“接管浏览器”时切换为用户控制；任务会等待明确的“交还给 Tinybot”后继续。聚焦地址栏、选择或复制地址不会接管。
- 已经发出的网页操作会完成，不会因为接管而撤销或自动重放。
- 等待完整加载超过 30 秒会明确返回超时，可检查当前快照判断页面是否随后就绪；网站返回的 HTTP 403 不会被隐藏或绕过。
- 只读模式下不能点击、输入或选择，只能读取、滚动、等待与截图。

## 联网搜索

**设置 → 工具与权限 → 搜索服务** 配置 `search_web` 使用的服务；默认使用必应（内置浏览器）并已启用。列表中的勾选与开关只修改草稿，详情页“完成”返回列表，底部“保存”才统一生效。搜索与网页读取同受“允许网页读取与搜索”总开关控制。返回给模型的是结构化来源（标题、URL、摘录、可用的来源时间），SearXNG 部分引擎失败时另附告警。

| 提供方 | 地址 | 凭据 |
| --- | --- | --- |
| 必应（内置浏览器） | 通过应用内浏览器访问 `https://www.bing.com/search` | 无需 API Key；关闭应用内浏览器即停用 |
| DeepSeek 原生搜索 | 固定官方地址 `https://api.deepseek.com/v1/tools/search` | 复用官方 DeepSeek 模型服务的 API Key，不填独立密钥 |
| Tavily | 默认 `https://api.tavily.com`，必须是 HTTPS | 独立地址与独立密钥 |
| SearXNG | 可配置 HTTP/HTTPS 实例基础地址，支持子路径 | 无需 API Key；实例需支持 JSON 输出 |

必应搜索不需要密钥：每次搜索都在应用内浏览器打开必应并读取结构化结果，遇到验证页会交还控制权，完成验证后继续。关闭“允许网页读取与搜索”或禁用应用内浏览器都会停用内置搜索。

DeepSeek 搜索按下面的规则选择服务：只有一个使用官方地址、已启用且配置了密钥的模型服务时自动复用；有多个时必须选择其中之一；保存时检查密钥是否存在，运行时分派时重新解析服务引用，因此密钥轮换不需要改搜索设置。服务被删除、停用或改成非官方地址时明确失败，不会退回猜测。

请求参数：搜索词 1–128 字符；`maxResults` 默认 5，范围 1–10。API 搜索传输层连接超时 15 秒、读取超时 60 秒、响应上限 1 MiB、不跟随重定向；DeepSeek / Tavily 的 HTTP 402 提示账户余额不足，其他非 200 状态附带原始状态码。

SearXNG 地址不含 `/search` 或查询参数；实例需在 `settings.yml` 的 `search.formats` 中启用 `json`，未启用时通常返回 403。请求以表单提交，来源去重后按 `maxResults` 限制数量；有来源但部分引擎失败时返回 `warnings`，没有来源且有引擎错误时明确报错。

DeepSeek 请求使用 `count` 指定条数并固定 `need_content: false`，摘要优先取长摘要并原样保留，不再调用模型或按字符上限裁剪。Search 按成功请求次数计费；网页正文仍由 `read_web` 读取。

搜索密钥不进入模型上下文、日志或备份。每次 API 搜索单独记一条用量记录（提供方标为 `deepseek-search`、`tavily-search` 或 `searxng-search`，用途为联网搜索）；记录不含 Token 字段，因此在用量里显示“未报告”而不是 0。

Tavily 地址与密钥在切换提供方后保留，切回同一地址无需重新输入。更换地址、替换或主动清除密钥时，只有列表保存成功后才清理旧密钥；未配置密钥的 Tavily 不能以启用状态保存。必应详情展示网页与浏览器权限，不提供密钥输入框。未知提供方保留配置并显示说明，不提供搜索工具。

## Skills

Skill 是一份带元数据的 Markdown 工作说明，只提供工作指导，不增加工具或权限，也不能覆盖用户当前要求。应用内置五个默认启用的文本 Skill：

| 名称 | 标识 | 用途 |
| --- | --- | --- |
| 资料速读 | `document-brief` | 阅读文档、文章与截图，提炼结论、依据及待核实项 |
| 联网调研 | `web-research` | 搜集并核实来源，比较方案，保留时间与适用范围 |
| 随手记整理 | `notes-to-actions` | 整理口述、会议与零散想法，区分决定、待办与问题 |
| 数据分析 | `data-analysis` | 检查 CSV/JSON/文档表格的数据口径，计算并展示结果 |
| 草图变原型 | `sketch-to-prototype` | 把草图、截图或布局说明变成可预览的 HTML/SVG 或交互演示 |

内置 Skill 不改变开关：联网调研仍需开启联网，搜索默认使用必应（可改用 DeepSeek、Tavily 或 SearXNG），图片理解仍需视觉模型，原型沿用现有预览沙箱。

### 调用

- 输入 `$` 唤起 Skill 列表，继续输入中文名称、英文名或用途关键词筛选；列表只包含已启用的 Skill，也包含只能手动调用的 Skill。点击后转换为 `/skill:名称` 并保留其他已输入内容，不自动发送。`$20`、`US$20` 这类金额不会唤起列表。
- 也可以直接输入 `/skill:名称 附加要求`。一条消息只使用一个 Skill，再次选择会替换前一个；发送时应用把 Skill 正文展开进用户消息并保存，之后停用或删除不会影响这条历史。
- **设置 → 管理 Skills** 中可点“在对话中使用”，效果同样是放入 `/skill:名称` 草稿。
- 默认只把已启用、本轮可用的 Skill 名称与简介放进上下文；模型用 `read_skill` 读取正文，读取时同时得到参考文件路径，按相对路径取用。

### 导入与编辑

在 **设置 → 管理 Skills → 添加** 导入单个 `SKILL.md` 或粘贴内容，检查后保存。例如：

```markdown
---
name: page-summary
description: 总结用户提供的网页，提取要点并保留来源链接
---

先读取用户提供的网址，再整理三个要点。保留来源 URL；读取失败或正文截断时明确说明。
```

Skill 引用 `references/guide.md` 时，在编辑页填写相同的相对路径，再导入或粘贴参考文本并点击“添加参考文件”。这些内容作为副本保存在本机，没有持续的外部目录授权。

- 元数据识别 `name`、`description` 与 `disable-model-invocation`；前两者支持普通文本、引号文本以及 `|`、`>` 多行文本，使用对象、引用或无效值会明确报错。其他元数据保留在原文中，不授予权限。
- `name` 限最多 64 字符的小写字母、数字与单连字符；`description` 1–1024 字符。
- 支持 `disable-model-invocation: true`，该 Skill 只在用户显式调用时提供给模型。
- 不批量导入目录或 ZIP，不运行 Shell、Python、Node.js 或 Skill 内脚本；参考文件越界、重名或未启用都会明确报错。

| 限制 | 值 |
| --- | --- |
| Skill 数量 | 不设固定数量上限，仍受下列文本容量限制 |
| 每个 Skill 的参考文件 | 最多 16 个 |
| 单个文档 | 最多 32000 字符 |
| 全部文档合计 | 最多 512000 字符 |
| 文件选择器单次导入 | 最多 64 KiB 的 UTF-8 文本 |

首次启动与旧版升级会把内置内容作为本地副本安装，不覆盖同名用户 Skill、联网设置或已有文档。安装后可以停用、编辑、重命名或删除，重启不会恢复；修改过的正文视为自定义内容，不再显示“内置”标记，后续应用更新也不会覆盖。

每次运行会固定本轮可用的 Skill 与正文副本，工具结果按现有检查点落盘并参与历史回放。

## 与交互预览的边界

预览与浏览器是两条独立通道：`publish_preview` 把工作区里的 `.js`、`.html` 或 `.svg` 发布为聊天内的隔离卡片，既不申请也不改变浏览器会话，也不继承浏览器的网络、存储与控制权。

- `.js` 在空白页面中执行，可操作 `document.body`，支持 `await`；`library: "three"` 会预加载 THREE 与独立 OrbitControls。
- 页面内没有 imports、网络、本地文件或存储访问；高度限制 200–800 vp，标题最多 160 字符。需要持久数据或长期复用时改用本地小程序，见[文件与工作区](/guide/files#小程序收藏)。
- 发布前会检查页面能否启动并截图，成功后保存不可变快照，重启后可恢复；JSONL 预览已不支持，会明确报错。
- 预览失败返回可修复的分类与位置，不会把半成品当作已发布内容。

更完整的渲染与沙箱细节见 [交互预览与 Web UI](/internals/preview)。

## 代码入口

| 职责 | 位置 |
| --- | --- |
| 网页读取、正文抽取与链接上限 | `entry/src/main/ets/services/WebTools.ets` |
| 网页传输、重定向与超时 | `entry/src/main/ets/services/NativeWebTransport.ets` |
| 浏览器工具与参数校验 | `entry/src/main/ets/services/BrowserTools.ets` |
| 浏览器会话与接管 | `entry/src/main/ets/services/BrowserSession.ets` |
| 搜索工具与参数范围 | `entry/src/main/ets/services/WebSearchTools.ets` |
| 搜索配置校验与凭据复用 | `entry/src/main/ets/model/WebSearch.ets`、`entry/src/main/ets/services/SearchSettings.ets` |
| 搜索传输、用量与超时 | `entry/src/main/ets/services/NativeSearchTransport.ets` |
| Skill 解析、校验与目录 | `entry/src/main/ets/model/Skills.ets` |
| Skill 工具（读取正文与参考文件） | `entry/src/main/ets/services/SkillTools.ets` |
| Skill 导入 | `entry/src/main/ets/services/SkillImport.ets` |
| 预览发布 | `entry/src/main/ets/services/PreviewTools.ets` |
