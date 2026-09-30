# Tinybot for HarmonyOS

使用 ArkTS + ArkUI 编写的原生 HarmonyOS 个人 AI 助手。手机直接连接用户配置的模型服务，数据保存在应用沙箱中；不依赖 Tinybot 桌面进程。

当前是 **0.1.0 原生 Agent 基础版**，最低与目标版本均为 **HarmonyOS API 26**。已接入会话工作区、工具调用循环、网页读取和指令型 Skills；MCP、附件与外部工作区尚未移植。

## 已实现

- 原生聊天、会话列表、新建与确认删除；界面跟随系统明暗主题。
- 默认工作区位于应用级 `ApplicationContext.filesDir/workspace/`，每个会话使用 `<会话ID>/` 子目录，无需额外存储授权。新建空会话立即保存，重启和切换沿用同一目录；已有会话启动时自动补建目录。
- 工作区路径按会话 ID 在运行时推导，拒绝路径穿越和符号链接目录。创建目录失败会明确提示；删除会话保留工作区文件，卸载应用或清除应用数据仍会清除这些文件。
- 通过注册表选择 DeepSeek、DashScope、OpenAI、Z.ai、Ollama 或自定义兼容服务；提供与桌面 Tinybot 对齐的模型预设，仍可手动填写模型名称和地址。支持 Chat Completions、OpenAI Responses 和 Anthropic Messages 三种流式协议。
- 增量文本显示、停止生成、失败后重新编辑发送；明确区分完整、停止和失败状态。
- Agent 循环支持流式工具参数、多步执行和同一步多个工具，工具结果以对应的 `tool_call_id` 回传模型；只有模型流完整结束后才会执行工具。
- 内置 `list_files`、`read_file`、`write_file`，仅访问当前会话的工作区。读写限 UTF-8 文本和 64 KiB，列表最多 200 项并明确标记截断；拒绝越界路径与符号链接。写入自动建父目录，以临时文件和重命名完整覆盖目标文件。
- 每轮最多 8 次模型调用、每步最多 8 个工具，顺序执行；最后一次模型请求若仍要求工具，会停止并说明原因。工具失败作为错误结果交给模型处理；流式协议或持久化错误会终止本轮。
- 工具执行前保存意图、执行后保存结果；聊天中可展开查看参数和结果。停止会取消网络请求并阻止后续工具；已提交的写入保留，不自动回滚。重启后不自动重放工具，执行中断且无结果的调用会标为结果未知。
- 运行中可追加指令，或将后续任务加入当前会话队列。支持查看、撤回编辑、移除和继续队列；停止、出错和重启后保留待办并暂停。
- `read_web` 直接读取指定 HTTP/HTTPS 网页的静态正文、标题和来源链接，不需要额外密钥；设置中可关闭。当前不接搜索服务，不登录或执行网页 JavaScript。
- Skills 管理支持导入或粘贴 `SKILL.md`、添加文本参考文件、编辑、启停、删除和显式调用。模型先看到名称与简介，再通过 `read_skill` 按需读取正文或参考文件；脚本不执行。
- API Key 使用 Asset Store Kit 保存，并禁止跨设备同步；更换服务商或服务地址时需重新填写密钥。旧设置迁移为自定义兼容服务，保留已有地址、模型和密钥。
- 通过临时文件、`fsync` 和重命名保存会话；保存失败保留页面内容并提供重试。
- 应用中断后的生成记录标为已停止，不伪装成完整回答；下一轮保留工具结果，避免模型误认为已完成的文件操作被撤销，未完成的回答文本不进入上下文。
- ArkTS 本地测试覆盖流式分帧和工具参数组装、多轮执行、取消、步数限制、执行前落盘失败、工具错误恢复、历史协议还原及工作区路径边界，也覆盖 provider 注册、配置快照、事件顺序和运行收尾。

