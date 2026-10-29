# 会话与持久化

这一页说明谁拥有会话（Session）数据、哪些命令能改它、待发送队列（queue）如何调度，以及会话如何以 v2 布局原子落盘、在中断后如何恢复。

## SessionService 的职责

`SessionService` 是会话数据的唯一所有者。它不导入 ArkUI，也不导入平台 Kit，只依赖四类注入对象：

| 依赖 | 接口 | 提供的能力 |
| --- | --- | --- |
| 仓库 | `SessionRepository` | `load()`、`save(data, changedThreadIds?)` |
| 运行内核 | `AgentRuntime` | 单次运行、订阅、取消、等待收尾 |
| 凭据 | `CredentialVault` | `read` / `write` / `remove`，供服务配置与 MCP 使用 |
| 资源 | `SessionResources` | 工作区、工具、账号预检、Skill/MCP 安装、错误上报 |

```ts
export interface SessionRepository {
  load(): Promise<AppData>;
  // 省略 changedThreadIds 表示全量保存；否则未变化的会话复用上次内容。
  save(data: AppData, changedThreadIds?: string[]): Promise<void>;
}
```

它负责：命令准入、待发送指令与逐项执行、会话增删改查与分支、设置提交、上下文压缩、记忆提炼、标题生成、检查点保存。平台实现（文件、工作区、网络、安全存储、账号）都在 `NativeSessionResources` 与 `NativeSessionService` 中。

## 命令准入

会话分别持有 `ThreadExecution`（由 `AgentRuntime.fork()` 创建），应用状态负责加载、共享设置写入和保存错误。`SessionState` 投影选中会话，并附带 `runningThreadIds`、`canNavigate` 和全局配置兼容提示。

| 判断 | 条件与用途 |
| --- | --- |
| `canNavigate` | 应用就绪、共享提交空闲且没有保存错误；允许在其他会话运行时切换或新建会话 |
| `canMutate` | 满足导航条件且选中会话空闲；允许当前会话修改 |
| `canMutateShared` | 满足导航条件且所有会话均无活动任务；允许修改共享配置 |
| `canQueueInput` | 满足导航条件、当前会话未归档且处于空闲或运行阶段；允许追加与排队 |

`mutate(prefix, action, publication, scope)` 按共享、会话或导航作用域准入，使用统一写入队列提交候选数据，补存期间产生的草稿。保存错误保留并停止所有活动任务，显式重试成功后才恢复准入。兼容检查保留未来版本的未知配置字段，对不支持的功能禁用运行并展示提示，不改写原始配置。

`send`、`stop`、`compactHistory`、`enqueueInput`、`resumeQueue` 不走 `mutate`：它们会进入 `running` 或 `compacting`，失败信息直接写到 `status.error`。发送、压缩、重新生成、恢复队列与表单续跑在开始前还会调用 `resources.authorizeGeneration()`（原生实现为华为账号 `requireLogin()`）。

仅有附件或会话引用时也可以发送，用户消息正文保持为空，不补写默认分析或参考指令；`/team`、`@team` 携带附件而未附任务文字时同样不补写。正文为空的首条消息保留当前会话标题，不触发基于文本的标题生成。

## 状态与事件

`SessionState` 对界面公开的阶段：

| phase | 含义 |
| --- | --- |
| `idle` | 可接受修改命令 |
| `loading` | 正在加载仓库 |
| `saving` | 设置或元数据提交中 |
| `running` | 任务执行或队列调度中 |
| `compacting` | 手动或自动压缩中 |
| `memory` | 记忆提炼中 |

`subscribe()` 发布的 `SessionEvent` 按用途区分，避免每个增量都复制完整历史：

| kind | 负载 | 说明 |
| --- | --- | --- |
| `snapshot` | `data`（深拷贝） | 结构性变化：新建、删除、切换、导入 |
| `preferences` | `preferences` | 配置、扩展与产品数据，不含聊天记录 |
| `thread` | `thread`（仅元数据，`messages: []`） | 队列、草稿、模型选择等会话级变化 |
| `message` | `message`（深拷贝） | 完整的助手消息，含步骤与工具回执 |
| `text` / `reasoning` | `content`、`step`、`stepContent` | 流式正文与思考增量 |
| `draft` | `content` | 草稿单独推送，不复制历史 |
| `state` | `state` | 阶段、错误与上下文统计变化 |
| `teams` | `teams` | 团队运行状态 |

