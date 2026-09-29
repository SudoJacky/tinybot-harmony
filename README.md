# Tinybot for HarmonyOS

使用 ArkTS + ArkUI 编写的原生 HarmonyOS 个人 AI 助手。手机直接连接用户配置的模型服务，数据保存在应用沙箱中；不依赖 Tinybot 桌面进程。

当前是 **0.1.0 原生 Agent 基础版**，最低与目标版本均为 **HarmonyOS API 26**。已接入会话工作区和工具调用循环；Skills、MCP、附件与外部工作区尚未移植。

## 已实现

- 原生聊天、会话列表、新建与确认删除；界面跟随系统明暗主题。
- 默认工作区位于应用级 `ApplicationContext.filesDir/workspace/`，每个会话使用 `<会话ID>/` 子目录，无需额外存储授权。新建空会话立即保存，重启和切换沿用同一目录；已有会话启动时自动补建目录。
- 工作区路径按会话 ID 在运行时推导，拒绝路径穿越和符号链接目录。创建目录失败会明确提示；删除会话保留工作区文件，卸载应用或清除应用数据仍会清除这些文件。
- 通过注册表选择 DeepSeek、DashScope、OpenAI、Z.ai、Ollama 或自定义兼容服务；提供与桌面 Tinybot 对齐的模型预设，仍可手动填写模型名称和地址。当前统一使用 Chat Completions 流式协议。
- 增量文本显示、停止生成、失败后重新编辑发送；明确区分完整、停止和失败状态。
- Agent 循环支持流式工具参数、多步执行和同一步多个工具，工具结果以对应的 `tool_call_id` 回传模型；只有模型流完整结束后才会执行工具。
- 内置 `list_files`、`read_file`、`write_file`，仅访问当前会话的工作区。读写限 UTF-8 文本和 64 KiB，列表最多 200 项并明确标记截断；拒绝越界路径与符号链接。写入自动建父目录，以临时文件和重命名完整覆盖目标文件。
- 每轮最多 8 次模型调用、每步最多 8 个工具，顺序执行；最后一次模型请求若仍要求工具，会停止并说明原因。工具失败作为错误结果交给模型处理；流式协议或持久化错误会终止本轮。
- 工具执行前保存意图、执行后保存结果；聊天中可展开查看参数和结果。停止会取消网络请求并阻止后续工具；已提交的写入保留，不自动回滚。重启后不自动重放工具，执行中断且无结果的调用会标为结果未知。
- API Key 使用 Asset Store Kit 保存，并禁止跨设备同步；更换服务商或服务地址时需重新填写密钥。旧设置迁移为自定义兼容服务，保留已有地址、模型和密钥。
- 通过临时文件、`fsync` 和重命名保存会话；保存失败保留页面内容并提供重试。
- 应用中断后的生成记录标为已停止，不伪装成完整回答；下一轮保留工具结果，避免模型误认为已完成的文件操作被撤销，未完成的回答文本不进入上下文。
- ArkTS 本地测试覆盖流式分帧和工具参数组装、多轮执行、取消、步数限制、执行前落盘失败、工具错误恢复、历史协议还原及工作区路径边界，也覆盖 provider 注册、配置快照、事件顺序和运行收尾。

当前回答用可复制的原生 Text 展示，暂不渲染 Markdown。会话在发送前及生成结束时保存；强制结束进程可能丢失本轮尚未落盘的增量文本，但已保存的历史不会被覆盖为假完成状态。首版采用单文件存储并一次加载全部会话，尚未针对大量历史做分页或上下文压缩。

## 开发

需要 DevEco Studio API 26 SDK、DevEco CLI，以及真机调试所需的华为开发者账号。当前工程使用 Stage 模型和 ArkUI V1 状态管理；AgentRuntime 管理运行状态，ViewModel 将事件投影为页面状态并协调本地保存，页面负责组件组合与交互。

```powershell
# 首次克隆时创建本机配置；已有文件时不要覆盖
if (-not (Test-Path build-profile.json5)) { Copy-Item build-profile.template.json5 build-profile.json5 }
devecocli check arkts
devecocli build
.\scripts\test.ps1
```