当前回答用可复制的原生 Text 展示，暂不渲染 Markdown。会话在发送前及生成结束时保存；强制结束进程可能丢失本轮尚未落盘的增量文本，但已保存的历史不会被覆盖为假完成状态。存储仍采用 v1 单文件并一次加载全部会话；聊天界面分批展示消息，尚无磁盘分页。支持按预算自动压缩和手动压缩较早上下文，保留完整历史及工具回执。

## 开发

需要 DevEco Studio API 26 SDK、DevEco CLI，以及真机调试所需的华为开发者账号。当前工程使用 Stage 模型和 ArkUI V1 状态管理；SessionService 管理会话与任务编排，AgentRuntime 管理单次运行，ViewModel 将服务事件投影为页面状态，页面负责组件组合与交互。

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
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` / `SessionViewModels.ets` | ArkUI 状态投影、编辑草稿和命令转发；保留消息及工具展开状态 |
| `entry/src/main/ets/services/SessionService.ets` | 会话数据、发送/停止、队列调度、会话管理和持久化检查点 |
| `entry/src/main/ets/services/SessionContracts.ets` / `NativeSessionService.ets` | 可注入的存储与资源接口，以及原生平台的组装入口 |
| `entry/src/main/ets/services/SessionContext.ets` | 上下文预算、指令组合和摘要提交策略 |
| `entry/src/main/ets/services/ProfileSettings.ets` | 模型服务配置提交与凭据生命周期 |
| `entry/src/main/ets/model/` | 会话结构、上下文选择、数据校验及原子文件保存 |
| `entry/src/main/ets/model/WorkspaceStore.ets` | 应用级默认工作区与会话子目录；由原生资源适配器按会话 ID 提供工具访问 |
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

模型选择显式使用配置，不根据名称猜测服务商。默认地址和模型名称沿用桌面 Tinybot；模型实际可用性取决于用户账号，并需要支持所选协议的流式工具调用。请求不自动重试，HTTP 错误与不完整输出直接展示。工具协议参照 [Function calling](https://developers.openai.com/api/docs/guides/function-calling)。

工具结果（包括读取到的文件内容）会发送给用户配置的模型。工作区文件工具只能读写当前会话目录，不能访问其他会话、模型配置或密钥；当前没有 Shell、跨应用控制或外部目录权限。旧版自带的“只能聊天”默认指令会自动更新，用户自定义指令保持原样。

## 运行中追加指令与任务排队

聊天输入框在执行期间保持可用：

- **追加指令**：沿用 Pi Agent 的 steering 语义。等待当前模型响应和整批工具调用完成，在下一次模型请求前按顺序接收一条追加指令；不打断或回滚正在执行的工具。即使模型本来准备结束回答，有待接收指令时也会继续响应。
- **加入队列**：当前任务成功结束并保存后，自动依次启动后续任务。每项任务是独立的用户/助手轮次，保留各自的 8 次模型调用上限和上下文预算；追加指令优先于后续任务。
- 待发送列表可展开、收起、**撤回编辑**或**移除**。撤回时若已有草稿会提示先处理草稿；队列执行不会清空另行输入的草稿。空闲时也可以先添加多个任务，再点击**继续队列**。
- **停止**会终止当前执行并暂停后续任务；模型或保存错误也会停止自动续跑。未开始的指令保留，重启后始终暂停，点击**继续队列**才恢复。手动发送新消息不会恢复已有的暂停队列。
- 队列按会话分别保存，最多 20 条，每条最多 24000 字符；沿用当前会话选择的模型。运行时不能切换会话或模型。追加指令记录在它进入模型上下文的位置，参与历史回放、搜索和上下文压缩；消费指令与记录历史在同一次检查点保存。
- 当前运行固定工具和 Skills。运行中用 `/skill:名称` 切换 Skill 时，请使用**加入队列**，在下一项任务开始时加载。已有待办暂停时，新一轮也保持该队列暂停，可继续加入待办。

本地测试覆盖指令顺序、整批工具边界、无工具回答后的追加、取消、落盘失败、上下文和步数限制、历史回放与压缩、会话隔离和重启恢复。真机使用本地模拟模型验证追加后连续执行多个任务，以及停止、错误、重启、撤回编辑和恢复执行。

## 网页读取与 Skills

在聊天中发送“读取并总结 https://example.com/”，模型可使用 `read_web`。网页读取默认启用，可在 **设置 → 允许读取网页 → 保存助手设置** 关闭；停用后既不向模型提供工具，也不接受该工具调用。

- 仅支持 HTTP/HTTPS GET，不接搜索服务，不携带模型密钥、登录 Cookie 或自定义认证头。地址不能包含用户名和密码；每次重定向重新校验协议，最多跟随 5 次。
- 一次读取含重定向最多 30 秒，响应最多 1 MiB；HTML 提取静态正文与标题，文本、Markdown、JSON 等按文本返回。正文最多 20000 字符、链接最多 30 个，超过时分别标记截断。
- 脚本、样式等不进入 HTML 正文；不会执行 JavaScript、绕过登录或验证码。PDF、图片、无正文页面、不支持的编码和 HTTP/网络错误会明确返回失败。
- 网页结果带有来源 URL 和 `trust: untrusted`，作为资料交给模型；停止会销毁正在进行的网络请求，阻止后续工具。网页内容仍可能不完整或过时，引用应保留来源并说明截断。

在 **设置 → 管理 Skills → 添加** 导入单个 `SKILL.md` 或粘贴其内容，检查后保存。例如：

```markdown
---
name: page-summary
description: 总结用户提供的网页，提取要点并保留来源链接
---

