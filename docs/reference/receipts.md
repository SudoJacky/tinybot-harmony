# 回执与错误

工具回执（Receipt）同时服务两个读者：模型把它当作下一步的依据，界面把它当作可回看的记录。两者读到的字段并不相同，失败时尤其如此。这一页说明回执的结构、错误码的分类、重试与终止的边界，以及超时和取消在两侧分别表现成什么。回执在运行循环中的产生顺序见[工具注册与执行](/internals/tools)，工具耗时的采集口径见[性能诊断](/internals/diagnostics)。

## 回执的组成

一次工具调用在会话里保存为 `ToolExecution`：

| 字段 | 含义 | 进入模型 |
| --- | --- | --- |
| `call` | 工具名与参数的原始 JSON 字符串 | 是，作为 assistant 的 tool_call |
| `status` | `pending`、`running`、`complete`、`failed`、`cancelled`、`interrupted` 六种 | 否，由后续消息体现 |
| `output` | 工具返回的文本，通常是 JSON | 是，原样作为 tool 消息 |
| `children` | 编排子调用，最多 32 条 | 只通过父回执的汇总体现 |
| `fileDiff`、`turnFileChange` | 本次改动与整轮净变化 | 否 |
| `websiteIcon` | 网页图标地址 | 否 |
| `previewContent`、`previewScreenshot` | 预览快照与截图元数据 | 否（截图另以用户消息发送） |

参数在执行前落盘，结果在完成后落盘；两者之间进程退出，重启后该调用按状态被标记为“未执行”或“结果未知”，不会自动重放。

## 成功回执

回执内容由具体工具决定，没有统一外包层。常见形状：

| 工具组 | 典型字段 |
| --- | --- |
| 读文件、读附件、补读引用 | `path`/`id`、`content`、`startLine`、`totalLines`、`truncated`、`nextOffset`、`nextColumn` |
| 列目录 | `path`、`entries[{name, kind}]`、`truncated`、`nextOffset` |
| 内容检索 | `matches[{path, line, column, text, before, after}]`、`skipped`、`checkedFiles`、`truncated`、`nextCursor` |
| 按名检索 | `paths`、`checkedFiles`、`truncated`、`nextCursor` |
| 写文件、编辑文件 | `{path, bytes, written}` |
| 网页正文 | `url`、`title`、`content`、`links`、`offset`、`totalChars`、`nextOffset`、`truncated`、`linksTruncated`、`trust` |
| 联网搜索 | `sources[{url, title, snippet, publishedAt?}]` |
| 浏览器 | `operation`、`completed`、`userIntervened`、`page` |
| 代码执行 | `status`、`stdout`、`stderr`、`result`、`error`、`logsTruncated`、`resultTruncated`、`durationMs` |
| 工具编排 | 上述状态字段加 `calls[{callId, tool, status}]` |
| 表单 | 提交结果 JSON（含 `status` 与 `values`） |
| 计划 | 校验后的结构化对象（步骤数组） |
| 预览 | `published`、`path`、`title`、`nodes`、`screenshot` |
| 文件交付 | `files[{path, description?}]` |
| 记忆 | `success`、`receipt{added, updated, removed, duplicates, characters}`、`limit`、`memories` |
| 团队 | `runId`、`status`、`revision`、`members`、`tasks`、`results`、`afterSequence`、`hasMore` |
| MCP 调用 | 远程服务返回的原始结果对象（含 `content`、`structuredContent`、`isError`） |
| 资源管理 | `success`、`action`、`name`/`id`、`tools`、`warning`、`next` |

字段名按工具实际返回；同一工具族内命名保持一致，例如所有分页读取都用 `nextOffset`/`nextColumn`，所有检索都用 `nextCursor`。

## 失败回执

失败仍然是 tool 消息，只是内容变成统一的错误对象：

```json
{
  "error": "文件自上次读取后已变化，请重新读取再修改。",
  "code": "FS_STALE_VERSION",
  "recovery": "read_file",
  "details": { "path": "notes.md" }
}
```

- `error` 是给人看的描述，多数由工具按当前界面语言生成；`code` 是稳定标识，不随文案变化。
- `recovery` 是分类建议（如 `read_file`、`fix_arguments`、`inspect_result_before_retry`），不构成自动重试授权。
- `details` 可选，可能包含 `path`、`editIndex`（1 起）、`version`、`category`、`location`、`excerpt`、`service`、`httpStatus`、`remoteCode`、`nativeCode`、`result`。
- 未知异常兜底为 `UNKNOWN_ERROR` + `inspect_error`，保留原始描述，不按文案猜测原因。
- 代码沙箱与编排的失败保留领域回执（`status`、日志、子调用），再补上 `error`/`code`/`recovery`；MCP 的 `isError` 原始结果放在 `details.result`。

