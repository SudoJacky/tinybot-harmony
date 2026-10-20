# 模型服务与凭据

这一页说明模型服务（Provider）如何注册与绑定、请求发出前凭据（credential）和账号各检查一次什么，以及三种协议的转换差异。配置界面与使用限制见[模型服务与上下文](/guide/models)。

## 三个概念

| 概念 | 类型 | 含义 | 位置 |
| --- | --- | --- | --- |
| 预设 | `ProviderInfo` | 内置的 ID、名称、协议、默认地址、模型清单与密钥入口 | `model/Provider.ets` 的 `builtinProviderInfos()` |
| 配置实例 | `ProviderProfile` | 用户保存的一份服务：协议、地址、密钥别名、模型列表、启用状态、窗口覆盖 | `model/ProviderProfiles.ets` |
| 运行时适配器 | `ModelProvider` | 负责端点规则、请求体、请求头与流解析 | `services/providers/*`，应用内统一实现为 `ProtocolProvider` |

```ts
export interface ModelProvider {
  readonly info: ProviderInfo;
  endpoint(baseUrl: string): string;
  stream(request: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void, onReasoning?: (text: string) => void): Promise<ModelTurn>;
}
```

预设只是编辑器的填写入口；运行时的注册表按已保存的配置实例注册。因此修改预设不会改变已有配置，判断服务商也不依据模型名或地址猜测。

## 内置预设

| ID | 名称 | 协议 | 默认地址 | 预设模型（首项为默认） |
| --- | --- | --- | --- | --- |
| `deepseek` | DeepSeek | `chat-completions` | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` |
| `dashscope` | DashScope · 阿里云百炼 | `chat-completions` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus`、`qwen-max`、`qwen-turbo` |
| `openai` | OpenAI | `chat-completions` | `https://api.openai.com/v1` | `gpt-4.1` |
| `zai` | Z.ai · 智谱 | `chat-completions` | `https://open.bigmodel.cn/api/paas/v4` | `glm-5.3`、`glm-5.3-flash`、`glm-5.2` |
| `ollama` | Ollama | `chat-completions` | 空，手动填写局域网地址 | 空，手动填写 |
| `openai-compatible` | 自定义兼容服务 | `chat-completions` | 空 | 空 |
| `openai-responses` | OpenAI Responses | `responses` | `https://api.openai.com/v1` | `gpt-4.1` |
| `anthropic` | Anthropic | `anthropic-messages` | `https://api.anthropic.com/v1` | 空，手动填写 |

Ollama 预设标记 `noApiKey`，并使用端点占位符提示填写手机可访问的服务器地址。内置云端预设带 `apiKeyUrl`，编辑页据此显示官方密钥入口；该链接不随服务改名变化，自定义服务与启用“无需 API Key”的配置不显示。

## ProviderRegistry

注册表负责注册、查找、列出、绑定与凭据作用域判断。

| 方法 | 行为 |
| --- | --- |
| `register(provider)` | 校验 ID 匹配 `^[a-z0-9][a-z0-9_-]{0,63}$` 且名称非空；重复 ID 抛错 |
| `unregister(id)` | 移除单个服务，供设置提交时重建注册表 |
| `list()` | 返回 `ProviderInfo` 的副本，界面不能改到注册表内部 |
| `require(id)` | 未知 ID 抛出“未注册的模型服务”，提示重新选择 |
| `bind(config, credentials, origin?)` | 先 `require`，再校验端点、模型名，返回绑定快照 `BoundModel` |
| `sameCredentialScope(previous, providerId, baseUrl)` | 判断新旧地址是否属于同一凭据作用域 |

绑定是不可变的：`BoundModel` 在构造时固定 provider 实例、基础地址、模型、凭据别名、推理强度、图片与用量开关。此后修改设置或重建注册表只影响下一次运行，不会改变正在执行的任务。

`profileProvider(profile, effects)` 是原生注册入口。它为每份配置创建 `ProtocolProvider`，允许 HTTP（本地模型），并对 `openai`、`ollama` 预设关闭 `reasoning_content` 回传，避免向不接受该扩展字段的服务发送厂商字段。

## 一次请求前的解析顺序

```text
AgentRuntime.run()
  → ProviderRegistry.bind(config, credentials, usageOrigin)
        require(providerId) → provider.endpoint(baseUrl) 校验地址
        config.model 非空 → 返回 BoundModel
  → BoundModel.stream(messages, tools, cancellation, onText, options)
        cancellation.check()
        图片能力检查（images === false 时移除截图或拒绝图片附件）
        credentials.read(credentialAlias)      每次请求都重新读取
        authorize()                            华为账号状态检查
        cancellation.check()
        克隆 usageOrigin，附加 purpose / step
  → ProtocolProvider.stream(request, ...)
        endpoint(input.baseUrl) → protocolUrl(protocol, ...)
        effects.hydrate(messages)              文本附件并入正文，图片转 data URL（单图 4 MB）
        组装请求体与请求头，发起流式 HTTP
```

