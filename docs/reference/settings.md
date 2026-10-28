# 设置项

设置不是一个单独的配置文件：模型服务、助手偏好、工具开关和资料保存在会话索引里，外观与语言保存在设备 Preferences 里，密钥保存在 Asset Store 里。这一页按存储位置和功能分组列出这些键、默认值与生效时机，方便排查“改了为什么没生效”。开关在界面上的位置见[设置](/guide/settings)，服务连接与协议细节见[模型服务](/internals/providers)。

## 持久化位置

“设置 → 实验室 → 小程序”控制小程序功能。`productivity.options.miniAppsEnabled` 默认为 `false`，旧配置缺少该字段时也视为关闭。开启后显示小程序入口并提供 `list_mini_apps`、`publish_mini_app` 工具；关闭后隐藏入口并阻止相关工具调用，保留已有小程序、数据和历史记录。普通页面预览不受此开关影响。有任务正在执行时，需等任务完成后再修改。

| 位置 | 载体 | 内容 | 进入备份 |
| --- | --- | --- | --- |
| `sessions-v2/index.json` | 会话索引的 `data` 字段 | `config`、`providerProfiles`、`extensions`、`productivity`、`projects`、`activeThreadId` | 是（凭据字段被剥离） |
| `sessions-v2/<uuid>.json` | 独立会话文件 | 每个会话的模型选择、推理强度、工具选择、团队、停用的 MCP 服务 | 是 |
| `tinybot-ui` Preferences | 键值 | `appearance`、`language`、`onboardingComplete` | 否 |
| `tinybot-developer` Preferences | 键值 | `enabled`（开发者模式） | 否 |
| Asset Store | 凭据别名 | 模型 API Key、MCP Token、搜索 Key | 否 |
| `usage-records` | 分块账本 | 请求与工具用量 | 否 |

语言偏好与用量账本都不在备份范围内；换机恢复后需要重新选择语言，用量从零开始累计。

## 模型服务

| 键 | 含义 | 默认 | 生效时机 |
| --- | --- | --- | --- |
| `config.providerId`、`config.model` | 当前服务与新会话默认模型 | 首个内置预设及其默认模型 | 下一次请求 |
| `config.baseUrl` | 解析后的服务基础地址 | 预设默认地址 | 下一次请求 |
| `config.configured` | 是否已配置可用模型 | `false` | 保存服务后为 `true` |
| `config.credentialAlias` | 当前密钥的 Asset Store 别名 | 空 | 下一次请求 |
| `config.contextWindow` | 覆盖上下文窗口 | 未设置：按模型默认 | 下一次请求 |
| `config.autoCompact` | 接近上限时自动压缩 | `true` | 下一次请求 |
| `config.reasoning` | 新会话默认推理强度 | 未设置（跟随服务默认） | 新会话或空会话 |
| `providerProfiles[].id` | 服务实例 ID | `provider-<uuid>` 或预设 ID | 保存后重建注册表 |
| `providerProfiles[].name` | 显示名称 | 预设名称 | 立即 |
| `providerProfiles[].presetId` | 内置预设来源 | 自定义服务为空 | 仅用于展示与图标 |
| `providerProfiles[].protocol` | `chat-completions`、`responses`、`anthropic-messages`、`gemini` | 由预设决定 | 下一次请求 |
| `providerProfiles[].baseUrl` | 服务地址，保存时去掉末尾斜杠 | 预设地址 | 下一次请求 |
| `providerProfiles[].credentialAlias` | 密钥别名；无密钥时为空 | 空 | 保存成功后写入 |
| `providerProfiles[].noApiKey` | 无需密钥（如本地 Ollama） | `false` | 下一次请求 |
| `providerProfiles[].enabled` | 是否启用 | `true` | 保存后立即过滤可选模型 |
| `providerProfiles[].models` | 该服务的模型 ID 列表 | 预设列表 | 下一次请求 |
| `providerProfiles[].contextWindow` | 该服务的窗口覆盖 | 未设置 | 下一次请求 |

- 上下文窗口通用默认 200000 tokens；`deepseek-flash`、`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp`、`deepseek-v4-pro`、`glm-5.3`、`glm-5.3-flash` 默认 1000000。显式值范围 8192–2000000，留空恢复自动值。
- 密钥保存在 Asset Store，别名为 `tinybot-<uuid>`，禁止跨设备同步。同一服务基础地址下改协议、名称、模型或窗口会保留密钥；更换域名、端口、HTTP/HTTPS 或基础路径时要求重新填写。
- 保存失败会删除本次新建的密钥；更换密钥后会尝试删除旧别名，删除失败只提示“旧密钥清理失败”，不回滚新配置。
- 删除或停用服务后，引用它的会话需要重新选择模型，应用不会自动切换。

## 助手偏好与上下文

