# 工具注册与执行

Tinybot 的工具目录同时决定模型能看到哪些工具、以及哪些调用可以被执行。这页说明工具如何分组注册、`definitions()` 暴露什么、一次调用如何经过执行流水线形成回执（receipt），以及目录下发、续跑、去重和错误如何回到模型；逐项参数与返回值见[工具参考](/reference/tools)，权限与审批见[审批、权限与沙箱](/internals/permissions)。

## 目录即权限

`ToolSet` 是工具目录与执行路由的唯一入口。构造时它遍历每个分组（`AgentTools`）的 `definitions()`，把工具名映射到所属分组；同名工具会立即以 `INTERNAL_ERROR` 失败，避免两个实现争用同一个名字。

```ts
// ToolSet.ets
const group = this.entries.get(call.function.name);
if (!group) {
  throw new ToolFailure('TOOL_UNAVAILABLE', t("工具未启用或不存在：") + call.function.name, 'check_available_tools');
}
return group.execute(call, cancellation, context);
```

`definitions()` 每次调用都会重建目录。模型看到的名字集合与 `execute()` 可路由的名字集合来自同一次刷新，因此“目录里没有”就等于“不能执行”。运行时不会为未注册的名字临时构造实现。

## 组装顺序

会话资源先按配置组装分组，再依次套上只读、会话选择、编排和目录排序四层包装：

```text
SessionResources.tools()
├─ WorkspaceTools        find_files / list_files / read_file / search_file_content / write_file / edit_file
├─ AttachmentTools       read_attachment
├─ SkillTools            read_skill / list_skills
├─ InteractionTools      request_user_input / update_plan
├─ CodeExecutionTools    execute_code
├─ PresentTools          present_files
├─ PreviewTools          publish_preview
├─ WebTools              read_web              （允许联网时）
├─ BrowserTools          browser_*             （浏览器对象存在时）
├─ WebSearchTools        search_web            （联网且已配置搜索时）
└─ McpTools              mcp_list_tools / mcp_search_tools / mcp_call
        ↓
      ToolSet            目录与路由
        ↓
      RuleTools           全局只读过滤
        ↓
      SelectedTools       full / custom 选择
        ↓
      OrchestrationTools  orchestrate
        ↓
      ToolCatalog         完整授权目录，稳定排序
```

会话层还会在外侧再包一层资源管理工具和记忆工具；它们受助手设置、Skills 页面与只读规则约束，不进入下面的可选能力开关。

## 工具分组

分组是权限与选择的共同单位。`readOnly` 决定全局只读模式是否放行整组。

| 分组 | 只读 | 工具 |
| --- | --- | --- |
| `workspace-read` | 是 | `list_files` `find_files` `read_file` `search_file_content` |
| `workspace-write` | 否 | `write_file` `edit_file` |
| `context-read` | 是 | `read_attachment` `read_reference` |
| `web` | 是 | `read_web` `search_web` |
| `browser` | 是 | `browser_open` `browser_snapshot` `browser_action` `browser_handoff` `browser_close` |
| `calculation` | 是 | `execute_code` |
| `orchestration` | 是 | `orchestrate` |
| `interaction` | 是 | `request_user_input` `update_plan` |
| `delivery` | 是 | `publish_preview` `present_files` |
| `skill-read` | 是 | `read_skill` `list_skills` |
| `mcp-discovery` | 是 | `mcp_search_tools` `mcp_list_tools` |
| `mcp-execution` | 否 | `mcp_call` |
| `extension-management` | 否 | `skill_manage` `mcp_manage` |
| `memory` | 否 | `memory` |
| `team-coordination` | 是 | `team_recruit` `team_wait` `team_inspect` `team_read_result` `team_control` `team_resume` |
| `team-handoff` | 是 | `team_complete_task` `team_list_messages` `team_read_message` |

面向用户的可选能力把上述分组重新打包为 12 项，界面按“资料与检索、执行与协作、预览与交付、MCP 服务”排列。6 个基础文件工具在自定义模式固定保留，4 个记忆/Skills 入口由专门设置控制，都不在这 12 项里。

