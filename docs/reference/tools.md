# 工具参考

这一页回答三个问题：模型能调用哪些工具、每个工具接受什么参数、边界在哪里。工具目录不是固定清单：它会随启用项、只读权限、团队角色、会话级开关和服务配置变化；请求里真正下发的 JSON Schema 由各 `*Tools.ets` 的 `definitions()` 在运行时生成，代码是唯一事实来源。下表的参数只摘录关键项，未列出的约束以源码为准。注册、排序与执行流水线见[工具注册与执行](/internals/tools)，只读、服务配置与逐次审批如何叠加见[权限与审批](/internals/permissions)。

## 目录如何生成

- `ToolSet` 把各组工具汇总成一张表，同名工具直接抛出 `INTERNAL_ERROR`；`definitions()` 与 `execute()` 共用这张表，模型看不到的工具也无法调用。
- `SelectedTools` 按会话的 `agentMode`/`disabledTools` 过滤，`RuleTools` 再按只读规则过滤；团队员工的 `EmployeeTools` 另按 `toolProfile` 收窄。三者与“服务是否配置”取交集。
- 已启用、已配置且通过只读、会话选择和角色过滤的工具，从首次请求起直接提供完整 schema 和使用说明，按名称稳定排序；`tool_search` 默认不提供。附件、引用和员工交接仍按对应资源及角色加入。旧发现回执保留为历史，不影响当前目录。
- 参数对象默认 `additionalProperties: false`：出现未声明字段按参数错误处理，不是忽略。
- 旧版 `generate_image`、`read_tool_result` 与 `publish_data_view` 已从目录移除，历史图表回执仍能显示、导出 CSV 及参与会话导出。`image_gen` 是当前版本的图片工具，与旧 `generate_image` 不是同一个入口，旧禁用记录不会影响它；新图表、表格和指标卡统一写入 HTML/JS/SVG，再以 `publish_preview` 发布。

## 能力分组

自定义模式把可选入口归入 14 项能力；基础文件工具不受开关影响。`memory`、`read_skill`、`list_skills`、`skill_manage` 由助手设置和 Skills 页面单独控制，不占这 14 项。

| 分组 | 工具 | 数量 | 门控 |
| --- | --- | --- | --- |
| 基础文件（固定保留） | `list_files`、`find_files`、`read_file`、`search_file_content`、`write_file`、`edit_file` | 6 | 自定义模式不可关闭 |
| 附件与历史结果 | `read_attachment`、`read_reference`、`view_image` | 3 | `read_attachment`、`read_reference` 在有对应资源时出现；`view_image` 随会话提供 |
| 网页读取与搜索 | `read_web`、`search_web` | 2 | `extensions.webEnabled`；`search_web` 还要求搜索服务已启用 |
| 邮件读取 | `list_mail_accounts`、`search_mail`、`read_mail` | 3 | 始终提供；只返回设置中已启用的连接，`read_mail` 还要求该连接允许读取正文 |
| 浏览器 | `browser_open`、`browser_snapshot`、`browser_action`、`browser_capture`、`browser_wait`、`browser_handoff`、`browser_close` | 7 | `extensions.browserPolicy` 为 `disabled` 时整组不出现 |
| 代码计算 | `execute_code` | 1 | 只读模式仍可用 |
| 工具编排 | `orchestrate` | 1 | 关闭后仍可直接调用已授权文件工具 |
| 信息确认 | `request_user_input` | 1 | 只读模式仍可用 |
| 任务计划 | `update_plan` | 1 | 只读模式仍可用 |
| 团队协作 | `team_recruit`、`team_wait`、`team_inspect`、`team_read_result`、`team_control`、`team_resume`、`team_complete_task`、`team_list_messages`、`team_read_message` | 9 | 会话启用团队后加入；员工三项只在子任务内出现 |
| 预览与图表 | `publish_preview`、`get_life_panel_catalog`、`list_life_panels`、`get_life_panel`、`publish_life_panel`、`validate_life_panel`、`list_life_boards`、`get_life_board`、`manage_life_board`、`manage_life_panel_task` | 10 | 只读模式保留读取与 `publish_preview`；发布、校验与调整看板需要非只读 |
| 文件交付 | `present_files` | 1 | 只读模式仍可用 |
| 生成图片 | `image_gen` | 1 | 仅在配置并选中图片模型后出现；只读模式不可用 |
| MCP 远程工具 | `mcp_search_tools`、`mcp_list_tools`、`mcp_call` | 3 | 存在已启用且未被本会话停用的服务 |
| MCP 服务管理 | `mcp_manage` | 1 | 只读模式不可用 |
| Skills | `read_skill`、`list_skills`、`skill_manage` | 3 | Skills 页面逐项启用；`skill_manage` 只读模式不可用 |
| 长期记忆 | `memory` | 1 | `autoMemory` 开启且非只读 |