持久化失败不是工具错误：执行前的意图落盘失败会阻止本批工具启动，结果落盘失败会终止本轮，不会退化成一条可继续执行的普通错误。

## 错误码

错误码按来源分组。同一个码在不同工具中的详细文案不同，含义与恢复方向一致。

### 通用、参数与状态

| 码 | 含义 | 触发条件 | 建议恢复 |
| --- | --- | --- | --- |
| `INVALID_ARGUMENTS` | 参数不合法 | 不是 JSON 对象、缺必填项、出现未声明字段、超出枚举或范围 | `fix_arguments` |
| `INVALID_RESPONSE` | 下游返回不可解析的 JSON 或结构不符 | 协议解析、远程响应对不上预期 | `inspect_service` |
| `INVALID_RESULT` | 结果结构校验失败 | 例如交接产物缺少 `content` | `inspect_result` |
| `INTERNAL_ERROR` | 运行时装配错误 | 工具名重复、保留名称、重定向校验安装失败 | `inspect_error` |
| `TOOL_UNAVAILABLE` | 工具不可用 | 名称不存在、未启用、被当前会话关闭、员工无此工具 | `check_available_tools` |
| `LIMIT_EXCEEDED` | 超过上限 | 调用次数、响应大小、目录分页、记忆容量、交接产物 | `reduce_input` |
| `NOT_FOUND` | 找不到目标 | 附件、引用快照、Skill 参考文件、团队或交接不存在 | `check_resource` |
| `INVALID_STATE` | 当前状态不允许该操作 | 团队已停止或未保存、任务状态不符、提交交接后继续调用 | `inspect_state` |
| `INTERACTION_PENDING` | 已有待处理的用户交互 | 表单或确认框未结束 | `wait_for_user` |
| `PERMISSION_DENIED` | 权限拒绝 | 只读规则、会话关闭、浏览器策略、员工角色、手动记忆 | `check_permissions` 或 `respect_user_decision` |
| `USER_DENIED` | 用户拒绝确认 | MCP 调用确认框被拒绝 | `respect_user_decision` |
| `NOT_EXECUTED` | 调用未执行 | 本轮中断时仍为 `pending` 的调用与编排子调用 | `none` |
| `OUTCOME_UNKNOWN` | 中断时结果未知 | 中断时正在运行的调用 | `inspect_result_before_retry` |
| `CANCELLED` | 用户停止 | 运行信号取消，或沙箱返回 `cancelled` | `inspect_result_before_retry` |
| `TIMEOUT` | 超时 | 网页、搜索、MCP、浏览器或沙箱超过各自时限 | `check_connection` 或 `inspect_result_before_retry` |
| `NETWORK_ERROR` | 网络失败 | 原生请求报错，`details.nativeCode` 保留错误码 | `check_connection` |
| `NOT_CONFIGURED` | 依赖未配置 | MCP 服务未启用等 | `check_settings` |
| `AUTH_REQUIRED` | 需要凭据 | HTTP 401，或搜索服务缺少 API Key | `check_credentials` |
| `RATE_LIMITED` | 被限流 | HTTP 429 | `wait_then_check` |
| `QUOTA_EXHAUSTED` | 额度不足 | 搜索服务返回余额不足（402） | `check_quota` |
| `HTTP_ERROR` | 其他 HTTP 失败 | 非 401/403/404/429 的错误状态 | `inspect_service` |
| `EXECUTION_FAILED` | 执行失败 | 沙箱或编排返回非 `ok` 且没有更具体的分类 | `fix_code` 或 `inspect_result_before_retry` |
| `STALE_RESOURCE` | 引用的资源已变化 | 团队交接产物与提交时内容不一致 | `read_resource` |
| `EVIDENCE_REQUIRED` | 缺少用户证据 | 记忆变更没有指向当前用户消息的来源 | `provide_user_evidence` |
| `UNKNOWN_ERROR` | 未分类异常 | 抛出非 `ToolFailure` 的错误 | `inspect_error` |

### 文件与检索