先读取用户提供的网址，再整理三个要点。保留来源 URL；读取失败或正文截断时明确说明。
```

Skill 引用 `references/guide.md` 等文件时，在编辑页填写相同的相对路径，再导入或粘贴参考文本并点击“添加参考文件”。这些内容作为副本保存在本机；没有持续的外部目录授权。当前不批量导入目录或 ZIP，不运行 Shell、Python、Node.js 或 Skill 内脚本。

- 元数据支持 `name`、`description` 的普通/引号文本及 `|`、`>` 多行文本；不是完整 YAML 实现，对这些字段中的对象、引用或无效值明确报错。其他元数据保留在文档中，不授予工具权限。
- 支持 `disable-model-invocation: true`，该 Skill 只在用户显式调用时提供给模型。点击“使用”会把 `/skill:名称` 放入聊天草稿，也可手动输入 `/skill:page-summary 读取这个链接……`。
- 默认仅把已启用、允许本轮使用的 Skill 名称和简介加入上下文；`read_skill` 读取正文时列出参考路径。未导入参考文件、越界路径、重复名称或未启用的 Skill 均明确报错。
- 每次运行固定可用 Skill 及其正文副本；工具结果按现有检查点落盘并参与历史回放。之后停用或删除不会删除旧对话里已经读取的资料。
- 最多保存 20 个 Skills，每个最多 16 个参考文件。单个文档最多 32000 字符，所有文档合计最多 512000 字符；文件选择器单次导入只接受最多 64 KiB 的 UTF-8 文本。

本地测试包含 Skill 元数据/资料校验、手动调用限制、工具启停、网页正文提取、截断与错误、取消，以及通过真实 Agent Loop 读取 Skill 和网页后保存、恢复调用结果的流程。

## 内置模型服务

| 服务 | 默认服务地址 | 预设模型（首项为默认） |
| --- | --- | --- |
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` |
| DashScope / 阿里云百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`、`qwen-max`、`qwen-turbo` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4.1` |
| Z.ai / 智谱 | `https://open.bigmodel.cn/api/paas/v4` | `glm-5.3`、`glm-5.3-flash`、`glm-5.2` |
| Ollama | 手动填写手机可访问的服务器地址 | 手动填写服务器上已安装、支持工具调用的模型 |
| 自定义兼容服务 | 手动填写 HTTPS 地址 | 手动填写 |