## 工作区文件

六个工具只能访问当前会话绑定的工作区（项目会话共享项目目录）。路径必须是相对路径，长度不超过 1024 字符、不超过 16 段，禁止空片段、`.`、`..`、反斜杠、冒号和 `.tinybot-` 前缀；解析时逐段拒绝符号链接。同一路径的文件操作在共享串行队列中执行，不同文件可并行。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `list_files` | 列目录 | `path` string 必填（根目录为 `.`）；`offset` integer 默认 0 | 每页 200 项，`truncated`/`nextOffset` 续页；过滤 `.tinybot-` 内部项；符号链接只报告类型，不跟随。回执 `{path, entries[{name,kind}], truncated, nextOffset}` |
| `read_file` | 按行读 UTF-8 文本，或按需提取 PDF/Office 文字 | `path` 必填；`offset` integer 默认 1；`limit` integer 默认 2000（上限 2000）；`column` integer 默认 1；`maxBytes` 默认 51200 | 单页最多 2000 行或 50 KiB，长行可按 UTF-16 列续读；返回 `content/startLine/totalLines/truncated/nextOffset/nextColumn`，内容去掉 BOM。文档读取时提取文字、不做 OCR；HarmonyOS 6 缺少 PDFKit 时读取 PDF 明确报错。成功读取才授权本轮后续覆盖 |
| `write_file` | 创建或完整覆盖 | `path`、`content` 均必填 | 自动建父目录；私有工作区原子替换，共享目录保存修改前备份后直接写入；目标已存在时必须本轮读过或成功写过，否则 `FS_NOT_OBSERVED`；含 NUL 直接拒绝。回执 `{path, bytes, written}` |
| `edit_file` | 按原文批量替换 | `path` 必填；`edits` 数组必填，1–32 项 `{oldText, newText}`；顶层 `oldText`/`newText` 为兼容入口，与 `edits` 互斥 | 所有 `oldText` 匹配同一份原文，须唯一且不重叠，全部校验后一次写入；只兼容 CRLF/LF 差异，不做模糊匹配；保留 BOM 与文件末尾换行。失败不改文件 |
| `find_files` | 按名称或 glob 查找 | `path` 必填；`glob` string 默认 `*`；`limit` integer 默认 100（1–100）；`cursor` string 可选 | 支持 `*`、`**`、`?`，不含正则；跳过隐藏条目和符号链接；每页最多检查 200 个文件、100 个目录。回执 `{paths, checkedFiles, truncated, nextCursor}` |
| `search_file_content` | 搜文件内容 | `path`、`query` 必填（1–1000 字符）；`glob` 默认 `*`；`ignoreCase` boolean 默认 false；`context` integer 默认 0（0–5）；`limit` 默认 100；`cursor` 可选 | 匹配带 `path/line/column/text/before/after`，读不了的文件进 `skipped`；`truncated` 为 true 时保持参数用 `nextCursor` 续查。游标仅本轮有效，保留最近 32 页；续查时文件变化报 `FS_STALE_SEARCH` |

