# 模型服务与上下文

Tinybot 自身不提供模型，它把对话内容发送给用户配置的模型服务。这页说明内置预设与自定义端点的差别、密钥保存在哪里、上下文窗口和自动压缩取什么值，以及从哪里核对一次请求实际发送了多少内容。

## 服务与预设

**设置 → 模型与服务** 列出所有已保存的服务配置，每条显示协议、模型数量，停用的标为“已停用”。底部有 **添加模型服务** 与 **模型分工与能力**。

| 服务 | 协议 | 默认服务地址 | 预设模型（首项为默认） |
| --- | --- | --- | --- |
| DeepSeek | chat-completions | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` |
| DashScope · 阿里云百炼 | chat-completions | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`、`qwen-max`、`qwen-turbo` |
| OpenAI | chat-completions | `https://api.openai.com/v1` | `gpt-4.1` |
| OpenAI Responses | responses | `https://api.openai.com/v1` | `gpt-4.1` |
| Z.ai · 智谱 | chat-completions | `https://open.bigmodel.cn/api/paas/v4` | `glm-5.3`、`glm-5.3-flash`、`glm-5.2` |
| Anthropic | anthropic-messages | `https://api.anthropic.com/v1` | 需手动填写 |
| Ollama | chat-completions | 需填写手机可访问的服务器地址 | 需填写服务器上已安装的模型 |
| 自定义兼容服务 | chat-completions | 需填写 HTTPS 地址 | 需手动填写 |

预设只是填写入口，不代表账号已经开通对应模型。选择内置预设会带入默认地址与模型，自定义兼容服务保留当前草稿。可保存多份服务配置，每份独立管理协议、地址、密钥、模型列表、上下文窗口与启停状态。每段对话独立选择模型，也可设置新会话默认模型；删除或停用服务后会话会提示重新选择，不自动切换其他服务。

平板上，对话输入区右下角的模型按钮会直接展开模型菜单：按服务分组列出可用模型，当前模型带勾选，模型较多时可在菜单内搜索；选择后立即生效并关闭菜单，草稿、附件和正在生成的回答都不受影响。推理强度仍在输入区的强度芯片中单独调整。手机上仍从标题栏进入“选择模型”页。

三种流式协议对应不同的请求路径与认证方式：

| 协议 | 请求路径 | 认证 | 说明 |
| --- | --- | --- | --- |
| `chat-completions` | 基础地址 + `/chat/completions` | `Authorization: Bearer` | 兼容大多数 OpenAI 格式服务；可请求流式用量 |
| `responses` | 基础地址 + `/responses` | `Authorization: Bearer` | OpenAI 新一代接口，system 段落合并为 `instructions` |
| `anthropic-messages` | 基础地址 + `/messages` | `x-api-key` 与 `anthropic-version: 2023-06-01` | Messages 要求 `max_tokens`，应用兜底 4096 |

请求一律以 `stream: true` 发出。兼容选项的实际行为：

- 服务地址末尾的斜杠会被去掉；地址已经包含 `/chat/completions`、`/responses` 或 `/messages` 时不再重复拼接。
- 地址后缀与所选协议不一致时保存失败，提示“服务地址的接口路径与所选协议不一致。”
- Anthropic 只填主机（如 `https://api.anthropic.com`）时自动补 `/v1/messages`。
- 允许显式填写 HTTP 以连接本地或内网模型；界面同时提示 HTTP 未加密，只适用于可信网络。
- 推理内容（`reasoning_content`）随工具步骤保存，并在后续 Chat Completions 请求中回传；OpenAI 与 Ollama 预设不回传该字段，Anthropic 的签名 thinking 块按原顺序回放。

## 自定义端点与模型发现

服务编辑页分“连接”“模型”“高级设置”三段。名称上限 80 字符；模型 ID 每行一个或用中英文逗号分隔，不能为空、不能重复、每个不超过 200 字符。