若 `devecocli` 不在 PATH，可用 `& "$env:APPDATA\npm\devecocli.cmd"` 代替。`test.ps1` 优先读取 `DEVECO_STUDIO_HOME`，默认使用 `C:\Program Files\Huawei\DevEco Studio`；不依赖工作区中的下载技能。

未配置签名时，构建生成 `entry/build/default/outputs/default/entry-default-unsigned.hap`。真机调试：

```powershell
devecocli device list
devecocli auth login
devecocli signature generate
devecocli run --device <设备名称或序列号>
```

签名命令会修改 `build-profile.json5` 并在本机保存签名材料。该文件已加入 `.gitignore`；版本库使用不含签名的 `build-profile.template.json5`，修改 SDK 或模块配置时需同步模板。工程当前不自动生成发布签名。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 原生导航与页面组装 |
| `entry/src/main/ets/views/` | 聊天、消息、会话列表及模型设置 |
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` | 状态、发送/停止、设置保存与持久化协调 |
| `entry/src/main/ets/model/` | 会话结构、上下文选择、数据校验及原子文件保存 |
| `entry/src/main/ets/model/WorkspaceStore.ets` | 应用级默认工作区与会话子目录；当前会话路径由 `ThreadViewModel.workspaceDir` 提供 |
| `entry/src/main/ets/services/providers/ProviderRegistry.ets` | 显式注册、配置绑定和每次请求前的凭据解析 |
| `entry/src/main/ets/services/providers/DefaultProviders.ets` | 应用内置服务商的注册入口 |
| `entry/src/main/ets/services/providers/ChatCompletionsProvider.ets` | Chat Completions 的 NetworkKit 请求、取消与 UTF-8 增量解码 |
| `entry/src/main/ets/services/providers/ChatCompletionsProtocol.ets` | 领域消息到协议请求的转换与端点校验 |
| `entry/src/main/ets/services/ChatStream.ets` | SSE 分帧、工具参数组装与完整性校验 |
| `entry/src/main/ets/services/AgentRuntime.ets` | 单次运行的生命周期、事件订阅、取消、禁止重入和等待结束 |
| `entry/src/main/ets/services/AgentLoop.ets` | 与 UI 和服务商无关的模型/工具循环、检查点及执行上限 |
| `entry/src/main/ets/services/Cancellation.ets` | 贯穿准备、凭据读取、网络和工具执行的取消信号 |
| `entry/src/main/ets/services/WorkspaceTools.ets` | 工具定义、参数校验及工作区相对路径约束 |
| `entry/src/main/ets/services/NativeWorkspaceFiles.ets` | 沙箱文件读写、逐级路径检查及原子替换 |
| `entry/src/main/ets/services/CredentialStore.ets` | 系统安全存储 |
| `entry/src/test/` | 不依赖真机和模型密钥的本地测试 |

模型选择显式使用配置，不根据名称猜测服务商。默认地址和模型名称沿用桌面 Tinybot；模型实际可用性取决于用户账号，并需要支持 Chat Completions 流式工具调用。请求不自动重试，HTTP 错误与不完整输出直接展示。工具协议参照 [Function calling](https://developers.openai.com/api/docs/guides/function-calling)。

工具结果（包括读取到的文件内容）会发送给用户配置的模型。工具只能读写当前会话目录，不能访问其他会话、模型配置或密钥；当前没有 Shell、跨应用控制或外部目录权限。旧版自带的“只能聊天”默认指令会自动更新，用户自定义指令保持原样。

## 内置模型服务

| 服务 | 默认服务地址 | 预设模型（首项为默认） |
| --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` |
| DashScope / 阿里云百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`、`qwen-max`、`qwen-turbo` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4.1` |
| Z.ai / 智谱 | `https://open.bigmodel.cn/api/paas/v4` | `glm-5.3`、`glm-5.3-flash`、`glm-5.2` |
| Ollama | 手动填写手机可访问的服务器地址 | 手动填写服务器上已安装、支持工具调用的模型 |
| 自定义兼容服务 | 手动填写 HTTPS 地址 | 手动填写 |