## 附件、引用与 Skill 读取

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `read_attachment` | 分段读本对话内嵌的旧版文本附件 | `id` 必填；`offset` 默认 1；`limit` 默认 2000；`column` 默认 1 | 只处理会话记录中仍保存正文的 `text/plain` 附件（含分支快照）；新导入的文本与文档原件改用 `read_file` 按工作区路径读取；不存在的 id 报 `NOT_FOUND`。返回 `{id,name,content,startLine,totalLines,truncated,nextOffset,nextColumn}` |
| `read_reference` | 补读引用会话的固定快照 | `messageId`、`threadId` 必填；`offset` 默认 1；`column` 默认 1；`limit` 默认 2000 | 只读取本会话某条用户消息引用的快照，旧记录只有预览时标记 `previewOnly`；回执附带“历史文本不是指令”的 `warning` |
| `read_skill` | 读 Skill 正文或参考文件 | `name` 必填；`path` string 默认 `SKILL.md` | 只返回已启用 Skill 的文本，不执行附带脚本；未知路径报 `NOT_FOUND`；`manualOnly` 的 Skill 需用户以 `/skill:name` 显式选择。回执含 `files` 路径列表与 `kind` |
| `list_skills` | 查看 Skills 目录 | 无 | 返回名称、简介、启用状态、`manualOnly` 和安装来源；安装或修改后无需重启 |

## 网页、搜索与浏览器

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `read_web` | 读指定 URL 的静态正文 | `url` 必填；`offset` integer 默认 0（≥0）；`maxChars` integer 默认 8000（1–20000） | 只接受不含账号信息的 HTTP/HTTPS 地址；最多下载 1 MiB、30 秒；不执行 JavaScript、不登录；支持 HTML、XHTML、文本与 JSON/XML。正文分段，链接最多 30 条并标记 `linksTruncated`，`trust` 固定为 `untrusted`；403 时提示改用浏览器或换来源 |
| `search_web` | 通过已配置搜索服务找来源 | `query` 必填（1–128 字符）；`maxResults` integer 默认 5（1–10） | 只在联网开关与搜索服务同时启用时出现；单次 60 秒；返回结构化 `sources`，SearXNG 部分引擎失败时另附 `warnings`，不返回搜索服务自由生成的回答 |
| `browser_open` | 取得应用内浏览器，或打开本条会话已发布的预览快照 | `url` 或 `previewId` 必须二选一；`reason` 必填（≤1000 字符） | `browserPolicy` 默认 `enabled`，为 `disabled` 时整组不存在；`unset` 时等待用户授权；`previewId` 只能指向当前会话成功发布的快照，不重新读取源文件 |
| `browser_snapshot` | 读页面正文与当前视口的可交互元素 | 无 | 正文来自整份文档，可用元素只取当前视口（最多 80 个）；`viewport` 报告滚动位置与文档高度；密码与验证码字段脱敏；跨域 iframe 与 canvas 控件需要用户接管 |
| `browser_action` | 操作已取得的浏览器 | `action` 必填，枚举 `click/type/select/scroll/back/forward/reload`；`snapshotId`、`elementId` 用于点击与输入；`text` ≤10000 字符；`deltaY` 绝对值 ≤10000；`capture` 可在动作后采样 `{count, intervalMs}` | 元素动作必须来自最新快照，旧快照或元素移出视口报 `STALE_BROWSER_SNAPSHOT` / `STALE_BROWSER_ELEMENT`；只读模式只允许 `scroll/back/forward/reload`；页面加载 30 秒超时 |
| `browser_capture` | 不重新加载页面，连续截取 1–6 帧 | `count` 1–6；`intervalMs` 250–10000，且总间隔 ≤10000 ms | 浏览器必须可见且应用在前台；部分帧失败时保留已采集帧；截图作为观察结果，不证明帧率 |
| `browser_wait` | 在本地等待正文、元素标签或输入值出现 | `condition` 必填：`type` 为 `text/element/value`，`text` 非空，`type=value` 时另需 `value`；`timeoutMs` 0–10000 | 超时返回 `TIMEOUT`；等待不执行动作，也不代表所有交互已验证 |
| `browser_handoff` | 交还给用户处理登录或验证 | `reason` 必填（≤1000 字符） | 任务暂停到用户明确交还，不尝试绕过验证 |
| `browser_close` | 关闭本任务取得的浏览器 | 无 | 回执 `{"closed":true}` |

