# 架构与运行管理

平台无关的 `Diagnostics` 统一聚合性能埋点与分级运行日志；`DiagnosticLog` 负责名称/字段白名单和脱敏，唯一的 HiLog 输出适配器为 `NativeDiagnosticLog`。`DeveloperDiagnostics` 管理原生探测、滚动日志、联合导出和采集生命周期，慢资源探测通过 `PerformanceProbe` 移到 taskpool。入口与数据边界见[App 内性能诊断](developer-diagnostics.md)。

[文档索引](README.md) · [项目首页](../README.md)

工程使用 Stage 模型和 ArkUI V1 状态管理。本文描述模块职责、运行生命周期和持久化约定；项目归属见[项目与工作区](projects-and-workspaces.md)，工具协议见[工具执行与权限](tools-and-permissions.md)。

## Provider 与运行管理

结构参考 pi 的 provider 工厂/注册表、有状态 Agent 和独立 agent-loop：

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

`ProviderRegistry.register()` 按稳定 ID 注册服务商；重复 ID 和未知服务商均明确报错。开始运行时，`bind()` 固定 provider 实例、地址、模型和凭据别名，后续设置或注册表修改不会改变正在执行的任务。密钥在每次模型请求前从安全存储读取。设置界面从服务配置和预设生成选项，不根据模型名称或 URL 猜测服务商。

内置服务元数据集中在 `model/Provider.ets`，`DefaultProviders.ets` 负责注册及协议选项。新增 Chat Completions 兼容服务时，添加 ID、显示名称、默认地址和模型预设，并显式选择其协议兼容选项。新增不同协议时，实现 `ModelProvider` 的 `endpoint()` 和 `stream()`，在该适配器内转换 `ModelMessage`、处理流和工具调用，再注册；无需修改 loop。`tool_calls`、`tool_call_id` 等 HTTP 字段仅出现在模型协议层。

密钥获取入口和服务配置见[模型与上下文](models-and-context.md)。

`SessionService` 是会话数据的唯一所有者，不导入 ArkUI 或平台 Kit。它接收存储、凭据和工作区等依赖，负责命令准入、待发送指令、逐项运行、设置提交、压缩及恢复；`waitForIdle()` 等待整次会话操作和队列结束。停止、运行失败或检查点保存失败会暂停后续任务，重试保存不自动续跑。

界面接收脱离内部数据的快照；流式文本通过单条消息事件投影，避免每个增量复制全部历史。`ChatViewModel` 只保留显示状态、编辑器和输入防抖，不再直接访问文件、凭据、工具或运行时。设置保存期间的新草稿在提交后接续保存。

Markdown 追加内容只重解析最后两个块及新增尾部，保留未变化块的身份；这也覆盖尚未补全的表格分隔符。视图按每组最多 16 个块隔离缓存与渐显时钟，离屏后以实测高度占位并释放文字节点；内容、字体或宽度变化会重新测量，不截断正文。一次性长答案每批最多新增 32 个块，其余分帧挂载；退出取消待挂载工作，重新进入从最新正文接续。最新消息的高度变化接入既有自动跟随，用户主动滚动后仍停止跟随。折叠代码仅高亮预览，展开及复制仍使用完整代码；渐显在离屏、后台、完成与卸载时停止。

`ProfileSettings` 独立处理配置与密钥提交顺序；`SessionContext` 独立处理预算及摘要提交。用户/助手成对历史仍保持兼容；后续功能增强已加入 v1 到 v2 分会话文件迁移，原 v1 数据保留。`SessionService.test.ets` 使用真实 AgentRuntime 和可控模型/存储，验证队列、收尾保存、停止与恢复、草稿隔离、配置和密钥回滚、压缩回滚及观察者隔离。

`AgentRuntime.run()` 接收会话 ID、模型配置、历史和工具；一次只允许一个活动任务。`subscribe()` 发布运行、模型步骤、文本增量及工具事件，`abort()` 取消本轮，`waitForIdle()` 等待本轮收尾。订阅用于同步更新 UI；必须等待的持久化放在 `checkpoint()` 中。最终状态投影和保存完成前仍禁止新任务进入，网络迟到的文本回调不会改写已结束的回答。

`runAgentLoop()` 只依赖绑定的模型会话、工具和取消信号；不访问 ViewModel、凭据或注册表。默认最多 200 次模型请求，调用方可将上限降低为 1–200。工具仍顺序执行，执行前后等待持久化检查点。停止不掩盖真实保存错误，也不撤销已完成的写入。

已经移植模型发现、树状会话分支、运行中追加和任务队列等语义，并实现远程 MCP OAuth。当前没有模型服务账号的 OAuth 登录或通用扩展插件运行环境。

## 会话持久化与恢复

- 新对话首条消息保存后，后台使用本轮实际模型生成简短标题（与输入语言一致，最多 28 字符）。起名请求不携带历史或工具，不阻塞回答；结果在前台操作结束后保存并刷新会话列表。失败时保留首句摘要，手动改名始终优先，归档或删除的会话不会被晚到结果改写。
- 通过临时文件、`fsync` 和重命名保存会话；保存失败保留页面内容并提供重试。
- 应用中断后的生成记录标为已停止，不伪装成完整回答；下一轮保留工具结果，避免模型误认为已完成的文件操作被撤销，未完成的回答文本不进入上下文。

