# 审批、权限与沙箱

工具能做什么，由“哪些工具被注册”“当前会话允许哪些能力”“路径与预算是否放行”“用户是否批准这一次”四层依次收紧。这页说明审批（approval）在哪出现、权限预设如何生效、文件与代码被限制在什么范围，以及没有界面时审批会怎样。

## 权限层级

| 层级 | 决定者 | 作用点 |
| --- | --- | --- |
| 注册 | `SessionResources.tools()` 按配置组装分组 | 工具是否存在 |
| 选择 | 会话的 `full` / `custom` | 可选能力整组去留 |
| 只读 | `RuleTools` | 非只读分组不可见、不可执行 |
| 角色与启用状态 | 员工角色、Skills 单项启用 | 目录与执行 |
| 单次审批 | `ToolApproval`、`BrowserSession` | 每次远程调用或浏览器控制 |
| 路径与预算 | 文件解析、QuickJS 限额 | 单次调用实际可达范围 |

任何一层拒绝都不会被下层重新打开；发现、编排子调用与团队员工只会在已通过前几层的目录里工作。

## 审批入口与交互

审批由 `ToolApproval` 持有，界面只渲染它的状态。对象上有 `title`、`details`、`form`、`formError` 四个可观察字段，同一时间只允许一个等待项：已有提问或确认未结束时，新的请求以 `INTERACTION_PENDING` 失败。

| 入口 | 调用 | 界面 | 允许/拒绝后 |
| --- | --- | --- | --- |
| 远程工具确认 | `request(title, details, cancellation)` | 输入框上方的确认卡，显示“允许调用远程工具？” | 允许继续执行；拒绝抛 `USER_DENIED` |
| 结构化提问 | `ask(form, cancellation)` | 输入框上方的表单卡，1–10 个字段 | 提交返回 JSON 结果；点“不回答”返回 `{"status":"cancelled"}` |
| MCP 鉴权 | `ask()` + `password` 字段 | 密码输入框，旁注说明令牌只发送到哪个地址 | 令牌写入安全存储后清空 |
| 浏览器授权 | `BrowserSession` 自己的待确认状态 | 浏览器状态卡 | 允许后取得控制；策略为 `disabled` 时不再询问 |

确认卡提供“拒绝”和“允许本次”，详情区可展开查看服务地址与参数，最多 160 vp 高。表单卡支持文本、数字、单选和多选，提交时校验失败只显示在卡片内，不关闭表单；按钮为“不回答”和“提交并继续”。

等待通过 Promise 挂起；本轮被停止时取消信号会清空界面字段并结束等待，调用按取消处理。点“不回答”只结束表单，不算停止本轮。停止与用户拒绝在回执里分别是 `CANCELLED` 与 `USER_DENIED`。MCP 的逐次确认在真正发出 `tools/call` 之前完成，拒绝时不会产生远程副作用。

`request_user_input` 不能收集密码：表单解析只接受 `text`、`number`、`select`、`multiselect`，`password` 是原生 MCP 鉴权表单专用的字段类型。令牌不进入聊天记录、模型上下文或诊断日志；写入凭据失败会回滚已建的别名。

## 权限预设

会话有两个工具选择模式，保存在会话上并随消息提交：

| 模式 | 目录 | 切换后 |
| --- | --- | --- |
| 完整版 `full` | 所有已配置且获授权的工具 | 保留自定义配置，切回时恢复 |
| 自定义 `custom` | 关闭的能力整组移除 | 选择在下一条有效消息生效，执行期间不可修改 |

基础文件工具（`list_files`、`find_files`、`read_file`、`search_file_content`、`write_file`、`edit_file`）在自定义模式中固定保留。记忆与 Skills 的 4 个入口由助手设置和 Skills 页面单独控制，不受这项开关影响。

能力开关在界面上的位置与默认值见[设置项](/reference/settings)。除会话选择外，还有两层独立限制：

- **全局只读**：`RuleTools` 在目录与执行两处过滤 `readOnly: false` 的分组（写文件、`mcp_call`、扩展管理、记忆）。开启后模型看不到这些工具，直接调用返回 `PERMISSION_DENIED`；结果归档与自动记忆整理也不再执行。
- **员工角色**：团队员工沿用同一份目录，再按任务职责与只读状态取交集；员工不能招募员工，聊天团队员工必须通过 `team_complete_task` 交接。

