# 新增模型服务

模型服务由三部分构成：**预设元数据**（用户看到的内置服务）、**服务实例配置**（`ProviderProfile`，用户可编辑）、**协议适配**（`ProtocolProvider` 按协议编码请求）。新增一个兼容服务通常只改前两项。

## 协议与预设

`model/ProviderProfiles.ets` 的 `validateProfile` 只接受三种协议：

| 协议 ID | 用途 |
| --- | --- |
| `chat-completions` | OpenAI Chat Completions 兼容接口（DeepSeek、DashScope、Z.ai、Ollama 等） |
| `responses` | OpenAI Responses |
| `anthropic-messages` | Anthropic Messages |

内置预设集中在 `model/Provider.ets` 的 `builtinProviderInfos()`，包含默认地址、默认模型、候选模型、密钥申请地址和说明。新增一个兼容服务的最小改动是往这个数组里加一条：

```ts
{ id: 'my-gateway', name: t('我的网关'), protocol: 'chat-completions',
  defaultBaseUrl: 'https://gateway.example.com/v1', defaultModel: 'my-model',
  models: ['my-model', 'my-model-mini'], apiKeyUrl: 'https://gateway.example.com/keys' }
```

约束来自 `validateProfile`：

- `id` 必须匹配 `^[a-z0-9][a-z0-9_-]{0,63}$`，且不能与已注册服务重复。
- `name` 非空、不超过 80 字符。
- `models` 至少一个，不能重复，每个不超过 200 字符。
- `noApiKey` 为真时 `credentialAlias` 必须为空（如 Ollama），为假时必须非空。
- `presetId` 若存在，必须是已有内置预设的 id。
- 地址由 `protocolUrl(protocol, baseUrl, true)` 校验，HTTP 明文地址只对本地/自建服务放开。

## 注册与绑定

`services/providers/ProviderRegistry.ets` 负责注册、按 id 查找和按次绑定：

- `register(provider)` 校验 id 与名称，重复注册直接报错。
- `bind(config, credentials, origin)` 在运行开始时固定 provider 实例、地址、模型和凭据别名；之后修改设置不影响正在运行的任务。
- 每次请求前读取密钥（`CredentialReader.read`），支持轮换而不用缓存明文。
- 注册表整体重建由 `NativeSessionService.configureProviders()` 完成：先注销全部旧实例，再按 profile 注册。

应用侧的注册入口是 `services/providers/DefaultProviders.ets` 的 `profileProvider()`，它把 `ProviderProfile` 转成 `ProtocolProvider`；`presetId` 为 `openai` 或 `ollama` 时不回放推理内容。

## 新协议适配

当服务商不兼容上述三种协议时，实现 `ModelProvider`：

```ts
export interface ModelProvider {
  readonly info: ProviderInfo
  endpoint(baseUrl: string): string
  stream(request: ProviderRequest, cancellation: Cancellation,
    onText: (text: string) => void, onReasoning?: (text: string) => void): Promise<ModelTurn>
}
```

- `endpoint()` 负责地址规范化与合法性校验，注册和绑定时都会调用。
- `stream()` 自行把 `ModelMessage` 和 `ToolDefinition` 编码成协议请求，解析流式增量和工具调用，返回 `ModelTurn`。
- `tool_calls`、`tool_call_id` 等 HTTP 字段只应出现在这一层；领域层始终使用 `ToolCall`。
- 取消通过 `Cancellation` 贯穿：准备、读密钥、网络与解码都要检查。
- 新增协议后，把协议 ID 加进 `validateProfile` 的白名单和 `WireProtocols.protocolUrl`，再补 `ReasoningRequest` 的档位映射。

## 凭据

- 密钥保存在系统安全存储（AssetStore），按 `credentialAlias` 读取，不进入会话、日志、备份或诊断导出。
- 模型服务设置页只展示别名与是否存在，不回显明文。
- 保存顺序由 `ProfileSettings` 管理：先写凭据再提交配置，失败时回滚。

## 测试

| 验证 | 命令或位置 |
| --- | --- |
| 注册、绑定、配置快照 | `ProviderRegistry.test.ets` |
| 三协议请求结构与 schema | `node scripts/test-tool-schemas.cjs` |
| 推理档位序列化 | `ReasoningEffort.test.ets` |
| 真实协议联调 | 在设备上用实际密钥，通过设置页配置后发送含工具调用的请求 |

合成协议测试不能替代真实服务验证：流式工具调用、图片输入、思考摘要和错误码都需要对实际服务确认。

## 检查清单

1. 预设加入 `builtinProviderInfos()`，或提供自定义 profile 入口。
2. `id` 稳定、小写、唯一；默认地址与模型可编辑。
3. 协议白名单、`protocolUrl` 与推理档位映射同步。
4. 密钥只走 `CredentialStore`，不写日志。
5. 绑定后不可变；修改设置只影响后续运行。
6. 词条、测试与文档更新完毕。