回答使用原生 Markdown 组件展示，支持标题、强调、列表、引用、代码块、表格和 HTTP(S) 链接。代码块可复制，表格与代码横向滚动；普通 Markdown 不执行 HTML 或远程脚本，独立的交互 Web 节点见[交互式回答](interactive-ui.md)。会话在发送前及生成结束时保存；强制结束进程可能丢失本轮尚未落盘的增量文本，但已保存的历史不会被覆盖为假完成状态。会话迁移为 v2 索引和独立会话文件：只重写变更的会话，先保存内容，再原子切换索引；原 v1 文件保留。当前仍一次加载会话元数据和消息，聊天界面分批展示，尚无磁盘按需加载。图片独立保存，不把 Base64 写入会话记录。支持按预算自动压缩和手动压缩较早上下文，保留完整历史及工具回执。

## 用量账本

- **大量用量记录**：请求明细采用稳定游标分页，每页 30 条，翻页替换当前页；会话和轮次每页 10 项，轮次在展开后查询。统计只保存汇总计数，按小批次让出界面线程，合并 300 ms 内的账本通知，过期查询和已关闭页面不会回写。账本按 256 条分块保存，更新只写受影响的块，旧 `usage-ledger.json` 首次迁移后保留恢复副本。当前账本仍在内存中维护索引与记录，启动按块恢复；分页限制的是页面数据和渲染节点，不会截断统计范围。运行 `node scripts/test-usage-performance.cjs` 可验证 10 万条请求的统计、分页、取消和事件循环响应。

## 模型重试

模型选择显式使用配置，不根据名称猜测服务商。默认地址和模型名称沿用桌面 Tinybot；模型实际可用性取决于用户账号，并需要支持所选协议的流式工具调用。Agent 请求在尚未开始输出时，对明确的临时 HTTP/连接错误最多重试 2 次（等待 1 秒、2 秒），显示重试状态并支持停止；已输出正文或思考、不完整流、鉴权与明确的额度错误直接展示。重试状态在重新请求前保存，保存失败不继续；不会重放已完成的工具。工具协议参照 [Function calling](https://developers.openai.com/api/docs/guides/function-calling)。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 原生导航与页面组装 |
| `entry/src/main/ets/views/` | 聊天、消息、会话列表及模型设置 |
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` / `SessionViewModels.ets` | ArkUI 状态投影、编辑草稿和命令转发；保留消息及工具展开状态 |
| `entry/src/main/ets/services/SessionService.ets` | 会话数据、发送/停止、队列调度、会话管理和持久化检查点 |
| `entry/src/main/ets/services/SessionContracts.ets` / `NativeSessionService.ets` | 可注入的存储与资源接口，以及原生平台的组装入口 |
| `entry/src/main/ets/services/SessionContext.ets` | 上下文预算、指令组合和摘要提交策略 |
| `entry/src/main/ets/services/ProfileSettings.ets` | 模型服务配置提交与凭据生命周期 |
| `entry/src/main/ets/model/` | 会话结构、上下文选择、数据校验及原子文件保存 |
| `entry/src/main/ets/model/WorkspaceStore.ets` | 应用级工作区；普通会话独立目录，项目共享目录由资源适配器统一提供 |
| `entry/src/main/ets/services/providers/ProviderRegistry.ets` | 显式注册、配置绑定和每次请求前的凭据解析 |
| `entry/src/main/ets/services/providers/DefaultProviders.ets` | 应用内置服务商的注册入口 |
| `entry/src/main/ets/services/providers/ChatCompletionsProvider.ets` | Chat Completions 的 NetworkKit 请求、取消与 UTF-8 增量解码 |
| `entry/src/main/ets/services/providers/ChatCompletionsProtocol.ets` | 领域消息到协议请求的转换与端点校验 |
| `entry/src/main/ets/services/ChatStream.ets` | SSE 分帧、工具参数组装与完整性校验 |
| `entry/src/main/ets/services/AgentRuntime.ets` | 单次运行的生命周期、事件订阅、取消、禁止重入和等待结束 |
| `entry/src/main/ets/services/AgentLoop.ets` | 与 UI 和服务商无关的模型/工具循环、检查点及执行上限 |
| `entry/src/main/ets/services/Cancellation.ets` | 贯穿准备、凭据读取、网络和工具执行的取消信号 |
| `entry/src/main/ets/services/WorkspaceTools.ets` | 工具定义、参数校验及工作区相对路径约束 |
| `entry/src/main/ets/services/ToolSet.ets` | 统一组合工具目录和执行路由；未启用工具不能执行 |
| `entry/src/main/ets/services/WebTools.ets` / `NativeWebTransport.ets` | 网页正文提取与原生 HTTP 读取、取消、超时和重定向 |
| `entry/src/main/ets/model/Skills.ets` / `services/SkillTools.ets` | Skill 文档解析、校验、按需发现及运行期内容快照 |
| `entry/src/main/ets/views/SkillsPanel.ets` / `SkillEditorPanel.ets` | Skills 管理、文档导入与参考文件编辑 |
| `entry/src/main/ets/services/NativeWorkspaceFiles.ets` | 沙箱文件读写、逐级路径检查及原子替换 |
| `entry/src/main/ets/services/CredentialStore.ets` | 系统安全存储 |
| `entry/src/test/` | 不依赖真机和模型密钥的本地测试 |