**获取模型** 会把协议端点替换为服务基础地址下的 `/models` 并发送 GET：连接超时 15 秒、读取超时 30 秒、响应上限 1 MiB、不跟随重定向。只取 `data[].id`，去重后最多 200 个；HTTP 状态非 200、返回不是兼容列表或列表为空都会明确报错，此时仍可手动添加模型 ID。发现时若编辑页没有新密钥，会读取同凭据范围内的已保存密钥。

**高级设置** 中可写服务级上下文窗口，留空表示按模型自动。单模型设置优先于服务设置。

## 密钥与凭据

- API Key 通过 Asset Store Kit 写入系统安全存储，属性为“设备解锁后可读”且禁止跨设备同步；凭据别名形如 `tinybot-<id>`。
- 凭据属于服务根地址，而不是具体请求格式。协议端点之外的部分（scheme、主机、端口、基础路径）相同即可继续使用原密钥：同一基础地址下切换协议、改名称、改模型或改上下文窗口都会保留密钥。
- 更换域名、端口、HTTP/HTTPS 或基础路径时，输入框会提示“服务基础地址已改变，请重新填写密钥。”，服务保存也要求重新填写。
- 勾选 **无需 API Key**（Ollama 或内网代理）时不写入密钥；自定义服务不会显示“获取 API Key”入口。
- 内置云端服务的密钥区域下方有 **获取 API Key**，在系统浏览器打开对应官方控制台；链接来自预设元数据，不随服务改名改变。
- 保存失败时不会留下半个状态：新密钥写入临时别名，提交失败会尝试删除；旧密钥清理失败会返回“模型服务已保存，但旧密钥清理失败”，而不是宣告成功。
- 删除服务会删除这份配置及其密钥，保留完整对话；使用它的会话需要重新选择模型。

密钥不进入模型结果、日志或备份，具体边界见 [隐私与用户协议](/guide/privacy) 与 [云备份](/guide/cloud-backup)。

## 上下文预算

上下文窗口按“单模型覆盖 → 服务覆盖 → 模型默认值”解析，留空即恢复自动值：

| 项目 | 值 |
| --- | --- |
| 通用默认 | 200000 tokens |
| 默认 1M 的模型 | `deepseek-flash`、`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp`、`deepseek-v4-pro`、`glm-5.3`、`glm-5.3-flash`（匹配时忽略大小写与首尾空白） |
| 显式范围 | 8192–2000000 的整数，超出范围保存失败 |

这是客户端预算，不会改变服务端实际支持的窗口。模型规则集中在 `ConversationContext`，同样适用于使用同名模型的自定义代理。

**设置 → 模型与服务 → 模型分工与能力** 里，每个模型可单独设置：

| 设置项 | 默认 | 作用 |
| --- | --- | --- |
| 支持图片输入 | 开 | 允许该模型接收图片附件与截图 |
| 请求流式用量 | 开 | 对支持 `stream_options` 的 Chat Completions 服务请求用量 |
| 推理强度 | 默认 | 按协议与模型提供可选档位；“默认”是本地取值，不会发给服务 |
| 上下文窗口 | 留空自动 | 覆盖服务级与模型默认值，占位文字显示自动取到的数值 |

自动选择模型可分别指定快速任务、深度任务与图片理解使用哪份配置；记忆整理另有专用模型。路由只看是否有图片、问题是否超过 1000 字符或命中分析类关键词，未指定时回退当前会话选择，并且不改变会话的手动选择。

## 固定限制

以下数值来自代码，没有对应的用户设置入口。