| 码 | 含义 | 触发条件 | 建议恢复 |
| --- | --- | --- | --- |
| `FS_INVALID_PATH` | 路径不合法 | 绝对路径、反斜杠、`.`/`..`、超过 16 段、`.tinybot-` 前缀、越界 | `fix_path` |
| `FS_INVALID_ARGUMENTS` | 文件工具参数不合法 | 缺 `path`、写入缺 `content`、偏移或范围非法 | `fix_arguments` |
| `FS_INVALID_EDITS` | 编辑项不合法 | `edits` 为空或超过 32 项、`oldText` 为空、与 `oldText`/`newText` 混用 | `fix_arguments` |
| `FS_NOT_OBSERVED` | 修改前未读取 | 覆盖或编辑已有文件，但本轮没有成功读取或写入 | `read_file` |
| `FS_STALE_VERSION` | 文件已变化 | 读取后文件被改写，版本不匹配 | `read_file` |
| `FS_EXTERNAL_IO` | 共享目录文件操作失败 | `details.category` 指明备份、打开、写入、截断、同步或关闭阶段，`details.nativeCode` 保留系统错误码。直接写入失败可能留下部分内容，原始备份仍保留 | `inspect_error` 或 `inspect_backup` |
| `FS_MATCH_NOT_FOUND` | 原文不存在 | `oldText` 在文件中找不到 | `read_file` |
| `FS_AMBIGUOUS_MATCH` | 原文匹配多处 | `oldText` 不唯一 | `add_match_context` |
| `FS_OVERLAPPING_EDITS` | 编辑范围重叠 | 同一批编辑的区间相交 | `merge_edits` |
| `FS_INVALID_CURSOR` | 检索游标失效 | 游标过期或参数已改变 | `restart_search` |
| `FS_STALE_SEARCH` | 续页时文件变化 | 分页检索期间文件被修改 | `restart_search` |
| `FS_INCOMPLETE_LIST` | 目录无法继续列出 | 分页信息缺失或偏移没有前进 | `inspect_directory` |

### 网页、搜索与浏览器

| 码 | 含义 | 触发条件 | 建议恢复 |
| --- | --- | --- | --- |
| `UNSUPPORTED_CONTENT` | 内容类型不支持 | 非 HTML、文本、JSON/XML；二进制或编码无法解析 | `use_supported_source` |
| `CONTENT_UNAVAILABLE` | 没有可读正文 | 正文为空，可能需要登录或 JavaScript | `use_supported_source` |
| `BROWSER_UNAVAILABLE` | 浏览器不可用 | 当前环境无法提供应用内浏览器 | `inspect_error` |
| `BROWSER_BUSY` | 浏览器被占用 | 其他任务或用户仍持有浏览器 | `wait_for_owner` |
| `BROWSER_NOT_OWNED` | 没有所有权 | 未 `browser_open` 就操作，或所有权已转移 | `acquire_browser` |
| `BROWSER_CLOSED` | 浏览器已关闭 | 用户关闭或策略禁止 | `respect_user_decision` |
| `BROWSER_LOAD_FAILED` | 页面加载失败 | 导航未完成或返回错误页 | `inspect_browser` |
| `BROWSER_HISTORY_EMPTY` | 没有可回退历史 | 在首屏执行 `back` 或 `forward` | `inspect_browser` |
| `STALE_BROWSER_SNAPSHOT` | 快照已过期 | `snapshotId` 或 `elementId` 不属于最新快照 | `read_browser_snapshot` |

### 预览、MCP 与团队

| 码 | 含义 | 触发条件 | 建议恢复 |
| --- | --- | --- | --- |
| `PREVIEW_INVALID` | 预览无法发布 | 预检、编译或截图失败，`details` 带路径、版本、分类与修复建议 | `fix_preview_file` |
| `UNSUPPORTED_PREVIEW_FORMAT` | 预览格式不支持 | 提交 `.jsonl` 预览 | `write_preview_file` |
| `SCHEMA_REQUIRED` | 缺少远程工具 schema | 未先 `mcp_list_tools`/`mcp_search_tools` 就调用 | `discover_tools` |
| `REMOTE_ERROR` | 远程协议错误 | MCP 返回 JSON-RPC 错误，`details.remoteCode` 保留原始码 | `inspect_result_before_retry` |
| `REMOTE_TOOL_ERROR` | 远程工具报告失败 | 回执 `isError` 为 true，原始结果在 `details.result` | `inspect_result_before_retry` |
| `UNSUPPORTED_PROTOCOL` | MCP 协议版本不支持 | 协商结果不在受支持版本列表内 | `check_settings` |
| `HANDOFF_REQUIRED` | 缺少交接 | 员工任务结束但没有调用 `team_complete_task` | `complete_handoff` |
| `ALREADY_EXISTS` | 名称冲突 | 安装或创建 Skill 时名称已存在 | `check_resource` |

## 重试与终止