| 键 | 含义 | 默认 | 生效时机 |
| --- | --- | --- | --- |
| `config.userDocument` | USER.md 个人偏好，附加到所有对话 | 空字符串 | 下一轮 |
| `productivity.options.autoMemory` | 自动提取长期记忆 | `true` | 下一轮（同时决定 `memory` 工具是否出现） |
| `productivity.options.saveSummary` | 把成功回答归档到工作区“任务结果” | `false` | 下一次任务结束 |
| `productivity.options.readOnly` | 全局只读模式 | `false` | 下一轮 |
| `productivity.options.autoRoute` | 按内容自动选择快/深模型 | `false` | 下一次请求 |
| `productivity.memories[]` | 长期记忆条目 | 空 | 新会话首次组装上下文时固定 |
| `productivity.templates[]` | 提示词模板 | 两个内置模板（总结材料、润色文字） | 立即 |

- 记忆上限 100 条、合计 16000 字符；注入上下文按更新时间取到预算为止。
- 每个会话在首次发送时捕获一份背景记忆快照，之后自动记忆的变更不会改写当前会话的固定快照，以 `memory` 工具的最新回执为准。
- `systemPrompt` 由应用维护，读取时会被重置为内置提示词，界面不提供修改入口。

## 工具与权限

| 键 | 含义 | 默认 | 生效时机 |
| --- | --- | --- | --- |
| `extensions.webEnabled` | 允许网页读取与联网搜索 | `true` | 下一轮工具目录 |
| `extensions.browserPolicy` | 应用内浏览器：`unset`、`enabled`、`disabled` | `enabled`（默认开启，可随时关闭；`unset` 表示尚未确认，首次使用时询问） | 立即 |
| `extensions.skills[]` | Skill 名称、正文、参考文件、启用与 `manualOnly` | 空 | 下一轮 |
| `extensions.seededBuiltinSkills[]` | 已处理过的内置 Skill 名称 | 空 | 内置安装时写入 |
| `productivity.options.search` | 搜索服务配置，见下节 | `bing-browser` 且已启用 | 下一轮创建工具时 |
| `threads[].agentMode` | `full` 或 `custom` | 旧会话按完整版 | 当前会话立即 |
| `threads[].disabledTools[]` | 被关闭的可选工具名 | 空 | 当前会话立即，随下一条消息保存 |
| `threads[].disabledMcpIds[]` | 本会话停用的 MCP 服务 | 空 | 下一轮 |
| `threads[].teamEnabled` | 是否启用团队工具 | 未设置 | 当前回合 |

- 只读模式会移除写文件、编辑、`mcp_call`、`memory`、`skill_manage`、`mcp_manage`，并限制浏览器点击与输入；基础文件读取、代码沙箱、计划、预览和交付仍可用。
- 自定义模式只关闭 12 项可选能力，基础文件工具与记忆、Skills 由专门设置控制；旧配置里只关闭部分子工具时，加载会把整项能力关闭。
- 执行期间页面锁定，保存失败会回滚开关并提示；有保存错误时编辑入口不可用。
- 从旧版本升级时，未写入的 `browserPolicy` 与 `search` 会补为当前默认值（应用内浏览器开启、必应搜索开启）；已保存的选择保持不变。

## 搜索服务

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `search.provider` | `deepseek`、`tavily` 或 `bing-browser` | `bing-browser` |
| `search.enabled` | 是否启用联网搜索 | `true` |
| `search.modelProviderId` | 复用哪个 DeepSeek 服务的密钥 | 留空自动选择，多个候选时必须指定 |
| `search.baseUrl` | Tavily 地址，必须 HTTPS | `https://api.tavily.com` |
| `search.credentialAlias` | Tavily 密钥别名 | 空 |
| `search.tavily` | 跨提供方保留的 Tavily `baseUrl` 与 `credentialAlias` | 首次编辑或切走 Tavily 时记录 |
| `search.deepseek.modelProviderId` | 跨提供方保留的 DeepSeek 服务选择 | 留空自动选择 |

必应（`bing-browser`）不需要密钥、地址或模型服务，通过应用内浏览器访问必应；应用内浏览器被关闭时内置搜索同时停用。DeepSeek 搜索复用官方地址的模型服务密钥，不需要单独填写；Tavily 的密钥保存为 `tinybot-search-<uuid>`。更换搜索地址后必须重填密钥；启用时若读不到已保存的密钥，保存会失败而不是留下空配置。

搜索页列表维护独立草稿，详情页只编辑并返回；列表底部统一保存。切换提供方保留其他提供方配置。为兼容旧版本，当前提供方仍使用顶层 `baseUrl` / `credentialAlias` / `modelProviderId`，加载旧 Tavily 配置后首次保存会保留其别名；原始密钥只写入安全存储。备份导出与恢复都会清空非当前提供方的 Tavily 别名。

## MCP 服务

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `servers[].id` | 服务 ID | 创建时生成 |
| `servers[].name` | 显示名称（≤40 字符） | 必填 |
| `servers[].url` | HTTPS 地址，不含账号或片段 | 必填 |
| `servers[].enabled` | 是否启用 | 保存时默认 `true` |
| `servers[].authType` | `oauth` 或省略（无鉴权或 Bearer） | 省略 |
| `servers[].credentialAlias` | Bearer Token 或 OAuth 凭据别名 | 空 |