| 项目 | 当前值或行为 |
| --- | --- |
| 自动压缩历史 | 默认开启，预留 `min(16384, 窗口 / 2)` tokens，估算输入超过剩余预算时触发 |
| 压缩保留近期历史 | `min(20000, 窗口 / 4)` tokens，至少保留最近完整一轮 |
| 压缩摘要 | 最多输出 4096 tokens；摘要文本最多 32768 字符 |
| 正常回复输出长度 | Chat Completions 与 Responses 不传上限；Anthropic 兜底 4096 |
| 单任务模型调用 | 最多 200 次（`MAX_AGENT_STEPS`），最后一次仍要求工具则停止 |
| 单次响应的工具调用 | 最多 8 个（`MAX_TOOL_CALLS`）；默认并行，批内出现声明为顺序执行的工具时整批依次执行 |
| 单个工具参数 | 最多 96 KiB；代码沙箱工具另有自己的输入口径 |
| 单步推理内容 | 最多 1 MiB |
| 请求重试 | 仅在尚未派发工具时，对明确的临时传输错误或空闲超时重试 2 次，等待 1 秒、2 秒 |
| 推理强度发送位置 | Chat Completions 用 `reasoning_effort`；Responses 用 `reasoning.effort`；Anthropic 用 `output_config.effort`，部分模型另加 `thinking: adaptive` |

## 上下文统计与压缩

点击输入框的上下文圆圈打开同一面板，面板分两部分。面板以居中弹层打开，点击遮罩或右上角关闭；内容可滚动到底部，底部会为系统导航条留出空间。顶部卡片以紧凑的已用 / 上限与百分比展示上下文窗口，点击标题可收起或展开分类明细。分段色条的整体长度对应当前占用，颜色按分类估算比例分配；分类行保留原始估算值，不将服务端校准差额归入某一类。剩余空间按窗口上限减去当前占用计算，超出上限时显示 0，顶部百分比仍保留实际超限值。

**上下文构成（估算）** 按实际保留的请求内容分类：

| 分类 | 展开后可看到 |
| --- | --- |
| 系统指令 | 身份与基础指令、运行规则、交互界面指令、用户偏好、Skills、长期记忆、团队指令等段落 |
| 工具定义 | 逐个工具的 schema 估算 |
| 用户输入 | 保留消息按轮次、步骤定位 |
| 助手内容 | 正文、推理内容与工具调用参数分别计 |
| 工具结果 | 具体工具；大结果只计实际发送的预览 |
| 历史摘要 | 已压缩历史的摘要文本 |
| 附件与引用 | 图片按固定值估算，文本附件与会话引用分别计 |
| 消息格式开销 | 每条消息的固定框架与调用 ID 开销 |

输入框中的草稿与待发送的会话引用另计，不计入已发送请求。分类合计是启发式估算，可以展开到指令段或具体工具、轮次步骤；界面明确写“分类按实际保留的内容估算，不是账单”，合计可能与服务端校准的占用不同。生成中展示最近一次请求的内容，空闲时重新估算当前保留内容。

**会话累计用量（服务端报告）** 独立展示当前会话所有聊天轮次的请求次数、输入、输出、缓存读取、缓存写入与推理。口径为：

- 只累计当前会话保存的聊天记录，不受消息分页或上下文压缩影响，切换会话随之切换。
- 缓存属于输入、推理属于输出，不重复相加。
- 未报告显示“未报告”，部分上报标记“（部分）”。
- 标题生成、记忆提取、上下文压缩与团队员工的请求不计入这里，完整统计在 **设置 → Token 用量**。

**压缩** 有两个入口：面板底部的 **压缩较早对话**，或在输入框发送 `/compact`（不接受参数，必须在当前任务完成后单独发送）。压缩会调用当前模型生成摘要，完整记录保留且不新增聊天消息。失败时命令留在草稿，面板与状态栏给出原因，包括“没有可压缩的较早完整轮次”“生成的摘要没有减少上下文用量”“上下文仍超过预算”。执行中若估算输入超出预算，会先压缩一次再继续；仍超出则停止本轮，不做静默丢弃。

## 与桌面版及 pi 的参数对照

对照本机源码版本（2026-10-04），不是在线模型规格承诺。