监听器抛出的异常由 `emit()` 捕获并上报 `observer_failed`，不会中断其他监听器或运行。

## 待发送指令与队列调度

执行期间输入框仍可用，指令以两种模式进入队列：

| 模式 | 语义 | 进入模型的时机 |
| --- | --- | --- |
| `steer`（追加指令） | 沿用 Pi 的 steering 语义，不打断当前工具 | 当前模型响应与整批工具完成后，下一次模型请求前 |
| `followUp`（加入队列） | 独立的新任务 | 当前任务成功结束并保存后 |

边界固定为每段对话最多 20 条、每条最多 24000 字符（`MAX_PENDING_INPUTS`、`MAX_INPUT_TEXT`）。`enqueueInput` 会拒绝以下情况：保存错误或阶段不允许、草稿为空、带会话引用、运行中发送 `/compact`、本轮已停止或正在结束时指定 `steer`、运行中用 `/skill:` 显式切换 Skill。入队成功后清空草稿与附件，并在非运行状态下把 `queuePaused` 置为 `true`，等待用户点“继续队列”。

调度规则集中在 `nextPendingInput()`：

- 队列暂停时不返回任何指令。
- 未暂停时优先返回 `steer`，否则返回最早入队的一条。
- 只取追加指令的调用（`steeringOnly`）在无 `steer` 时返回 `undefined`。

`runTasks(initial)` 先执行首条消息，再循环取队列直到为空、被暂停或保存出错。每条任务都作为独立的用户/助手轮次执行，各自拥有 200 次模型调用上限与独立的上下文预算；队列不会清空另行输入的草稿。追加指令被消费时，`consume(id)` 与历史写入在同一次检查点完成，因此不会出现“已进历史但仍在队列”的重复。

`stop()` 把 `queuePaused` 置为 `true`、停止团队、取消恢复操作并 `runtime.abort()`，随后保存当前状态。模型失败、保存失败与用户停止都会暂停后续任务；重启后带待发送指令的会话一律恢复为暂停，需要显式继续。`removePendingInput(id, edit)` 可以撤回尚未开始的指令；选择编辑时若已有新草稿会先要求处理草稿。

## 检查点与保存失败

检查点（checkpoint）是运行过程中唯一要求等待的写入。`persist(threadId?)` 是所有检查点的落点：

1. 若存在进行中的提交，先等它完成。
2. 同步一次空会话偏好，记录当前 `draftRevision`。
3. 调用 `repository.save()`：指定 `threadId` 时只写该会话、空会话偏好与脏草稿；不指定时全量保存。
4. 保存期间草稿版本未变才清空 `dirtyDrafts`，否则保留给下一轮补写。
5. 成功时清空 `saveError`。

失败时：

- 写入 `saveError`（“会话尚未保存，请重试保存。当前内容仍保留在页面中。原因：”加具体错误），停止团队，运行中则暂停队列并 `runtime.abort()`。
- 上报 `save_failed`，发布 `state`，并向调用方抛出错误，使运行以 `failed` 收尾。
- 保存失败会关闭 `canMutate` 与 `canQueueInput`，因此不会在未落盘的状态上继续开新任务。

恢复入口是 `retrySave()`：仅在 `idle` 阶段执行，重写脏草稿并保留显式错误供用户看到；运行侧如何触发检查点见[轮次、流式与重试](/internals/agent-loop)。草稿输入由 `ChatViewModel` 做 800 ms 防抖，防抖结束后调用 `flushDraft()`；`flushDraft()` 在 `saving` 或存在 `saveError` 时直接返回，避免与设置提交争抢同一条保存通道。

## 会话数据模型

`ThreadData` 中与调度和持久化相关的字段：

