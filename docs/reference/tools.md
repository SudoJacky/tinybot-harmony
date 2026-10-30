# 工具参考

这一页回答三个问题：模型能调用哪些工具、每个工具接受什么参数、边界在哪里。工具目录不是固定清单：它会随启用项、只读权限、团队角色、会话级开关和服务配置变化；请求里真正下发的 JSON Schema 由各 `*Tools.ets` 的 `definitions()` 在运行时生成，代码是唯一事实来源。下表的参数只摘录关键项，未列出的约束以源码为准。注册、排序与执行流水线见[工具注册与执行](/internals/tools)，只读、服务配置与逐次审批如何叠加见[权限与审批](/internals/permissions)。

## 目录如何生成

- `ToolSet` 把各组工具汇总成一张表，同名工具直接抛出 `INTERNAL_ERROR`；`definitions()` 与 `execute()` 共用这张表，模型看不到的工具也无法调用。
- `SelectedTools` 按会话的 `agentMode`/`disabledTools` 过滤，`RuleTools` 再按只读规则过滤；团队员工的 `EmployeeTools` 另按 `toolProfile` 收窄。三者与“服务是否配置”取交集。
- 已启用、已配置且通过只读、会话选择和角色过滤的工具，从首次请求起直接提供完整 schema 和使用说明，按名称稳定排序；`tool_search` 默认不提供。附件、引用和员工交接仍按对应资源及角色加入。旧发现回执保留为历史，不影响当前目录。
- 参数对象默认 `additionalProperties: false`：出现未声明字段按参数错误处理，不是忽略。
- `generate_image`、`read_tool_result` 与 `publish_data_view` 已从目录移除。历史图表仍能显示、导出 CSV 及参与会话导出；新图表、表格和指标卡统一写入 HTML/JS/SVG，再以 `publish_preview` 发布。

## 能力分组

自定义模式把可选入口归入 12 项能力；基础文件工具不受开关影响。`memory`、`read_skill`、`list_skills`、`skill_manage` 由助手设置和 Skills 页面单独控制，不占这 12 项。

| 分组 | 工具 | 数量 | 门控 |
| --- | --- | --- | --- |
| 基础文件（固定保留） | `list_files`、`find_files`、`read_file`、`search_file_content`、`write_file`、`edit_file` | 6 | 自定义模式不可关闭 |
| 附件与历史结果 | `read_attachment`、`read_reference` | 2 | 本对话存在对应资源时才出现 |
| 网页读取与搜索 | `read_web`、`search_web` | 2 | `extensions.webEnabled`；`search_web` 还要求搜索服务已启用 |
| 浏览器 | `browser_open`、`browser_snapshot`、`browser_action`、`browser_capture`、`browser_wait`、`browser_handoff`、`browser_close` | 7 | `extensions.browserPolicy` 为 `disabled` 时整组不出现 |
| 代码计算 | `execute_code` | 1 | 只读模式仍可用 |
| 工具编排 | `orchestrate` | 1 | 关闭后仍可直接调用已授权文件工具 |
| 信息确认 | `request_user_input` | 1 | 只读模式仍可用 |
| 任务计划 | `update_plan` | 1 | 只读模式仍可用 |
| 团队协作 | `team_recruit`、`team_wait`、`team_inspect`、`team_read_result`、`team_control`、`team_resume`、`team_complete_task`、`team_list_messages`、`team_read_message` | 9 | 会话启用团队后加入；员工三项只在子任务内出现 |
| 预览与小程序 | `publish_preview`、`list_mini_apps`、`publish_mini_app` | 3 | 只读模式提供前两项；小程序工具还要求实验室开关已开启 |
| 文件交付 | `present_files` | 1 | 只读模式仍可用 |
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
| `search_web` | 通过已配置搜索服务找来源 | `query` 必填（1–128 字符）；`maxResults` integer 默认 5（1–10） | 只在联网开关与搜索服务同时启用时出现；单次 60 秒；只返回结构化 `sources`，不返回搜索服务自由生成的回答 |
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
| `orchestrate` | 用异步 JavaScript 组合调用已授权工具 | `code` 必填 | 可嵌套 19 个工具（文件、附件与引用、网页与搜索、Skills 读取、MCP 发现与调用、计算、预览、小程序与文件交付）；上限 32 次调用、4 个并发宿主工具、2 秒脚本计算、120 秒总时长、32 MiB JS 内存、1 MiB 结果；子调用回执保存在父回执里，取消后未开始的子调用标为 `NOT_EXECUTED`；不支持嵌套编排 |

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

## 小程序

小程序在“设置 → 实验室 → 小程序”开启后才提供给模型，默认关闭；关闭后入口和相关工具都隐藏，已有小程序与数据保留。

| 工具 | 用途 | 参数 | 约束与回执 |
| --- | --- | --- | --- |
| `list_mini_apps` | 列出当前工作区已进入集合的本地小程序 | 无 | 返回 `appId`、标题、描述、归档状态、源文件路径、`dataPath` 与更新时间；尚未采用的试用版不列出；更新前应先查询 |
| `publish_mini_app` | 创建或更新可持久化的单页小程序 | `path` 必填（`.js`、`.html`、`.svg`）；`title` 1–160；`description` ≤1000；`appId` 更新时必填；`library` 为 `none`/`three` | 页面只允许单页；发布前用只读数据快照做启动校验，启动脚本不能写数据；更新不会覆盖清单指定的数据文件；已归档的小程序必须先恢复才能更新；回执包含 `appId`、`startup` 与 `interaction`（固定 `not_checked`） |

小程序页面通过 `tinybot.storage.load()` 取得 `{value, revision}`，在用户交互后用 `save(value, revision)` 保存；版本过期时保存失败，页面应重新加载并对齐，不能盲目覆盖。不要为临时视觉或一次性图表使用小程序，这类内容继续使用 `publish_preview`。

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
| `entry/src/main/ets/services/MemoryTools.ets` | 长期记忆操作 |
| `entry/src/main/ets/services/SkillTools.ets` | 读取 Skill 与目录 |
| `entry/src/main/ets/services/ResourceTools.ets` | Skills 与 MCP 配置管理 |
| `entry/src/main/ets/services/McpTools.ets` | 远程工具发现与调用 |
| `entry/src/main/ets/services/ChatTeamTools.ets` | 团队协调与员工交接 |
| `entry/src/main/ets/model/ToolGroups.ets` | 能力分组与只读分组 |
| `entry/src/main/ets/model/AgentMode.ets` | 自定义选择与工具开关判定 |