| 能力 | 分区 | 包含工具 |
| --- | --- | --- |
| `context-read` | 资料与检索 | `read_attachment` `read_reference` |
| `web` | 资料与检索 | `read_web` `search_web` |
| `browser` | 资料与检索 | 浏览器 5 个入口 |
| `calculation` | 执行与协作 | `execute_code` |
| `orchestration` | 执行与协作 | `orchestrate` |
| `user-input` | 执行与协作 | `request_user_input` |
| `plan` | 执行与协作 | `update_plan` |
| `team` | 执行与协作 | 团队 9 个入口 |
| `preview` | 预览与交付 | `publish_preview` |
| `file-delivery` | 预览与交付 | `present_files` |
| `mcp` | MCP 服务 | 发现与调用 3 个入口 |
| `mcp-manage` | MCP 服务 | `mcp_manage` |

完整版（`full`）在注册与只读过滤之后放行全部工具；自定义（`custom`）按能力整组关闭。`toolEnabled()` 对基础文件工具、记忆/Skills 工具始终返回真，其余名字按所属能力判断：能力内任一工具被禁用，整组都不再执行。保存的禁用列表会被 `normalizeDisabledTools()` 归一化为整组，旧配置只关闭部分成员时加载为整组关闭。同一限制同时作用于直接调用、编排子调用和团队员工。

旧存档中已移除的 `generate_image`、`read_tool_result` 禁用记录会在加载时清除。`publish_data_view` 已移除；其旧禁用项迁移为 `publish_preview`，继续保留原有预览能力开关。旧工具发现记录不会恢复已移除入口；历史图表回执仍支持展示、CSV 导出及会话导出。

MCP 已接受的完整工具结果保存在会话回执中，并原样进入模型请求；框架不再生成首尾预览或提供 `read_tool_result` 分页补读。超大结果同时占用上下文、内存与磁盘，仍受网络层和远端服务自身限制。编排子回执保留在工具详情并参与压缩时的文件操作证据汇总。

## definitions() 暴露的结构

每个工具定义包含协议字段与两个本地提示字段：

| 字段 | 作用 | 是否发给模型协议 |
| --- | --- | --- |
| `type` / `function.name` | 调用名 | 是 |
| `function.description` | 何时使用、边界 | 是 |
| `function.parameters` | JSON Schema，含 `required` 与 `additionalProperties` | 是 |
| `executionMode` | `parallel`（默认）或 `sequential` | 否 |
| `promptSnippet` | 一行用途，进入运行时快照的工具清单 | 否 |
| `promptGuidelines` | 使用规则，进入 `tool_guidelines` 片段 | 否 |

`toolSchemas()` 在发送前只保留 `type` 与 `function`，提示字段不会混入 provider 请求。标记为 `sequential` 的工具会让**整批**调用串行：任一步出现写文件、编辑、交互与数据展示、预览发布、编排或任一 MCP 工具，该步其余调用都排在后面执行。

## 执行流水线

一次工具批次由 `executeToolBatch()` 驱动，顺序固定为“保存意图 → 执行 → 写回结果 → 保存结果”：

```text
模型流完整结束
  → 校验 tool_calls：≤ 8 个、ID 唯一、参数 ≤ 96×1024 字符（execute_code 除外）
  → prepare：全部状态置 running，先 checkpoint 保存意图
  → execute：解析参数 → ToolSet 路由 → 工具实现
  → post：写回 output 与 status，记录耗时与诊断
  → checkpoint：保存结果
  → stepMessages：assistant 消息 + 每个 tool_call_id 的结果消息
```

- 默认并行执行同一步的多个工具；整批中任一工具为 `sequential`，或调用方指定串行模式时，改为逐个“保存意图 → 执行 → 保存结果”。
- 工具正常返回字符串即视为完成，空字符串也算完成；抛出的异常交给 `toolError()` 归一化为 `{error, code, recovery, details}`，状态记为 `failed`；取消记为 `cancelled`。
- 保存意图失败会把状态退回 `pending` 并终止该批，不会带着未落盘的意图执行副作用。持久化失败以独立错误终止本轮，不会被当成普通工具错误交给模型继续。
- 停止发生在工具完成之后时，已完成的结果仍会保存，不会因为取消而丢弃。
- 执行前若有执行门（`ExecutionGate`，由浏览器会话实现），批处理会先等待门放行；工具完成后还会再等一次并刷新回执，因此用户接管浏览器后模型看到的是新快照。
- 诊断开启时，工具开始与结束各记一条事件，只含轮次、参数字符数、结果字符数与失败/取消标记，不含正文。

## 默认完整工具目录

模型从首次请求起直接获得所有已启用、已配置且通过权限过滤的工具 schema 与使用说明，包括文件、计算、浏览器、交互、预览、文件交付、MCP 包装入口及当前角色允许的团队工具。目录按名称稳定排序，不再根据本轮调用或旧发现记录逐步扩展。`tool_search` 默认不提供。