| 检查 | 时机 | 失败结果 |
| --- | --- | --- |
| 服务是否注册 | 每次运行绑定前 | 运行失败，提示重新选择模型 |
| 端点是否合法 | 绑定前 | 绑定失败，不发起网络请求 |
| 模型名是否为空 | 绑定前 | 绑定失败 |
| 密钥是否存在 | 每次模型请求前 | 明确提示重新填写 API Key |
| 华为账号状态 | 密钥读取之后、请求之前 | 可重试错误，不发送请求 |

## 凭据与密钥生命周期

API Key 保存在系统 Asset Store，写入属性为 `DEVICE_UNLOCKED` 且 `SyncType.NEVER`，不跨设备同步，也不进入会话、诊断日志或备份。

`ProfileSettings.save()` 负责配置与密钥的提交顺序：

1. 校验草稿与服务是否存在；`sameCredentialScope()` 比较新旧协议与地址，决定能否沿用旧密钥。
2. 未启用“无需 API Key”、密钥为空、且没有可沿用的同作用域别名时，要求重新填写。
3. 新密钥先写入形如 `tinybot-<uuid>` 的别名，再提交配置；提交失败会尝试删除刚写入的别名。
4. 提交成功后删除旧别名；旧密钥清理失败只返回警告，不否定已保存的配置。
5. 密钥为空时沿用旧别名，但会先 `read()` 一次，避免“保存成功但系统里取不到密钥”。

作用域只比较协议、主机、端口与基础路径；同一基础地址下切换协议或修改名称、模型、上下文窗口都不会更换密钥，更换域名、端口或 HTTP/HTTPS 时需重新填写。

## 华为账号校验注入

账号校验不是会话数据的一部分，而是注册表级别的回调：

- `createNativeSessionService()` 用 `new ProviderRegistry(() => huaweiAccount.requireLogin())` 创建注册表；`BoundModel` 在读取密钥后调用该回调，因此聊天、标题、摘要、记忆与团队请求都会经过同一检查。
- `SessionService` 在发送、压缩、恢复队列、表单续跑与重新生成之前调用 `resources.authorizeGeneration()`，避免未登录时清空草稿或创建分支。
- `HuaweiAccount.requireLogin()` 先等待初始化完成，再在设备上查询 OpenID 状态；失败、账号切换或并发检查的旧结果都会阻止请求。并发请求共享同一次检查，退出登录用修订号阻止旧检查恢复登录态。
- 登录记录只保存 OpenID，不使用或持久化授权码、ID Token、UnionID；账号信息不写入 `AppData`、备份或诊断日志。

## Chat Completions 的转换与端点校验

地址先由 `completionUrl()` 校验：必须是 HTTP 或 HTTPS（配置默认允许 HTTP 以支持本地模型），不能包含账号密码、查询参数、反斜杠或片段；末尾斜杠会被去掉。若地址已经以 `/chat/completions` 结尾则直接使用，否则追加该路径。

`protocolUrl()` 再按协议追加后缀：

| 协议 | 后缀 | 额外规则 |
| --- | --- | --- |
| `chat-completions` | `/chat/completions` | 地址已带其他协议的接口路径时报“接口路径与所选协议不一致” |
| `responses` | `/responses` | 同上 |
| `anthropic-messages` | `/messages` | 只有主机没有路径时补 `/v1/messages` |

`chatRequest()` 的固定行为：

- `stream: true`；有工具时传 `tools` 与 `tool_choice: 'auto'`，无工具时不传。
- 只有调用方显式给出 `maxOutputTokens` 才写 `max_tokens`，正常聊天不主动设置输出上限。
- 有图片时 `content` 转为 `[{type:'text'}, {type:'image_url'}]` 数组，否则保持字符串。
- `reasoning_content` 仅在 `replayReasoning` 为真且角色为 assistant 时回传；OpenAI 与 Ollama 预设关闭该行为。
- `requestUsage !== false` 时附加 `stream_options: { include_usage: true }`。

请求头默认 `Content-Type: application/json` 与 `Accept: text/event-stream`；有密钥时使用 `Authorization: Bearer <key>`。

## Anthropic 与 Responses 的差异

| 项目 | Chat Completions | Responses | Anthropic Messages |
| --- | --- | --- | --- |
| 鉴权头 | `Authorization: Bearer` | 同左 | `x-api-key` + `anthropic-version: 2023-06-01` |
| 系统指令 | `system` 角色消息 | 提升为 `instructions` | 提升为顶层 `system` |
| 输出上限 | 不传 | 不传 | `max_tokens` 默认 4096 |
| 工具结果 | `tool` 消息 + `tool_call_id` | `function_call_output` | `tool_result` 内容块 |
| 工具调用 | `tool_calls` | `function_call` 条目 | `tool_use` 内容块 |
| 图片 | `image_url` | `input_image` | base64 `image` 块 |