全量提供不改变任何一层权限：模型只收到已通过选择、只读与角色过滤的目录，`tool_search` 默认不提供。编排子调用同样经过参数校验、路径校验与 MCP 审批。

## 路径约束

工作区工具只接受相对路径，入口先做语法校验，再由存储层逐段解析：

| 检查 | 规则 |
| --- | --- |
| 长度与字符 | 非空、最多 1024 字符；禁止反斜杠、冒号与控制字符 |
| 层级 | 最多 16 段 |
| 段内容 | 不允许空段、`.`、`..`，也不允许 `.tinybot-` 开头的保留名 |
| 根目录 | 只有列表、检索与查找允许传入 `.` |
| 解析 | 工作区根必须是绝对路径且不以斜杠结尾；根目录与其父目录必须是真实目录 |
| 符号链接 | 逐段 `lstat`，任一段是符号链接即拒绝；父目录必须是目录 |
| 写入目标 | 已存在的目标必须是普通文件，打开时使用 `NOFOLLOW` |

父目录不存在的中间段会在写入时创建，但任何已存在的段都不会被符号链接（symbolic link）“穿透”。读取、列表与写入共用同一套解析，因此不存在“列表能看到、写入却跳出工作区”的路径。`present_files` 另用 `checkedPath()` 复核：必须是普通文件，不能是目录或符号链接。

## 沙箱写入根目录

应用级工作区的根目录是 `ApplicationContext.filesDir/workspace`。普通会话使用会话 ID 作为子目录，项目会话使用项目的稳定 `workspaceId`；两者都在同一根下。项目可额外挂载由系统选择器明确授权的共享文件夹，入口为 `shared/<名称>/`；工具仍无法访问模型配置、密钥或未授权目录。

```text
<ApplicationContext.filesDir>/
├─ workspace/
│  ├─ <会话 ID>/                普通会话
│  │  ├─ .tinybot-review/       文件修改基线
│  │  └─ .tinybot-<uuid>.tmp    写入中的临时文件
│  └─ <workspaceId>/            项目共享目录
├─ attachments/                 图片与文档附件
└─ <日志、会话、用量等应用数据>
```

私有工作区写入在目标同目录创建 `.tinybot-<uuid>.tmp`，写完 `fsync` 后重命名覆盖目标，失败时删除临时文件。共享目录先在私有工作区持久保存修改前备份，再直接写入目标、按字节长度截断并同步；不依赖共享目录的重命名能力，也不保证原子性。临时文件与基线目录都以 `.tinybot-` 开头，目录列表会过滤它们，模型也不能把这类名字当作普通路径。

## 代码执行隔离与预算

`execute_code` 在独立 QuickJS Runtime 中执行同步 JavaScript。每次调用由宿主生成执行 ID，在 Native 异步工作线程新建并销毁 Runtime；ArkTS 等待 Native 返回并完成清理后才释放工具通道。

| 项目 | 限制 |
| --- | --- |
| 执行时间 | 从 Native 接收开始计 2000 ms，含排队、解析、执行、序列化 |
| Runtime 分配 | 32 MiB，分配失败锁存为终止状态 |
| JavaScript 栈 | 512 KiB |
| 日志 | stdout + stderr 合计 32 KiB UTF-8，按完整码点截断 |
| 错误文本 | 4 KiB UTF-8 |
| 并发 | 应用内最多一次，其他调用收到 busy 错误，不排队 |
| 宿主能力 | 无网络、文件、进程、Node.js、模块加载、定时器或宿主对象 |

源码通过 `input` 读取 JSON 副本，通过 `return` 返回可序列化值。Promise 返回值或待执行 job 会被拒绝，`Atomics.wait` 被禁用。状态为 `ok`、`error`、`timeout`、`cancelled`、`memory_limit`、`unsupported_async`；失败时 `result` 为 `null`，日志截断不影响计算成功。

`orchestrate` 使用异步函数体，通过 `tools.*` 调用已授权工具。外层脚本受 32 次子调用、4 个并发宿主通道、120 秒墙钟、32 MiB Runtime 与 1 MiB 返回值约束；脚本源码与每个子调用参数各最多 96 KiB，结果超过 1 MiB 时以错误回执替代。子调用沿用原工具的参数、路径与审批规则；Team 控制、用户表单、预览发布和 `execute_code` 本身不开放为嵌套工具。