工具目录仍受只读、会话能力开关、角色、资源是否存在和服务配置约束。Skills 和记忆工具继续由对应设置控制。停用或撤销的工具不会因为旧消息调用过而重新出现；附件和引用入口只在有对应资源时加入。

普通工具调用不会改变顶层声明集，也不需要一次发现请求。首次请求会携带更多 schema；同一授权目录下后续请求保持一致，避免因按需加载工具而重建 provider 缓存前缀。用户修改能力配置、服务或角色时，目录仍会相应变化；不承诺固定缓存命中率。

旧 `tool_search` 回执保留为普通历史记录，默认运行与上下文检查不再解析它们来决定可见性。BM25 发现模式及延迟加载状态已移除；`ToolCatalog` 统一排序当前已授权工具，并明确拒绝新的 `tool_search` 调用。编排子调用的白名单、调度、持久化、参数校验和审批保持原有规则。

## 可视化与交付编排

`orchestrate` 允许调用 `execute_code`、`publish_preview`、`present_files`，与文件、资料读取工具共用当前授权目录。可以顺序完成“读取 → 计算检查 → 写文件 → 发布 → 交付”，无需为每个依赖步骤重新请求模型。依赖步骤必须 `await`；未捕获的失败会停止脚本，禁止把已失败的写入当成发布依据。

预览、图表与交付使用原来的子调用回执。`toolReceipts()` 统一读取顶层调用及当前工作区中的一层编排子调用，供聊天展示、截图回传、版本选择、文件交付、导出和备份使用。不会展开团队员工的独立工作区。源文件内容不复制进模型结果，编排应返回简短的发布回执和路径；截图作为独立图像消息送入下一次模型请求。

预览发布回执包含 `reference`，编排需把它返回给模型，再由模型在最终回复的插入位置独占一行复制。工具阶段不自动挂载新预览；turn 成功结束后才在正文引用位置展示无外框页面。旧回执保留历史展示。

子调用仍逐项保存意图和结果，遵守串行边界、只读与自定义权限。外层编排失败或取消不撤销已成功的子发布；失败的发布不会产生卡片。修复时按失败回执读取当前版本、局部编辑并重新发布，避免重复已有成功副作用。

## beforeFinish 续跑

模型某一步不再调用工具时，循环会询问工具的 `beforeFinish()`。`ToolSet` 逐个询问分组，把非空文本用空行拼接返回。当前实现该钩子的是聊天团队：它取出本轮触碰过的团队运行，等待并分页读取尚未确认的交接，返回“员工交接已保存”的续跑提示，附带数据页。

续跑文本写入 `step.continuation`，随该步一起落盘，并作为一条 user 消息进入下一次请求，不是新的系统指令。若已到本轮模型调用上限，循环不再续跑，而是报错说明团队结果已保存、需要用户继续。

## 重复调用提醒

`RepeatToolReminder` 在一次运行内跟踪连续相同的调用。键由工具名与规范化 JSON 参数组成：对象键排序、数组保持顺序，解析失败时退回原始参数文本。

| 规则 | 行为 |
| --- | --- |
| 计数对象 | 状态为 `complete` 或 `failed` 的调用；编排调用按子调用逐个计数 |
| 不计数 | `team_wait`、`request_user_input`，以及 `pending`/`running`/`cancelled`/`interrupted` 的调用 |
| 触发点 | 连续第 3、5、8 次 |
| 重置 | 用户追加指令、运行结束 |
| 效果 | 追加一条提醒消息，要求检查进展、换方法或说明阻碍；不阻止调用、不自动重放 |

提醒文本只带工具名，不带参数正文，避免把大参数复制进上下文。

## MCP 工具接入

`McpTools` 把一个 MCP 服务暴露为三个工具，远端工具不会按名称自动变成独立工具：

| 工具 | 作用 | 约束 |
| --- | --- | --- |
| `mcp_list_tools` | 读取远端工具目录与 schema | 每个服务最多 10 页、200 个工具 |
| `mcp_search_tools` | 按关键词筛选目录 | 空格分词，返回最多 12 项；空查询报 `INVALID_ARGUMENTS` |
| `mcp_call` | 调用已发现的远端工具 | 必须先读目录，否则 `SCHEMA_REQUIRED`；每次调用单独确认 |