## 执行与编排

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `execute_code` | 在隔离 QuickJS 中跑同步 JavaScript | `code` 必填（函数体）；`input` 可选原生 JSON 值，默认 `null` | 2 秒预算、32 MiB Runtime 分配、日志合计 32 KiB；无文件、网络、定时器、模块导入或宿主工具，Promise 不支持。回执 `{status, stdout, stderr, result, error, logsTruncated, resultTruncated, durationMs}`；`status` 非 `ok` 记为失败 |
| `orchestrate` | 用异步 JavaScript 组合调用已授权工具 | `code` 必填 | 可嵌套 17 个工具（文件读写与检索、附件与引用、网页与搜索、Skills 读取、MCP 发现与调用、计算、预览与文件交付）；图片、看板、邮件与团队工具不开放嵌套；上限 32 次调用、4 个并发宿主工具、2 秒脚本计算、120 秒总时长、32 MiB JS 内存、1 MiB 结果；子调用回执保存在父回执里，取消后未开始的子调用标为 `NOT_EXECUTED`；不支持嵌套编排 |

## 交互与计划

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `request_user_input` | 用原生表单收集信息 | `title` 必填（1–200）；`fields` 必填 1–10 项，`name` 以字母开头且只含字母数字下划线（≤40），`label` 1–300，`type` 为 `text/number/select/multiselect`，`required` 可选，选择字段需 2–10 个不同选项 | 已有待处理提问时报 `INTERACTION_PENDING`；等待提交后继续，停止会把等待中的表单按取消结束；中断的表单可从工具记录重填 |
| `update_plan` | 展示并更新任务步骤 | `steps` 必填 1–20 项 `{step, status}`；`explanation` 可选（1–2000） | 每次提交完整计划；未全部完成时恰好一个 `in_progress`；回执保存步骤，供聊天内计划卡片渲染 |

## 预览与文件交付

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `publish_preview` | 准备工作区文件预览，最终回复引用插入 | `path` 必填（`.js`、`.html`、`.svg`）；`title` 可选（≤160，默认文件名）；`library` 可选 `none`/`three`（默认 `none`）；`height` 可选 200–800 | JS 在空白页执行、可操作 `document.body`；`library="three"` 预加载 THREE 与 OrbitControls；无 import、网络、本地文件或存储访问；JSONL 已不支持。发布前做启动预检并截图，成功后保存不可变快照；回执含 `previewId` 和 `reference`，最终回复独占一行复制引用，turn 完成后原位展示；工具阶段不自动展示 |
| `present_files` | 交付工作区文件 | `files` 必填 1–8 项 `{path, description?}`，说明 ≤300 字符 | 只校验文件真实存在，不创建也不复制内容；重复路径直接拒绝；成功回执在回答末尾生成文件卡片 |

## 图片生成与检查

`image_gen` 只在配置并选中图片模型时出现，属于“生成图片”能力；`view_image` 属于“附件与历史结果”能力，只读。两者分别使用图片服务与当前聊天模型。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `image_gen` | 生成或编辑图片 | `prompt` 必填（1–32000 字符）；`reference_images` 最多 4 个工作区相对路径或本对话照片引用；`aspect_ratio` 为 `1:1`/`3:2`/`2:3`；`transparent_background` 仅在 OpenAI Images 协议下可用 | 参考图须为 PNG/JPEG/WebP，合计不超过 16 MiB，重复路径直接拒绝；每次调用生成一张，写入 `generated-images/<uuid>.<ext>`；回执 `{path, mime, bytes, files:[{path}]}`；调用前单独确认服务、地址、提示词与参考图 |
| `view_image` | 把本地图片交给视觉模型检查 | `path` 必填，工作区相对路径或本对话照片引用 | 只接受 PNG/JPEG/WebP；另存最长边 1600 px 的 JPEG 副本并作为额外用户消息发送；文字回执 `{path, mime}`；不修改源文件，也不能确认透明通道 |