两者都是同进程解释器隔离：中断是协作式检查，内建 C 运算与 Runtime 清理不是操作系统抢占，解释器漏洞或崩溃仍可能影响应用进程。需要更强边界时应新增进程或 WASM 后端，而不是给现有工具开放宿主权限。

## 网络访问边界

联网是一个总开关。关闭“允许联网”后，`read_web` 与 `search_web` 既不提供也不接受调用。

| 通道 | 边界 |
| --- | --- |
| 网页读取 | 仅 HTTP/HTTPS；GET；不携带模型密钥、Cookie 或自定义认证头；重定向逐跳重新校验，最多跟随 5 次；整次读取最多 30 秒、响应最多 1 MiB |
| 联网搜索 | 独立服务与密钥；只接受结构化来源，不把模型自由回答当作来源 |
| 应用内浏览器 | 独立 `BrowserSession` 与浏览器面板，受启用策略、控制权与用户接管约束；仅 HTTP/HTTPS |
| MCP | 配置校验要求 HTTPS 地址且不含账号或片段；支持 Bearer Token 与 OAuth；每次 `mcp_call` 单独确认；请求 60 秒、响应 1 MiB |
| 模型请求 | 由 provider 适配层发起，与工具网络权限分开；连接超时 15 秒，首段与流空闲超时 120 秒 |

网页正文、附件、MCP 结果都标记为资料，不能改变角色或扩大权限。浏览器接管期间，已发出的操作会完成，不会因接管撤销；预览卡片不申请、不继承浏览器的网络、存储或控制权。

## 没有界面时的审批行为

审批对象不内置超时，也没有自动允许路径。界面没有消费某个确认或表单时，工具调用会一直等待，直到本轮取消；取消后字段清空、调用记为取消。因此无界面运行只能执行不需要审批的工具。

- 浏览器策略为 `unset` 时，第一次需要浏览器会进入待确认状态；没有界面回答就一直等待。策略为 `disabled` 时直接以 `PERMISSION_DENIED` 失败，不弹确认、不再询问。
- MCP 鉴权表单同理：没有提交就没有凭据，调用以取消或失败结束，不会退化为匿名调用。
- `ToolApproval` 与 `McpTools` 没有自动允许分支；本地测试通过注入替身直接回答或取消，只替换界面消费方，不改变权限判断。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/ToolApproval.ets` | 确认与表单的单一等待项、取消清理、拒绝错误 |
| `entry/src/main/ets/views/ChatPanel.ets` | 确认卡渲染与允许/拒绝操作 |
| `entry/src/main/ets/views/InputFormCard.ets` | 结构化表单渲染、字段校验与提交 |
| `entry/src/main/ets/services/NativeResourceSetup.ets` | MCP 鉴权表单、令牌写入与失败回滚 |
| `entry/src/main/ets/services/McpTools.ets` | 每次远程调用前的确认与拒绝处理 |
| `entry/src/main/ets/services/BrowserSession.ets` | 浏览器启用策略、控制权、接管与等待点 |
| `entry/src/main/ets/services/RuleTools.ets` | 全局只读过滤 |
| `entry/src/main/ets/model/ToolGroups.ets` | 只读分组与可选能力清单 |
| `entry/src/main/ets/services/WorkspaceTools.ets` | 相对路径语法校验与文件参数检查 |
| `entry/src/main/ets/services/NativeWorkspaceFiles.ets` | 逐段路径解析、符号链接拒绝、原子替换与基线 |
| `entry/src/main/ets/model/WorkspaceStore.ets` | 工作区根目录与目录生命周期 |
| `entry/src/main/ets/services/CodeExecutionTools.ets` | `execute_code` 参数、状态与回执 |
| `entry/src/main/ets/services/NativeCodeExecutor.ets` | QuickJS 执行、取消订阅与清理 |
| `entry/src/main/ets/services/NativeWebTransport.ets` | 网页 GET、重定向校验、超时与 1 MiB 限制 |
| `entry/src/main/ets/services/NativeDiagnosticLog.ets` | 唯一 HiLog 输出适配器 |