目录输出超过 48000 字符时只返回工具名清单，提示改用检索。客户端按服务配置 JSON 缓存：服务地址、名称、凭据别名或启停状态变化后，旧客户端与已读目录一起失效。

`McpClient` 负责协议层：`initialize` 协商版本并接受 `2025-03-26`、`2025-06-18`、`2025-11-25`，发送 `notifications/initialized`；从响应头读取 `Mcp-Session-Id`；404 清空会话与初始化状态；请求超时 60 秒，响应上限 1 MiB；取消时对 `tools/call` 发送 `notifications/cancelled`，但明确不承诺远端副作用已撤销。`isError` 回执转为 `REMOTE_TOOL_ERROR`，完整结果保存在 `details.result`。

## 错误分类

工具失败统一保留 `error`、稳定 `code`、`recovery` 与可选 `details`。分类在知道原因的工具或适配层完成，未知异常回退为 `UNKNOWN_ERROR`，不按文案猜测。

| 来源 | 代码 |
| --- | --- |
| 参数与未知工具 | `INVALID_ARGUMENTS` `TOOL_UNAVAILABLE` `INTERNAL_ERROR` |
| 权限与用户决定 | `PERMISSION_DENIED` `USER_DENIED` `INTERACTION_PENDING` |
| 文件 | `FS_INVALID_PATH` `FS_INVALID_ARGUMENTS` `FS_INVALID_EDITS` `FS_NOT_OBSERVED` `FS_STALE_VERSION` `FS_MATCH_NOT_FOUND` `FS_AMBIGUOUS_MATCH` |
| 执行与预算 | `LIMIT_EXCEEDED` `TIMEOUT` `NOT_EXECUTED` `OUTCOME_UNKNOWN` `CANCELLED` |
| 远端与网络 | `AUTH_REQUIRED` `RATE_LIMITED` `HTTP_ERROR` `NETWORK_ERROR` `REMOTE_ERROR` `REMOTE_TOOL_ERROR` `SCHEMA_REQUIRED` |
| 预览 | `PREVIEW_INVALID` `UNSUPPORTED_PREVIEW_FORMAT` |
| 通用 | `NOT_FOUND` `INVALID_RESPONSE` `UNSUPPORTED_PROTOCOL` |
| 兜底 | `UNKNOWN_ERROR` |

HTTP 状态在适配层按数值分类：401 → `AUTH_REQUIRED`，403 → `PERMISSION_DENIED`，404 → `NOT_FOUND`，429 → `RATE_LIMITED`，其余 → `HTTP_ERROR`，并带上 `service` 与 `httpStatus`。

状态与代码语义严格区分：`USER_DENIED` 表示用户拒绝，`CANCELLED` 表示等待被停止，`NOT_EXECUTED` 表示从未开始，`OUTCOME_UNKNOWN` 表示中断后结果未知。恢复建议只是给模型的提示，不授权自动重试；结果未知的写入或远端调用必须先核对。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/ToolSet.ets` | 目录刷新、同名检查、执行路由、`beforeFinish` 聚合 |
| `entry/src/main/ets/services/ToolExecution.ets` | 批处理、意图与结果检查点、执行门、诊断与用量活动 |
| `entry/src/main/ets/services/ToolCatalog.ets` | 完整授权目录稳定排序；拒绝已退役的工具搜索入口 |
| `entry/src/main/ets/services/SelectedTools.ets` | full/custom 选择的目录与执行双重过滤 |
| `entry/src/main/ets/services/RuleTools.ets` | 全局只读过滤 |
| `entry/src/main/ets/model/ToolGroups.ets` | 分组、能力、基础与受管工具清单 |
| `entry/src/main/ets/model/AgentMode.ets` | 模式校验、`toolEnabled`、禁用列表归一化 |
| `entry/src/main/ets/services/AgentLoop.ets` | 轮次、工具批次调用、续跑与提醒接入 |
| `entry/src/main/ets/services/RepeatToolReminder.ets` | 连续调用计数与提醒文本 |
| `entry/src/main/ets/services/McpTools.ets` | MCP 目录、检索、调用与审批 |
| `entry/src/main/ets/services/McpClient.ets` | Streamable HTTP、会话、超时、取消与错误映射 |
| `entry/src/main/ets/model/ToolFailure.ets` | 失败类型、HTTP 分类与回执错误构造 |
| `entry/src/main/ets/services/OrchestrationTools.ets` | 嵌套工具目录、子调用并发与子回执 |
