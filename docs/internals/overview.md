# 架构总览

这一页说明一次请求（request）经过哪些层、每层能做什么、依赖朝哪个方向流动，以及哪些不变量（invariant）不能破坏。具体子系统的实现细节见各 internals 页面。

## 分层

工程使用 Stage 模型与 ArkUI V1 状态管理。代码按“界面 → 投影 → 会话服务 → 运行内核 → 模型接入”分层，平台能力集中在最外层的原生组装入口。

| 层 | 代表文件 | 职责 | 明确不做 |
| --- | --- | --- | --- |
| ArkUI 页面与视图 | `pages/Index.ets`、`views/ChatPanel.ets`、`views/ThreadList.ets` | 声明式界面、导航、弹层与动效、原生能力入口 | 不读写会话数据，不读取凭据或工具 |
| ViewModel | `viewmodel/ChatViewModel.ets`、`viewmodel/SessionViewModels.ets` | 把 `SessionEvent` 投影为 `@Observed` 状态；持有编辑器草稿与输入防抖 | 不访问文件、凭据、工具或运行时 |
| 会话服务 | `services/SessionService.ets` | 会话（Session）数据的唯一所有者：命令准入、待发送队列、检查点、压缩、设置提交 | 不导入 ArkUI 或平台 Kit |
| 运行内核 | `services/AgentRuntime.ets`、`services/AgentLoop.ets` | 单次运行的生命周期、模型/工具循环、重试、取消与收尾 | `runAgentLoop` 不接触 ViewModel、凭据、注册表或 UI |
| 模型接入 | `services/providers/*` | 显式注册、配置绑定、协议请求转换、流式解析 | 不持有 UI 状态；凭据仅在每次请求前读取 |

依赖方向如下。箭头表示“调用或读取”，反向只允许通过事件或接口回调。

```text
ArkUI 页面 → ChatViewModel → SessionService → AgentRuntime → runAgentLoop
                 ↑               ↓                              ↓
             状态投影         会话 / 队列                    ModelSession
                              ↓                              ↓
                         SessionRepository              ModelProvider
                              ↓                              ↓
                         ConversationStore              协议与网络适配

NativeSessionService：组装原生文件、工作区、凭据、网络和 ProviderRegistry
```

- 向下只调用接口：`SessionRepository`、`SessionResources`、`ModelSession`、`AgentTools`，因此测试可以替换仓库、模型与资源。
- 向上只发事件：`SessionService.subscribe()` 发布 `SessionEvent`，`AgentRuntime.subscribe()` 发布 `AgentEvent`；两者都是同步回调，只用于更新界面。
- 平台能力收在 `NativeSessionService`、`NativeWorkspaceFiles`、`NativeWebTransport`、`NativeDiagnosticLog`、`HuaweiAccount` 等适配器中。

## 组装入口

`createNativeSessionService()` 是原生组合根，按顺序创建并注入依赖：

| 依赖 | 实现 | 注入对象 |
| --- | --- | --- |
| 会话仓库 | `ConversationStore(filesDir)` | `SessionService` |
| 运行内核 | `AgentRuntime(providers, credentials, usage, validateAnswer, orchestrator, gate?)` | `SessionService` |
| 凭据 | `CredentialStore` | `AgentRuntime`、`ProfileSettings`、`McpSettings` |
| 资源 | `NativeSessionResources` | 工作区、工具集、Skill/MCP 安装、错误上报 |
| 模型服务注册表 | `ProviderRegistry(() => huaweiAccount.requireLogin())` | 注册、绑定与每次请求前的账号预检 |

`SessionService` 的构造函数只接收四类依赖：`SessionRepository`、`AgentRuntime`、`CredentialVault`、`SessionResources`。测试里使用真实 `AgentRuntime` 搭配可控模型与存储，验证队列、收尾保存、停止与恢复等行为，因此会话服务并不要求真机或真实密钥。

## 关键不变量