图片请求与响应格式由图片协议决定，失败码与恢复建议见[回执与错误](/reference/receipts)。配置与图片模型选择见[图片生成服务](/guide/models#图片生成服务)。

## 生活看板

看板工具读写工作区或看板自己保存的卡片与布局，不联网抓取页面；数据源由卡片配置决定。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `get_life_panel_catalog` | 读取看板卡片的资源与接口说明 | `section` 可选：`all`、`html`、`native`、`sources`、`balance`、`design` | `balance` 返回已配置的服务账户与对应卡片定义；原生邮件卡片可在用户操作时读取邮件正文 |
| `list_life_panels` | 列出卡片摘要 | `workspaceId`、`archived`、`limit`（1–20，默认 10）、`cursor` | 每页最多读取 50 个清单；下一页用返回的 `nextCursor` |
| `get_life_panel` | 读取单张卡片的定义、数据或任务 | `workspaceId`、`panelId` 必填；`section` 为 `all`/`definition`/`data`/`task` | 回执含可选展示用的 `reference`；更新前应取得 `configRevision` |
| `publish_life_panel` | 校验并保存卡片，可固定到看板 | `path` 必填（`.panel.json`）；`htmlPath`、`panelId`、`workspaceId`、`expectedRevision`（更新必填）、`replaceData`、`checkSource`、`placementWidth`/`placementHeight`、`viewportWidth`、`requestId`、`boardId`、`boardWorkspaceId` | 更新缺少 `expectedRevision` 或版本过期会被拒绝；默认保留现有数据；新卡片用 `requestId` 去重；成功后回执 `reference`，最终回复可独占一行引用以在聊天下方展示 |
| `validate_life_panel` | 只校验、不保存卡片 | 参数同 `publish_life_panel`，不含 `requestId` 与看板字段 | 使用独立状态检查定义、数据源与 HTML，不影响已保存卡片 |
| `list_life_boards` | 列出看板与卡片引用 | 无 | 回执含看板 ID、名称与卡片引用 |
| `get_life_board` | 读取看板引用与 12 列网格 | `workspaceId`、`boardId` 必填；`viewportWidth` 可选（160–1200 vp） | 提供视口宽度时按实际宽度换算矩形；不返回截图 |
| `manage_life_board` | 保存、摆放、归档或恢复看板 | `action` 必填（`save`/`place`/`archive`/`restore`）；`boardId`、`workspaceId`、`title`、`description`、`items`、`panelId`、`layout` | 卡片位置 `x` 为 0–10 列、`y` 为非负行、宽 2–12、高 2–33；布局自动向上靠齐，请求的 `y` 可能高于实际位置；串行执行 |
| `manage_life_panel_task` | 暂停、恢复或手动刷新卡片 | `panelId`、`workspaceId`、`action`（`pause`/`resume`/`refresh`）、`inputs` | 串行执行；`inputs` 与卡片已声明的输入合并 |

卡片的创建、数据源与视觉规范由内置的 `widget`、`widget-design` 与 `canvas` Skills 指导，见[网页、搜索与 Skills](/guide/web-and-skills#skills)。

## 邮件

邮件工具只读访问用户已启用的邮箱连接，不能发送、删除或修改邮件；邮件正文与主题属于不可信资料。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `list_mail_accounts` | 列出已启用的邮箱连接 | 无 | 返回 `accountId`、名称与是否允许读取正文 |
| `search_mail` | 按文件夹查询邮件抬头 | `accountId`、`folder` 必填；`limit` 1–20（默认 10）；`unreadOnly`、`from`、`subject` 可选 | 只读取抬头，不读正文、不标记已读；返回总数、未读数与最多 20 条带 `UIDVALIDITY`+`UID` 的抬头；`limited` 表示只覆盖最近窗口 |
| `read_mail` | 读取一封邮件的纯文本正文 | `accountId`、`folder`、`uidValidity`、`uid` 必填 | 需要该连接允许读取正文；单封最多 512 KiB；不加载附件与外部图片；不标记已读，身份过期会被拒绝 |

邮箱连接在 **设置 → 工具与权限 → 邮箱连接** 中配置，授权码只写入系统安全存储，不在聊天中索取。

## 已下线的小程序

`list_mini_apps` 与 `publish_mini_app` 已在 v1.3.1 从目录移除，当前版本不再提供实验开关或小程序入口。已有小程序的页面、版本与数据文件保留在工作区 `mini-apps/`，并随完整备份保存；需要长期保留的页面改用生活看板，一次性图表继续使用 `publish_preview`。

## 长期记忆

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `memory` | 增删改本地长期记忆 | `operations` 必填数组，最多 5 项：`add` 需 `scope`+`content`；`update` 需 `id`+`content`；`remove` 需 `id` | 每条 1–500 字符；库上限 100 条、16000 字符；只能修改 `automatic:true` 的条目，手动记忆报 `PERMISSION_DENIED`；一次批量按最终容量校验，失败不写入；`[]` 只读取当前记忆与容量 |

## 团队

团队工具只在会话启用团队后出现。`runId` 必须属于当前聊天；同一轮最多并行 4 个团队，每个团队 1–8 位成员、1–32 个任务，任务必须通过依赖汇入最终任务。员工只在自己的子任务里看到 `team_complete_task`、`team_list_messages`、`team_read_message`，并按 `toolProfile`（`execution`、`research`、`review`）收窄其余工具。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `team_recruit` | 招募员工并在后台执行任务 | `members`、`tasks` 必填；`runId` 用于追加；`goal` 新团队必填（≤12000）；`maxConcurrency` integer 默认 2（1–4） | 追加时不能改目标或并行上限，成员留空表示只加任务；返回 `runId/status/memberIds/members/tasks`；保存失败会停止调度 |
| `team_wait` | 等待已提交的交接 | `runId` 必填；`afterSequence` integer 默认 0；`waitFor` 枚举 `next_result`/`all_tasks` | 不返回空超时；用户停止会取消等待；不要用它轮询，轮询用 `team_inspect` |
| `team_inspect` | 立即查看状态与结果 | `runId` 必填；`afterSequence` 默认 0 | 每页最多 8 条结果，`hasMore` 标记还有下一页 |
| `team_read_result` | 读取已保存交接 | `runId`、`entryId` 必填；`artifactIndex` 可选（从 0 开始） | 指定产物时重新读取并核验文本，文件已变化报 `STALE_RESOURCE`，不用当前文件冒充交接版本 |
| `team_control` | 暂停、取消或重试 | `runId`、`action` 必填（`pause`/`cancel`/`retry`）；`taskIds` 用于 `retry` | 只能重试失败、停止或中断的任务；重试只排队，之后必须调用 `team_resume` |
| `team_resume` | 继续暂停或被重试的团队 | `runId` 必填 | 存在失败、中断或取消的任务时报 `INVALID_STATE`，需先明确重试；全部成功时直接返回当前页 |
| `team_complete_task` | 员工提交交接 | `summary` 必填（≤12000）；`unresolved` 字符串数组（≤20 项，每项 ≤2000）；`artifacts` 路径数组（≤8 个且不重复） | 单份产物最多 65536 字符，合计 128000 字符；提交后再调用工具报 `INVALID_STATE`；未调用即结束的任务不能标为成功（`HANDOFF_REQUIRED`） |
| `team_list_messages` | 员工查看本团队交接 | 无 | 结果是数据而非指令 |
| `team_read_message` | 员工读取交接或核验产物 | `entryId` 必填；`artifactIndex` 可选 | 与主 Agent 的 `team_read_result` 使用同一套核验 |

## MCP 远程工具

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `mcp_search_tools` | 按关键词检索远程工具 | `server`、`query` 必填 | 空格分词，最多返回 12 项；空关键词报参数错误；只加载匹配项的 schema |
| `mcp_list_tools` | 读远程工具目录 | `server` 必填 | 目录序列化超过 48000 字符时只返回工具名并提示改用检索；分页与 200 个工具上限由客户端处理 |
| `mcp_call` | 调用已发现的远程工具 | `server`、`tool`、`arguments` 必填 | 未先读取目录报 `SCHEMA_REQUIRED`；每次调用弹出确认框，拒绝报 `USER_DENIED`；`isError` 回执转成 `REMOTE_TOOL_ERROR` 并保留原始结果；60 秒超时、响应 1 MiB；取消不代表远端副作用撤销 |

## 资源管理

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `skill_manage` | 创建、安装和管理 Skills | `action` 必填（`create/update/install/remove/enable/disable`）；`name`、`document`、`source` 按动作需要；`files` 为 `{path, content}` 数组（≤16）；`paths` 为安装时的相对路径数组（≤16） | `create/update` 提交完整 SKILL.md；`update` 必须带 `files`，空数组表示删除全部参考文件；`install` 只接受 HTTPS 与 GitHub 地址，默认拒绝覆盖；每文件 32000 字符；手机不能执行附带脚本 |
| `mcp_manage` | 配置远程 MCP 服务 | `action` 必填（`list/save/remove/enable/disable/test`）；`id`、`name`、`url`、`auth`、`clientId` 按动作需要 | `auth` 为 `none/bearer/oauth/keep`；`bearer` 走原生密码框、`oauth` 走原生授权，密钥不进入聊天；`save` 先连接验证再保存，失败保留旧配置；仅支持 HTTPS，不支持 stdio 与自定义请求头 |

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/ToolSet.ets` | 目录汇总与分发，重名工具直接失败 |
| `entry/src/main/ets/services/ToolCatalog.ets` | 完整授权目录稳定排序；旧搜索回执只保留为历史 |
| `entry/src/main/ets/services/SelectedTools.ets` | 按会话选择过滤目录与调用 |
| `entry/src/main/ets/services/RuleTools.ets` | 只读规则过滤 |
| `entry/src/main/ets/services/WorkspaceTools.ets` | 文件工具定义、参数校验与路径约束 |
| `entry/src/main/ets/services/WorkspaceSearch.ets` | 名称与内容检索、游标分页 |
| `entry/src/main/ets/services/NativeWorkspaceFiles.ets` | 读写落盘、版本校验、修改基线与临时文件 |
| `entry/src/main/ets/services/WebTools.ets` | 网页正文抽取与分页 |
| `entry/src/main/ets/services/WebSearchTools.ets` | 联网搜索与来源 |
| `entry/src/main/ets/services/BrowserTools.ets` | 应用内浏览器工具 |
| `entry/src/main/ets/services/CodeExecutionTools.ets` | 代码沙箱工具与状态映射 |
| `entry/src/main/ets/services/OrchestrationTools.ets` | 工具编排、子调用并发与限额 |
| `entry/src/main/ets/services/InteractionTools.ets` | 表单、计划与图表 |
| `entry/src/main/ets/services/PreviewTools.ets` | 预览发布、预检与截图 |
| `entry/src/main/ets/services/PresentTools.ets` | 文件交付 |
| `entry/src/main/ets/services/ImageGenerationTools.ets` | 图片生成与编辑工具、参考图读取与输出保存 |
| `entry/src/main/ets/services/ImageInspectionTools.ets` | `view_image` 参数、图片副本与回执 |
| `entry/src/main/ets/services/NativeImageGenerator.ets` | 图片服务请求、超时、下载与失败映射 |
| `entry/src/main/ets/services/ImageGenerationProtocol.ets` | 四种图片协议的请求体与响应解析 |
| `entry/src/main/ets/services/LifePanelTools.ets` | 看板卡片、看板布局与刷新任务工具 |
| `entry/src/main/ets/services/MailTools.ets` | 邮箱连接、查询与正文读取工具 |
| `entry/src/main/ets/services/MemoryTools.ets` | 长期记忆操作 |
| `entry/src/main/ets/services/SkillTools.ets` | 读取 Skill 与目录 |
| `entry/src/main/ets/services/ResourceTools.ets` | Skills 与 MCP 配置管理 |
| `entry/src/main/ets/services/McpTools.ets` | 远程工具发现与调用 |
| `entry/src/main/ets/services/ChatTeamTools.ets` | 团队协调与员工交接 |
| `entry/src/main/ets/model/ToolGroups.ets` | 能力分组与只读分组 |
| `entry/src/main/ets/model/AgentMode.ets` | 自定义选择与工具开关判定 |