| 项目 | Tinybot 桌面版 | pi | 鸿蒙版取舍 |
| --- | --- | --- | --- |
| 通用上下文 | 128000，已知 DeepSeek / GLM 5.3 模型 1M | 按模型目录解析 | 通用 200000，补齐六个 1M 型号 |
| 任务轮数 | 默认 200，可配置 | Agent Loop 无固定 200 轮阈值 | 保留 200 |
| 正常输出 token | 可选，未设置则不传 | 按模型 maxTokens 与上下文余量收缩 | Chat Completions / Responses 不传 |
| 自动压缩 | 默认 90% 触发 | 剩余 16384 tokens 触发 | 采用 pi 预留值，窗口不足时预留一半 |
| 压缩保留内容 | 优先用户消息，最多 20000 tokens | 近期约 20000 tokens | 近期约 20000 tokens，按完整用户/助手及工具组切分 |
| 压缩摘要输出 | 默认 1024 tokens | 约预留的 80% | 独立 4096 预算 |
| 流式网络超时 | 初始请求及流空闲 120 秒 | HTTP 空闲默认 300 秒，可选档位 | 120 秒无数据计时，不使用固定总时限 |
| 自动重试 | 最多 3 次，限响应流开始前 | 默认 3 次，基础延迟 2000ms | 最多 2 次（1 秒、2 秒），只重发未提交请求 |

## 常见配置示例

```text
DeepSeek 官方
  协议      chat-completions
  服务地址  https://api.deepseek.com
  模型      deepseek-flash
  密钥      在 platform.deepseek.com 创建

局域网 Ollama
  协议      chat-completions
  服务地址  http://192.168.1.100:11434/v1
  模型      服务器上已安装且支持工具调用的模型
  密钥      打开“无需 API Key”
```

| 场景 | 服务地址 | 协议 | 要点 |
| --- | --- | --- | --- |
| 阿里云百炼北京地域 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | chat-completions | 其他地域或 Coding Plan 需换成对应地址与密钥 |
| 智谱通用 API | `https://open.bigmodel.cn/api/paas/v4` | chat-completions | 国际站或 Coding Plan 地址不同 |
| 自建 OpenAI 兼容网关 | 例如 `https://gateway.example.com/v1` | chat-completions | 换基础路径需重填密钥；模型名可与官方同名 |
| OpenAI Responses | `https://api.openai.com/v1` | responses | 与 Chat Completions 共用同一密钥入口 |
| Anthropic Messages | `https://api.anthropic.com/v1` | anthropic-messages | 模型 ID 需手动填写 |

Ollama 通过其 OpenAI 兼容接口连接服务器，不在手机内运行模型。`127.0.0.1` 指向手机本身，应填写手机能访问的实际服务器地址。使用受保护的代理时可关闭“无需 API Key”并填写密钥。

## 代码入口

| 职责 | 位置 |
| --- | --- |
| 内置预设、协议与密钥入口 | `entry/src/main/ets/model/Provider.ets` |
| 服务配置结构、校验与迁移 | `entry/src/main/ets/model/ProviderProfiles.ets` |
| 保存服务、密钥写入与清理 | `entry/src/main/ets/services/ProfileSettings.ets` |
| Asset Store 读写 | `entry/src/main/ets/services/CredentialStore.ets` |
| 请求地址、认证头与凭据范围 | `entry/src/main/ets/services/providers/WireProtocols.ets` |
| 协议实例与推理回传开关 | `entry/src/main/ets/services/providers/DefaultProviders.ets` |
| 模型发现 | `entry/src/main/ets/services/ModelDiscovery.ets` |
| 上下文预算、估算与压缩边界 | `entry/src/main/ets/model/ConversationContext.ets` |
| 模型能力与自动路由 | `entry/src/main/ets/model/AssistantOptions.ets` |
| 推理强度档位与请求字段 | `entry/src/main/ets/model/ReasoningEffort.ets`、`entry/src/main/ets/services/providers/ReasoningRequest.ets` |
| 上下文面板 | `entry/src/main/ets/views/ContextDetails.ets` |
| 上下文构成计算 | `entry/src/main/ets/model/ContextBreakdown.ets` |