| 不变量 | 含义 | 落点 |
| --- | --- | --- |
| 会话单一所有者 | 只有 `SessionService` 修改 `AppData`；界面拿到的是 `snapshot()` 深拷贝，或只含元数据的 `thread` 事件 | `SessionService.snapshot()`、`publishThread()` |
| 绑定后不可变 | `bind()` 固定 provider 实例、地址、模型和凭据别名；注册表或设置改动只影响后续运行 | `ProviderRegistry.bind()`、`BoundModel` |
| 模型可见即已记录 | 进入模型请求的历史都先经过检查点；历史回放只取完整步骤与工具回执，中断的正文不进入上下文 | `requestHistory()`、`AgentLoop` |
| 检查点时机固定 | 运行开始、追加指令并入历史、重试状态切换、工具批次前后、压缩前后、运行收尾 | `AgentRuntime.run()`、`executeToolBatch()` |
| 事件同步、持久化异步 | 订阅回调只做同步投影；必须等待的写入放在 `checkpoint` 钩子里 | `AgentRuntime.subscribe()` |
| 停止不撤销已提交效果 | 取消只阻止后续步骤；已完成写入的工具结果保留并回放给模型 | `interruptTools()`、`ToolExecution` |

## 一次请求的时序

```text
用户点发送
  ChatPanel → ChatViewModel.send(onUpdate)            只转发命令，不组装数据
    → SessionService.send()
         预检 canMutate、华为账号授权；/compact 与团队命令先分流
    → runTasks(initial) → runTask(thread, text)
         解析当前模型（modelRef → ModelConfig）
         组装指令段：身份 + 运行规则 + 用户文档 + Skills + 记忆 + 工作区 + 团队
         组装工具目录：SelectedTools(ToolSet(...))
         追加 user / assistant 消息；answer.status = generating
         订阅 AgentRuntime 事件
    → AgentRuntime.run(request, hooks)
         冻结 config、工具选择与历史副本
         ProviderRegistry.bind() → BoundModel（provider 实例、地址、模型、凭据别名）
         checkpoint()                     首条用户消息落盘
         prepare(cancellation)            补齐工作区；必要时后台生成标题
         prepareContext(...)              传入压缩钩子
    → runAgentLoop(context, cancellation, observer)
         每轮：读取追加指令 → RequestContext.prepare() → 预算/压缩检查
         BoundModel.stream() → ProtocolProvider.stream() → ChatStream 等解析器
         校验工具调用；无工具且无后续输入则结束
         executeToolBatch()               意图落盘 → 执行 → 结果落盘
         stepMessages() 追加到下一轮请求
    → 收尾：run_finishing → checkpoint() → run_end
    → 事件 text / reasoning / message → ChatViewModel.project() → ArkUI 刷新
```

检查点不是“保存界面”，而是保存模型可见状态：`runTask` 把 `checkpoint` 实现为 `publishThread()` 加 `persist(thread.id)`；持久化失败会设置 `saveError`、暂停队列并中止本次运行。

## 三条数据流

同一份状态在层之间以三种方式流动，混用会造成难以排查的覆盖问题。

| 流 | 方向 | 载体 | 约束 |
| --- | --- | --- | --- |
| 命令流 | 视图 → ViewModel → SessionService | 方法调用（`send`、`enqueueInput`、`stop`、`selectModel` 等） | 由 `canMutate` / `canQueueInput` 准入；失败返回布尔值或写入 `status.error` |
| 事件流 | SessionService → ViewModel → 视图 | `SessionEvent`（含脱离内部数据的快照） | 同步回调；监听器抛错由 `SessionService.emit()` 捕获并上报，不影响其他监听器 |
| 持久化流 | SessionService → SessionRepository → 文件 | `save(data, changedThreadIds?)` | 仓库在调用时同步捕获待写内容，写盘按队列串行执行 |

运行内核另有自己的事件流 `AgentEvent`：`run_start`、循环事件（`step_start`、`text_delta`、`reasoning_delta`、`model_end`、`tool_start`、`tool_end`、`step_end`、`request_retry`）、`run_stopping`、`run_finishing`、`run_end`。`SessionService` 订阅它，把增量投影成 `text` / `reasoning` / `message` 事件，再交给 ViewModel。

## 并发与等待