Anthropic 适配还有三点行为差异：

- 如果助手消息带有 `anthropicContent`，会原样、按序重放完整内容块（含签名思考），而不是从文本与工具调用重新拼装；重放前会做结构校验。
- 流式解析按内容块索引推进，`message_start`、`content_block_start/delta/stop`、`message_delta`、`message_stop` 的状态必须自洽；结束原因只接受 `end_turn`、`stop_sequence`、`tool_use`。
- 推理强度写入 `output_config.effort`；对支持自适应思考的模型额外设置 `thinking: { type: 'adaptive' }`，不虚构 `budget_tokens` 映射。

## 密钥读取时机

| 时机 | 行为 |
| --- | --- |
| 保存服务 | 有新密钥则写入新别名并提交配置；无新密钥则沿用旧别名并读取一次确认可用 |
| 应用启动 | 不读取 API Key；只从 `AppData` 恢复配置与别名 |
| 每次模型请求 | 按别名读取密钥，随后做账号检查；不在内存缓存密钥 |
| 删除服务 | 先提交移除配置，再删除对应别名；删除失败返回警告 |
| 请求失败 | 只展示状态码与本地化提示，不复制上游响应体，避免回显提示词或凭据 |

## 新增服务需要改哪里

新增一个 Chat Completions 兼容服务，通常只需元数据：

1. 在 `model/Provider.ets` 的 `builtinProviderInfos()` 中增加 ID、名称、协议、默认地址、默认模型、模型清单，按需补充 `apiKeyUrl`、`description`、`endpointPlaceholder`、`noApiKey`。
2. 如需品牌图标，在 `common/ProviderBrand.ets` 的 `providerLogo()` 中按预设 ID 登记资源；未登记时使用通用图标。
3. 不需要新适配器：保存后 `profileProvider()` 会用 `ProtocolProvider` 按该配置注册；编辑器从预设生成选项，不靠名称推断。
4. 若服务对推理字段有特殊要求，检查 `supportsReasoningEffort`、`reasoningEfforts`（`model/ReasoningEffort.ets`）与 `applyReasoningEffort()`。

新增不同协议时，还需要：

1. 在 `WireProtocols.ets` 增加请求体、请求头与端点后缀，并在 `protocolUrl()` 的路径冲突检查中登记该后缀。
2. 在 `EventStreams.ets` 增加流解析器（可复用 `EventFrames` 分帧），在 `ProtocolProvider` 中按协议选择解析器。
3. 在 `model/ProviderProfiles.ets` 的 `validateProfile()` 协议白名单中加入新协议。
4. 若支持推理强度，在 `applyReasoningEffort()` 中加入该协议的分支。
5. 用 `entry/src/test/Providers.test.ets`、`ProviderProfiles.test.ets` 与 `scripts/test-tool-schemas.cjs` 验证请求结构与流式行为。

完整步骤与检查清单见[新增模型服务](/dev/add-provider)。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/model/Provider.ets` | 内置预设元数据与默认服务 ID |
| `entry/src/main/ets/model/ProviderProfiles.ets` | 配置实例、模型引用、校验与迁移 |
| `entry/src/main/ets/services/providers/ProviderRegistry.ets` | 注册、查找、绑定与凭据作用域 |
| `entry/src/main/ets/services/providers/Provider.ets` | `ModelProvider`、`ModelSession`、`CredentialReader` 接口 |
| `entry/src/main/ets/services/providers/DefaultProviders.ets` | 由配置实例创建 `ProtocolProvider` |
| `entry/src/main/ets/services/providers/ProtocolProvider.ets` | 网络请求、流选择、超时与取消 |
| `entry/src/main/ets/services/providers/WireProtocols.ets` | 请求头、端点后缀、Responses 与 Anthropic 请求体 |
| `entry/src/main/ets/services/providers/ChatCompletionsProtocol.ets` | Chat Completions 请求转换与地址校验 |
| `entry/src/main/ets/services/providers/EventStreams.ets` | Responses 与 Anthropic 流解析 |
| `entry/src/main/ets/services/providers/ProviderErrors.ets` | HTTP 错误、临时错误与上下文溢出分类 |
| `entry/src/main/ets/services/CredentialStore.ets` | 系统安全存储读写 |
| `entry/src/main/ets/services/ProfileSettings.ets` | 服务配置提交与密钥生命周期 |
| `entry/src/main/ets/services/HuaweiAccount.ets` | 账号登录、状态校验与 `requireLogin()` |