| 字段 | 含义 |
| --- | --- |
| `messages` | 用户/助手成对的消息记录；长度必须为偶数且角色交替 |
| `draft`、`attachments`、`references` | 输入区草稿、附件与会话引用 |
| `pendingInputs`、`queuePaused` | 待发送指令与队列暂停标记 |
| `modelRef`、`reasoningEffort` | 本会话的模型与推理强度 |
| `agentMode`、`disabledTools` | 工具选择 |
| `compaction` | 上下文压缩检查点 |
| `titleEdited`、`pinned`、`archived` | 标题归属与列表状态 |
| `parentThreadId`、`parentMessageId` | 分支来源 |
| `teamEnabled`、`teams` | 团队开关与运行记录 |

`parseAppData()` 在加载时校验这些字段；任何一项不合法都会拒绝整份数据并保留原文件，而不是丢弃部分会话。

## 存储布局与迁移

```text
<filesDir>/                    会话仓库根目录
  sessions-v2/
    index.json                 清单：version 2 + 非会话元数据 + threads[{id, file}]
    <uuid>.json                每个会话一个独立文件
  tinybot-v1.json              旧版单文件会话，迁移后保留

<applicationFilesDir>/         应用级工作区根目录
  workspace/
    <会话 ID>/                 普通会话工作区
    project-<项目 ID>/         项目共享工作区
```

- 启动时若 `sessions-v2/index.json` 不存在：读取旧版 `tinybot-v1.json`（不存在则用空数据），随后立即按 v2 保存。
- `index.json` 的 `version` 必须为 2，`threads` 必须是数组；文件名必须匹配 `^[a-zA-Z0-9-]+\.json$`，且文件内 `thread.id` 必须与索引一致，否则报“会话索引与内容不一致”。
- 旧版数据格式版本 1 与 2 都可读取，读入后统一升级为 2。缺少 `providerProfiles` 时由当前 `config` 迁移出一份服务配置；迁移发生时会把已配置的模型补写到各会话的 `modelRef`。
- 旧版 `tinybot-v1.json` 不会被删除，可用于人工回溯。

## 原子写入

`ConversationStore` 的提交分两步：内容文件先落盘，索引最后切换。

1. `save()` 在任何排队 IO 之前同步捕获待写内容。省略 `changedThreadIds` 或上次捕获失败时全量序列化，否则未变化的会话复用上次的字符串。
2. 捕获结果进入 `pendingSave` 队列，写盘串行执行；某次失败只影响该次调用，但会把下一次保存标记为需要全量重写。
3. 提交时逐个会话比较文本：文件名不存在或内容变化才写入新的 `<uuid>.json`，未变化的会话继续引用旧文件。
4. 写出 `index.json.tmp`，再用 `fs.rename` 覆盖 `index.json`。重命名是提交点，读者要么看到旧索引，要么看到新索引。
5. 更新内存中的文件映射，删除不再被引用的旧会话文件；删除失败只留下无引用孤儿，不影响读取。
6. 每次写文件都循环写满字节、调用 `fsync` 后再关闭；写入不足会直接报错，不会产生“看似成功”的半截文件。

`commitCandidate()` 同时只允许一个提交在途，重入会抛错，避免两个设置提交互相覆盖。

## 标题生成

首条用户消息保存后，后台为本轮生成标题：

- 触发条件由 `shouldGenerateTitle()` 判断：未手动改名、未归档、尚无消息、标题仍是默认的“新对话 / New chat”。
- 起名请求通过 `runtime.fork()` 执行，`contextOnly` 且工具目录为空；只发送 `CONVERSATION_TITLE_PROMPT` 与本次输入的前 4000 字符，不携带历史。提示词要求使用与输入相同的语言，输出 6–12 个汉字或 3–7 个英文词。
- 结果经 `sanitizeConversationTitle()` 取首个非空行、去掉引号、Markdown 标记与结尾标点，最多 28 字符。
- 写入前先等到前台 `phase === 'idle'`，再校验会话仍存在、未归档、未手动改名、标题仍是回退值、首条消息 ID 未变；任一不满足就丢弃结果。
- 提交时只写目标会话（外加当时的脏草稿），不复制或重新投影其他会话；写入期间的新输入用同一保存通道补写。
- 失败只上报 `title_failed`，保留由首句生成的 32 字符回退标题；起名不阻塞回答，也不会改写已归档或已删除的会话。