预设只是填写入口，不代表账号已经开通相应模型。打开设置不会覆盖现有配置；选择内置服务会应用它的默认值，自定义兼容服务保留当前草稿。当前仍保存一份活动配置，更换服务商或端点时不会复用原密钥；多服务商配置档案尚未实现。

Ollama 通过其 [OpenAI 兼容接口](https://docs.ollama.com/api/openai-compatibility) 连接服务器，不在手机内运行模型。填写例如 `http://192.168.1.100:11434/v1` 的实际服务器地址，确认手机能访问该服务器；`127.0.0.1` 指向手机本身。选择 Ollama 时清空云端地址/模型并默认启用“无需 API Key”，使用受保护的代理时可关闭该开关并填写密钥。仅 Ollama 注册项允许 HTTP，其余服务维持 HTTPS 校验；无需增加系统权限。

GLM 等模型返回的 `reasoning_content` 会独立组装，随工具步骤保存，并由支持该字段的适配器回传；不会混入最终回答。OpenAI 的请求不携带这个厂商扩展字段。[智谱文档](https://docs.bigmodel.cn/cn/guide/capabilities/thinking)明确说明 GLM 5.3 不支持关闭思考，因此本实现保留协议上下文，不通过强行禁用思考绕过多轮工具调用。

## Provider 与运行管理

结构参考 pi 的 provider 工厂/注册表、有状态 Agent 和独立 agent-loop：

```text
ChatViewModel → AgentRuntime → runAgentLoop → ModelSession
                     ↓                           ↓
               生命周期与取消          ProviderRegistry 绑定的 ModelProvider
                     ↓                           ↓
                本地保存检查点              协议适配与网络请求
```

`ProviderRegistry.register()` 按稳定 ID 注册服务商；重复 ID 和未知服务商均明确报错。开始运行时，`bind()` 固定 provider 实例、地址、模型和凭据别名，后续设置或注册表修改不会改变正在执行的任务。密钥在每次模型请求前从安全存储读取。设置界面的选项也来自同一注册表，不根据模型名称或 URL 猜测服务商。

内置服务元数据集中在 `model/Provider.ets`，`DefaultProviders.ets` 负责注册及协议选项。新增 Chat Completions 兼容服务时，添加 ID、显示名称、默认地址和模型预设，并显式选择其协议兼容选项。新增不同协议时，实现 `ModelProvider` 的 `endpoint()` 和 `stream()`，在该适配器内转换 `ModelMessage`、处理流和工具调用，再注册；无需修改 loop。`tool_calls`、`tool_call_id` 等 HTTP 字段仅出现在模型协议层。

`AgentRuntime.run()` 接收会话 ID、模型配置、历史和工具；一次只允许一个活动任务。`subscribe()` 发布运行、模型步骤、文本增量及工具事件，`abort()` 取消本轮，`waitForIdle()` 等待本轮收尾。订阅用于同步更新 UI；必须等待的持久化放在 `checkpoint()` 中。最终状态投影和保存完成前仍禁止新任务进入，网络迟到的文本回调不会改写已结束的回答。

`runAgentLoop()` 只依赖绑定的模型会话、工具和取消信号；不访问 ViewModel、凭据或注册表。默认最多 8 次模型请求，调用方可将上限降低为 1–8。工具仍顺序执行，执行前后等待持久化检查点。停止不掩盖真实保存错误，也不撤销已完成的写入。

目前没有移植 pi 的 OAuth、自动模型发现、消息排队或运行中追加指令；Responses、Anthropic 等协议也尚未实现。现有拆分为这些能力提供明确入口，不表示已经支持。

## 下一阶段

1. 扩展原生手机工具与工作区文件浏览、导入和导出。
2. 接入只读系统信息与系统选择器授权的外部文件，为外部动作增加可审阅的授权入口。
3. Markdown 与附件、多模型档案、历史分页和上下文管理，再评估 HarmonyOS 能支持的 Skills 与远程 MCP。

`docs/local/` 保存本机工具资料和验证证据，不发布到 GitHub。Tinybot 品牌图形来自桌面项目；脚手架中的华为版权声明保留。