- `AgentRuntime.run()` 一次只允许一个活动任务；重入会直接抛错。标题生成、记忆提炼与团队员工使用 `fork()` 得到独立实例，因此不会与主任务争抢活动槽位。
- `AgentRuntime.waitForIdle()` 等待本轮收尾（含最终检查点）；`SessionService.waitForIdle()` 等待 `phase` 回到 `idle`，覆盖整次会话操作与队列。
- 后台辅助任务（标题、记忆复盘）在写入前会先等到前台 `phase === 'idle'`，再基于实时数据重新校验，避免覆盖用户刚做的修改。
- 耗时探测与日志适配器不参与请求路径；慢资源探测通过 `PerformanceProbe` 移到 taskpool，详见[运行诊断与性能](/internals/diagnostics)。

## 错误分层

| 错误来源 | 处理位置 | 可见结果 |
| --- | --- | --- |
| 命令被拒绝（忙、归档、保存错误） | `SessionService` 的准入检查 | 返回 `false` 或写入 `status.error`，界面状态不变 |
| 账号未登录或状态变化 | `HuaweiAccount.requireLogin()`（发送前预检与每次模型请求） | 可重试错误，不发起模型请求，不清空草稿 |
| 模型服务绑定失败 | `ProviderRegistry.bind()` | 运行状态 `failed`，消息记录错误文本 |
| 网络或流解析失败 | `ProtocolProvider` / 流解析器 | 明确的临时错误可重试，其余直接展示；不伪造原因 |
| 保存失败 | `ConversationStore` → `SessionService.persist()` | 页面保留内容并显示 `saveError`；暂停队列、中止运行，需手动重试保存 |
| 工具失败 | 工具适配层 → `toolError()` | 作为工具结果回传模型，本轮可继续；不自动重试 |

## 子系统索引

| 主题 | 页面 | 主要问题 |
| --- | --- | --- |
| 代码地图 | [代码地图](/internals/code-map) | 目录职责、代表文件、新功能落点 |
| 会话与持久化 | [会话与持久化](/internals/session) | 命令准入、队列、v2 存储、原子写入、标题与恢复 |
| 轮次、流式与重试 | [轮次、流式与重试](/internals/agent-loop) | 运行生命周期、SSE 分帧、重试与取消 |
| 模型服务与凭据 | [模型服务与凭据](/internals/providers) | 注册与绑定、协议转换、密钥读取、账号校验 |
| 系统提示词与上下文 | [系统提示词与上下文](/internals/prompt) | 指令分层、投影、预算与压缩 |
| 工具注册与执行 | [工具注册与执行](/internals/tools) | 目录组合、权限过滤、回执 |
| 审批、权限与沙箱 | [审批、权限与沙箱](/internals/permissions) | 只读、逐次审批、代码沙箱 |
| 工作区与文件 | [工作区与文件](/internals/workspace) | 路径约束、版本校验、原子替换 |
| 交互预览与 Web UI | [交互预览与 Web UI](/internals/preview) | 预览发布、验证与恢复 |
| 运行诊断与性能 | [运行诊断与性能](/internals/diagnostics) | 埋点、脱敏日志、导出 |

面向使用者的说明见[模型服务与上下文](/guide/models)、[项目与共享工作区](/guide/projects)；扩展模型服务见[新增模型服务](/dev/add-provider)。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 页面组装、原生导航、会话服务实例化 |
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` | ArkUI 状态投影、草稿防抖、命令转发 |
| `entry/src/main/ets/viewmodel/SessionViewModels.ets` | 会话、消息与工具执行的视图模型 |
| `entry/src/main/ets/services/SessionService.ets` | 会话数据、发送/停止、队列调度、持久化检查点 |
| `entry/src/main/ets/services/SessionContracts.ets` | 仓库、资源、状态与事件契约 |
| `entry/src/main/ets/services/NativeSessionService.ets` | 原生组合根，注入文件、工作区、凭据、ProviderRegistry |
| `entry/src/main/ets/services/AgentRuntime.ets` | 单次运行生命周期、订阅、abort、waitForIdle |
| `entry/src/main/ets/services/AgentLoop.ets` | 模型/工具循环、检查点、执行上限 |
| `entry/src/main/ets/services/RequestContext.ets` | 每次请求的组装、预算与压缩边界 |
| `entry/src/main/ets/services/providers/ProviderRegistry.ets` | 显式注册、配置绑定、凭据解析 |
| `entry/src/main/ets/model/ConversationStore.ets` | v2 索引、独立会话文件、原子保存 |