## 中断运行标记

进程退出或运行被中断后，加载阶段主动消除“假完成”：

- 状态为 `generating` 的助手消息改为 `stopped`，并写入“应用退出时执行尚未完成。已完成的文件操作会保留；可继续发送指令。”
- `interruptTools()` 把未开始的工具标为 `cancelled`（`NOT_EXECUTED`），把执行中的工具标为 `interrupted`（`OUTCOME_UNKNOWN`），提示再次写入前先检查文件。
- 带 `pendingInputs` 的会话强制 `queuePaused = true`，加载过程不会自动恢复执行。
- 历史回放 `requestHistory()` 只重放完整步骤与工具结果；未完成回答的正文被排除，但会追加一条说明，要求模型不要假设文件操作已回滚。团队运行由 `recoverTeams()` 做对应恢复。

## 备份与恢复接缝

备份与恢复都在 `SessionService` 的入口上完成，模型与存储不感知具体来源：

- `createBackupFile()` 深拷贝快照，保留用户文档，清空公开模型服务与 MCP 的密钥别名、把服务置为停用；模型 API Key 及其服务绑定另存到 OpenID 派生密钥加密区。再通过 `BackupArchive` 分块打包附件与工作区原始字节（容量、索引和文件数量不设应用固定上限，实际受设备资源约束）。
- `importSnapshot()` 先丢弃与本地重复的会话 ID，再调用 `prepareBackupServices()`：协议与基础地址能明确匹配的服务沿用本地 ID；无法匹配的新增为停用、无密钥的副本，并重写会话、消息与团队记录中的 `modelRef`。MCP 服务按 URL 同样处理。
- `BackupKeys` 解密后的密钥通过 `WeakMap` 随导入对象仅在内存中传递，不放进可序列化的 `AppData`。`commitBackupKeys()` 为新增模型服务恢复经认证的原始配置、写入安全存储；提交失败删除新增别名，已匹配的本机服务与密钥始终保留。无加密区的旧备份沿用停用副本流程。
- 用户文档只在本机为空时恢复；Skills 按名称去重；记忆按 ID 去重，模板按 ID 或名称加内容去重，MCP 服务直接追加；工作区目录逐个补齐后才提交。
- 提交走 `commitSettings()`，与普通设置共用原子保存与回滚路径。

使用说明见[云备份](/guide/cloud-backup)，磁盘布局细节见[磁盘布局](/reference/storage)。

## 内存索引边界

当前实现是“启动全量加载、内存维护索引”：

- `load()` 会读取并解析 `index.json` 与每个会话文件，把所有消息放进内存；同时保存三张映射：会话到文件名、会话到已序列化文本、以及上次捕获的文本。
- 保存只重写真正变化的会话文件，但索引始终整体生成并切换；未变化会话不会产生新的磁盘写入。
- 界面按批展示（默认最近 60 条消息），搜索也在内存中的会话集合上执行；分页限制的是渲染与查询结果，不是磁盘读取范围。
- 目前没有按磁盘分页加载历史的路径，因此会话很多或单会话历史很长时，启动解析与常驻内存会随数据量增长。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/SessionService.ets` | 命令准入、队列、检查点、标题与恢复 |
| `entry/src/main/ets/services/SessionContracts.ets` | 仓库、资源、状态与事件契约 |
| `entry/src/main/ets/model/ConversationStore.ets` | v2 索引、独立会话文件、原子保存 |
| `entry/src/main/ets/model/Conversation.ets` | 数据结构、历史回放与加载校验 |
| `entry/src/main/ets/model/PendingInput.ets` | 待发送指令结构与调度顺序 |
| `entry/src/main/ets/model/ConversationTitle.ets` | 标题提示词、截断与清洗 |
| `entry/src/main/ets/model/BackupRestore.ets` | 恢复时的服务与 MCP 重映射 |
| `entry/src/main/ets/services/Backup.ets` | 备份封装与资源打包 |
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` | 草稿防抖与命令转发 |