- `recovery` 只描述下一步该查什么，不会触发自动重试；远程副作用是否发生未知时，先核对再决定。
- 模型请求本身可能重试：仅在响应流开始前、遇到明确的临时传输错误或空闲超时时最多重试 2 次（间隔 1 秒、2 秒），丢弃未完成的输出；已完成的工具不会重放。
- 同一工具与规范化参数连续调用达到 3、5、8 次时，运行时追加一条提醒消息；失败调用也计数，等待员工和用户表单不计数，用户追加指令会重置计数。
- 会终止本轮的是持久化失败、请求流协议错误和用户停止；单个工具失败只产生错误回执，循环继续。
- 停止后未开始的调用标为 `cancelled` 且回执为 `NOT_EXECUTED`；正在运行的调用标为 `interrupted` 且回执为 `OUTCOME_UNKNOWN`；已经提交的写入保留，不自动回滚。
- 重启后不重放工具。历史中状态为 `generating` 的回合改为 `stopped`，并提示已完成的文件操作仍然有效。

## 模型看到什么，界面看到什么

| 内容 | 模型侧 | 界面侧 |
| --- | --- | --- |
| `output` 字符串 | 原样作为 tool 消息 | 工具行的简短预览；详情面板按“结果/参数/日志/原始记录”分页 |
| 错误对象 | 原样作为 tool 消息，含 `code` 与 `recovery` | 错误区块显示 `error`，详情保留完整字段 |
| 预览截图 | 作为额外 user 消息，附 JPEG 图片与尺寸说明 | 聊天内预览卡片与历史本地预览 |
| UI 校验失败诊断 | 作为额外 user 消息，声明为不可信诊断数据 | 失败工具详情 |
| 续跑提示、重复调用提醒 | 作为额外 user 消息 | 不单独成行，属于过程记录 |
| `fileDiff`、`turnFileChange` | 不发送 | 差异卡片、“本轮修改”汇总 |
| `websiteIcon` | 不发送 | 网页工具行的图标 |
| `previewContent`、`previewScreenshot` 字段 | 不发送（截图另发） | 预览卡片与截图预览 |

界面只投影已保存的回执：打开详情不会重新执行工具，也不会重新读文件。正文每段最多 8000 字符、列表每页最多 30 项，分页只影响展示，不改变存储内容。回执被工具自身截断时显示“工具仅返回了部分内容”，并给出续读位置。旧回执缺少当次基线时保留原有内容预览，不从当前文件反推历史差异。

## 超时与取消的表现

| 场景 | 上限 | 结果 |
| --- | --- | --- |
| 网页读取 | 30 秒 | `TIMEOUT`，状态 `failed`，提示检查网络 |
| 联网搜索 | 60 秒 | `TIMEOUT`，状态 `failed` |
| MCP 请求 | 60 秒 | `TIMEOUT`，明确“结果未知”，建议先核对服务端 |
| 浏览器页面加载 | 30 秒 | `TIMEOUT`，建议检查页面 |
| 代码沙箱 | 2 秒、32 MiB | 回执 `status` 为 `timeout` 或 `memory_limit`，分别转为 `TIMEOUT`、`LIMIT_EXCEEDED`，日志保留 |
| 工具编排 | 2 秒脚本、120 秒总时长、32 次调用、4 个并发、1 MiB 结果 | `TIMEOUT` 或 `LIMIT_EXCEEDED`，子调用状态一并保存 |
| 用户点击停止 | 立即 | 取消网络请求；未开始的调用 `cancelled`，运行中的 `interrupted` |

超时与取消都不承诺撤销远端副作用；已写入的文件保留，界面与回执都按“已发生”记录。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/model/Agent.ets` | `ToolExecution` 结构、`toolError` 错误序列化、中断标记与回执校验 |
| `entry/src/main/ets/model/ToolFailure.ets` | `ToolFailure`、`ToolResultError`、HTTP 状态分类 |
| `entry/src/main/ets/services/ToolExecution.ets` | 批量执行、执行前后落盘、状态与取消处理 |
| `entry/src/main/ets/services/Cancellation.ets` | 运行信号与 `RunCancelledError` |
| `entry/src/main/ets/services/RepeatToolReminder.ets` | 重复调用计数与提醒 |
| `entry/src/main/ets/model/ToolPresentation.ets` | 工具行标题、预览、统计与状态标签 |
| `entry/src/main/ets/model/ToolDetailContent.ets` | 详情分区、通知、8000 字符与 30 行分页 |
| `entry/src/main/ets/services/ToolApproval.ets` | 表单等待与 MCP 确认，拒绝映射为 `USER_DENIED` |