预设只是填写入口，不代表账号已经开通相应模型。打开设置不会覆盖现有配置；选择内置服务会应用它的默认值，自定义兼容服务保留当前草稿。可保存多份服务配置，每份分别管理协议、地址、密钥、模型列表和启停状态。每段对话独立选择模型，也可设置新会话默认模型；删除或停用服务后会提示重新选择，不自动切换其他服务。更换协议或端点时不会复用原密钥。

Ollama 通过其 [OpenAI 兼容接口](https://docs.ollama.com/api/openai-compatibility) 连接服务器，不在手机内运行模型。填写例如 `http://192.168.1.100:11434/v1` 的实际服务器地址，确认手机能访问该服务器；`127.0.0.1` 指向手机本身。选择 Ollama 时清空云端地址/模型并默认启用“无需 API Key”，使用受保护的代理时可关闭该开关并填写密钥。服务配置允许显式填写 HTTP 以连接本地模型；云端服务建议保留 HTTPS。无需增加系统权限。

GLM 等模型返回的 `reasoning_content` 会独立组装，随工具步骤保存，并由支持该字段的适配器回传；不会混入最终回答。OpenAI 的请求不携带这个厂商扩展字段。[智谱文档](https://docs.bigmodel.cn/cn/guide/capabilities/thinking)明确说明 GLM 5.3 不支持关闭思考，因此本实现保留协议上下文，不通过强行禁用思考绕过多轮工具调用。

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

`SessionService` 是会话数据的唯一所有者，不导入 ArkUI 或平台 Kit。它接收存储、凭据和工作区等依赖，负责命令准入、待发送指令、逐项运行、设置提交、压缩及恢复；`waitForIdle()` 等待整次会话操作和队列结束。停止、运行失败或检查点保存失败会暂停后续任务，重试保存不自动续跑。

界面接收脱离内部数据的快照；流式文本通过单条消息事件投影，避免每个增量复制全部历史。`ChatViewModel` 只保留显示状态、编辑器和输入防抖，不再直接访问文件、凭据、工具或运行时。设置保存期间的新草稿在提交后接续保存。

`ProfileSettings` 独立处理配置与密钥提交顺序；`SessionContext` 独立处理预算及摘要提交。v1 单文件格式、用户/助手成对历史和原子保存方式保持兼容，本次拆分不迁移已有数据。`SessionService.test.ets` 使用真实 AgentRuntime 和可控模型/存储，验证队列、收尾保存、停止与恢复、草稿隔离、配置和密钥回滚、压缩回滚及观察者隔离。

`AgentRuntime.run()` 接收会话 ID、模型配置、历史和工具；一次只允许一个活动任务。`subscribe()` 发布运行、模型步骤、文本增量及工具事件，`abort()` 取消本轮，`waitForIdle()` 等待本轮收尾。订阅用于同步更新 UI；必须等待的持久化放在 `checkpoint()` 中。最终状态投影和保存完成前仍禁止新任务进入，网络迟到的文本回调不会改写已结束的回答。

`runAgentLoop()` 只依赖绑定的模型会话、工具和取消信号；不访问 ViewModel、凭据或注册表。默认最多 8 次模型请求，调用方可将上限降低为 1–8。工具仍顺序执行，执行前后等待持久化检查点。停止不掩盖真实保存错误，也不撤销已完成的写入。

目前没有移植 pi 的 OAuth、自动模型发现、通用扩展插件机制和树状会话分支。运行中追加、任务队列及上述三种协议已经实现。

## 下一阶段

1. 扩展原生手机工具与工作区文件浏览、导入和导出。
2. 接入只读系统信息与系统选择器授权的外部文件，为外部动作增加可审阅的授权入口。
3. Markdown 与附件、存储分页，并评估远程 MCP 与更多原生工具。

`docs/local/` 保存本机工具资料和验证证据，不发布到 GitHub。Tinybot 品牌图形来自桌面项目；脚手架中的华为版权声明保留。