最多 10 个服务。保存前先连接验证并列出工具，失败保留旧配置；新增凭据失败会回滚本次创建的别名。会话里的停用记录优先于全局启用状态。

## 模型分工与能力

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `options.fast`、`options.deep`、`options.vision`、`options.memory` | 快速、深入、图片、记忆整理分别使用的模型 | 未设置时沿用当前模型 |
| `options.capabilities[]` | 每个模型的 `images`、`reasoning`、`contextWindow`、`requestUsage` 覆盖 | 空 |
| `threads[].reasoningEffort` | 本会话推理强度，`default` 表示跟随服务 | 未设置 |

自动路由开启后，带图片的消息走 `vision`，文本超过 1000 字符或包含“深入”“分析”“比较”等关键词时走 `deep`，其余走 `fast`；未配置的目标模型不会启用该分支。推理强度按模型能力给出可选档位，`default` 是本地哨兵，不发送给服务。

## 外观与语言

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `appearance.mode` | `system`、`light`、`dark` | `system` |
| `appearance.accent` | `green`、`blue`、`purple`、`amber`、`rose`、`custom` | `green` |
| `appearance.fontScale` | 0.9、1、1.15、1.3 | `1` |
| `appearance.fontFamily` | 字体族，≤128 字符 | 空（跟随系统） |
| `appearance.lightEffect` | `auto`、`off`、`gentle`、`standard`、`vivid` | `auto` |
| `appearance.customColor` | 自定义主色的十六进制值 | `#216451` |
| `language` | `system`、`zh-CN`、`en` | `system` |
| `onboardingComplete` | 首次使用指引是否已完成 | `false`（未写入） |

外观以一条 JSON 字符串存在 `tinybot-ui` 的 `appearance` 键下，启动时在首帧之前应用；保存会先写盘再应用，失败回滚到上一份。语言偏好只影响界面文案，不重写模型请求、用户消息或已保存内容；切换语言会重建视图树，但保留会话视图模型、导航栈与草稿。

## 诊断

| 键 | 含义 | 默认 |
| --- | --- | --- |
| `enabled`（`tinybot-developer`） | 开发者模式是否已解锁 | `false` |

开发者模式只写入本机 Preferences，不进入备份；进程重启后保留入口，但不会自动开始采集。日志等级默认为 Info，重启后恢复 Info。更细的采集项与导出方式见[性能诊断](/internals/diagnostics)。

## 生效时机

| 改动 | 生效点 |
| --- | --- |
| 外观、语言 | 立即生效；下次启动时在首帧前应用 |
| 助手开关（自动记忆、只读、归档、自动压缩、联网） | 写盘成功后立即，下一轮请求读取新值 |
| 称呼与回答偏好 | 下一轮 |
| 模型服务的新增、修改、删除 | 保存后立即重建服务注册表；会话已选模型在下一次请求解析 |
| 搜索服务 | 下一轮创建工具时 |
| MCP 保存、启用、停用 | 保存后全局配置立即更新；会话级停用立即影响下一轮 |
| 自定义工具选择 | 当前会话立即，随下一条有效消息保存 |
| 推理强度 | 当前会话下一条消息；空会话跟随默认值 |
| 长期记忆 | 当前会话的背景快照不随之变化 |

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/model/Conversation.ets` | `AppData`、`ModelConfig` 与 `parseAppData` 校验 |
| `entry/src/main/ets/model/AssistantOptions.ets` | 助手开关、模型分工与自动路由 |
| `entry/src/main/ets/model/Skills.ets` | `ExtensionSettings` 与联网、浏览器、Skills |
| `entry/src/main/ets/model/Productivity.ets` | 记忆、模板、MCP 服务与上限校验 |
| `entry/src/main/ets/model/ProviderProfiles.ets` | 服务实例、模型引用与地址/凭据边界 |
| `entry/src/main/ets/model/WebSearch.ets` | 搜索配置与密钥解析 |
| `entry/src/main/ets/services/ProfileSettings.ets` | 模型服务保存、密钥生命周期与回滚 |
| `entry/src/main/ets/services/SearchSettings.ets` | 搜索配置与密钥保存 |
| `entry/src/main/ets/services/McpSettings.ets` | MCP 配置、连接验证与凭据回滚 |
| `entry/src/main/ets/services/AppearancePreferences.ets` | 外观偏好的读写与应用 |
| `entry/src/main/ets/services/LanguagePreferences.ets` | 语言偏好与界面刷新 |
| `entry/src/main/ets/services/OnboardingPreferences.ets` | 首次使用指引的完成记录 |
| `entry/src/main/ets/services/DeveloperDiagnostics.ets` | 开发者模式开关与采集 |
| `entry/src/main/ets/views/SettingsPanel.ets` | 设置页分组、开关与保存交互 |
