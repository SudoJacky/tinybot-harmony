# 代码地图

这一页给出 `entry/src/main/ets` 各目录的职责、每个目录里值得先读的文件，以及新增功能应该落在哪里。文件名与路径均来自仓库，便于从文档直接跳进源码。

## 顶层结构

```text
entry/src/main/ets/
  pages/               页面入口与原生导航
  views/               页面内的 ArkUI 组件
  viewmodel/           ArkUI 状态投影与编辑器状态
  services/            会话、运行内核、工具与平台适配
  model/               数据结构、校验、纯逻辑与本地存储
  common/              设计令牌、通用控件与动效
  entryability/        UIAbility 生命周期与首屏装载
  entrybackupability/  系统备份扩展（华为云空间）
  entryformability/    桌面服务卡片扩展
  widget/              卡片页面（2×2、2×4）
entry/src/test/        Hypium 本地测试（不依赖真机与真实密钥）
scripts/               构建辅助、自动化测试与冒烟服务
```

## 目录职责

| 目录 | 职责 | 依赖约束 |
| --- | --- | --- |
| `pages/` | 组装页面、持有 `ChatViewModel` 与 `SessionService` 实例、注册原生导航目的地 | 只调用 ViewModel 与原生服务，不直接改会话数据 |
| `views/` | 声明式 UI：聊天、侧栏、消息、设置、面板与宿主组件 | 通过 `@ObjectLink`/`@Prop` 读取 ViewModel，不发起模型请求 |
| `viewmodel/` | 把 `SessionEvent` 投影为可观察状态；编辑器草稿、分页、展开状态 | 不访问文件、凭据、工具或运行时 |
| `services/` | 会话服务、运行内核、工具目录、协议适配、备份与诊断 | 依赖通过构造函数注入，平台实现放在 `Native*` 适配器 |
| `model/` | 数据结构、校验、上下文投影、用量与持久化 | 不依赖 ArkUI；文件系统只在 `WorkspaceStore`、`TextFiles` 等模块使用，会话数据走 ArkData 适配器 |
| `common/` | 主题令牌、通用控件、动效与品牌资源 | 只用 ArkUI 组件与资源，不读取会话 |
| `entryability/`、`entrybackupability/`、`entryformability/` | 三个扩展入口：应用生命周期与首屏装载、系统备份、桌面服务卡片 | 只做平台适配，业务交给 `services/` |
| `widget/` | 卡片页面：2×2 与 2×4 两种尺寸的展示与快捷入口 | 不联网、不定时刷新，跟随系统语言与主题 |

## pages

| 文件 | 说明 |
| --- | --- |
| `pages/Index.ets` | 唯一的页面入口：创建原生会话服务、持有抽屉与导航栈、把 `ChatPanel`、`ThreadList` 及各类面板组装成应用外壳；大屏上还负责命令面板、会话详情、旁聊、分栏拖动与布局恢复 |

## views

| 文件 | 说明 |
| --- | --- |
| `views/ChatPanel.ets` | 聊天主体：消息列表、输入区、附件与语音入口、上下文与推理强度控件、待发送面板挂载；桌面输入区尺寸与弹出层高度上限 |
| `views/DesktopCommandDialog.ets` | 大屏命令面板：会话与命令混合搜索、键盘选择 |
| `views/GeneratedImageCard.ets` / `ImageCompare.ets` | 生成图片的等待、显现、参考图对比与打开 |
| `views/SideChatPanel.ets` | 旁聊消息、草稿、发送、停止与删除 |
| `views/MessageBubble.ets` | 单条消息的正文、执行时间线、工具行与操作栏；生成图片与图片检查的展示 |
| `views/MarkdownView.ets` | Markdown 渲染入口 |
| `views/MarkdownChunkView.ets` | 长内容分块挂载与渐显，代码块默认折叠 |
| `views/ThreadList.ets` | 会话与项目侧栏：分组、搜索、置顶、归档与分页 |
| `views/ToolDetails.ets` | 工具回执详情：结果、参数、日志与原始记录分页 |
| `views/InputQueuePanel.ets` | 待发送指令列表：追加指令与队列任务的撤回、编辑、移除 |
| `views/SettingsPanel.ets` | 统一设置首页及子页导航 |
| `views/ProviderEditorPanel.ets` | 模型服务编辑页：预设、协议、地址、密钥、模型列表 |
| `views/WorkspacePanel.ets` | 工作区文件浏览、编辑、导入与导出 |
| `views/UsagePanel.ets` | 用量总览、会话、活动与请求明细 |
| `views/StoragePanel.ets` | 存储总览、分类明细与安全清理 |
| `views/StartupBackupDialog.ets` | 新安装恢复最新备份的确认与进度 |
| `views/SearchSettingsPanel.ets` / `SearchProviderPanel.ets` | 搜索服务列表草稿与各提供方详情 |
| `views/MiniAppsPanel.ets` | 小程序集合、打开、导出、恢复与移除 |
| `views/PreviewFullscreen.ets` / `PublishedPreviewCard.ets` | 预览卡片、侧区入口与全屏容器 |
| `views/BrowserPanel.ets` | 应用内浏览器宿主，保持 Web 实例常驻 |
| `views/PreviewCaptureHost.ets` | 预览截图宿主：按聊天宽度整卡渲染并截图 |

## viewmodel

| 文件 | 说明 |
| --- | --- |
| `viewmodel/ChatViewModel.ets` | 订阅 `SessionService`，投影会话、上下文与设置状态；草稿 800 ms 防抖；转发命令 |
| `viewmodel/SessionViewModels.ets` | `ThreadViewModel`、`MessageViewModel`、`AgentStepViewModel`、`ToolExecutionViewModel`：保留分组与展开状态 |
| `viewmodel/MessageListSource.ets` | `LazyForEach` 的数据源，只维持已挂载行 |
| `viewmodel/ProviderEditorViewModel.ets` | 模型服务编辑草稿与预设应用；图片协议、图片模型与同源校验 |
| `viewmodel/SkillEditorViewModel.ets` | Skill 文档与参考文件编辑草稿 |
| `viewmodel/PlanProgressViewModel.ets` | 单条助手消息的计划展示状态，不写入历史 |
| `viewmodel/DisclosureState.ets` | 消息级临时阅读状态，不随条件挂载丢失 |
| `viewmodel/WindowViewport.ets` | 窗口键盘与手势 inset，供输入区和底部面板避让 |

## services

按职责分组，同组文件通常一起改动。

| 文件 | 说明 |
| --- | --- |
| `services/SessionService.ets` | 会话数据唯一所有者：命令准入、队列、检查点、压缩、设置提交 |
| `services/SessionCandidates.ets` | 导入、项目设置与会话分支的候选数据变换；不做 IO 或提交 |
| `services/SessionContracts.ets` | `SessionRepository`、`SessionResources`、`SessionState`、`SessionEvent` 等契约 |
| `services/NativeSessionService.ets` | 原生组合根：文件仓库、工作区、凭据、ProviderRegistry、工具资源 |
| `services/AgentRuntime.ets` | 单次运行生命周期、事件订阅、`abort`、`waitForIdle`、`fork` |
| `services/AgentLoop.ets` | 与 UI 和协议无关的模型/工具循环、检查点与步数上限 |
| `services/RequestContext.ets` | 每次请求的指令组装、预算判断、压缩与用量基线 |
| `services/SessionContext.ets` | 会话级提示段、上下文源与压缩入口 |
| `services/ContextCompactor.ets` | 生成摘要并形成压缩检查点 |
| `services/ChatStream.ets` | Chat Completions 的 SSE 分帧、工具参数组装与完整性校验 |
| `services/RequestRetry.ets` | 只重试当前模型请求，不重放已完成步骤 |
| `services/Cancellation.ets` | 单次运行共享的取消信号 |
| `services/ToolSet.ets` | 工具目录与执行路由，未启用的工具不能执行 |
| `services/ToolExecution.ets` | 工具批次的顺序/并发调度与前后检查点 |
| `services/ToolCatalog.ets` | 完整授权工具目录的稳定排序与旧搜索入口拒绝 |
| `services/WorkspaceTools.ets` / `NativeWorkspaceFiles.ets` | 工作区工具定义与沙箱文件读写 |
| `services/providers/ProviderRegistry.ets` | 显式注册、配置绑定、每次请求前的凭据解析 |
| `services/ImageGenerationTools.ets` | `image_gen` 工具、参考图读取、输出保存与单独审批 |
| `services/ImageInspectionTools.ets` | `view_image` 工具、JPEG 视觉副本与回执 |
| `services/ImageGenerationProtocol.ets` | 四种图片协议的请求编码与响应解析 |
| `services/GeneratedImageLabel.ets` | 生成图片的“AI生成”标记绘制与 AIGC 元数据嵌入 |
| `services/NativeImageGenerator.ets` | 图片服务网络请求、超时、下载与错误映射 |
| `services/NativeImageWorkspace.ets` | 工作区图片与会话照片的统一读取 |
| `services/DesktopLayoutPreferences.ets` | 2in1 分栏宽度与收起状态的持久化 |
| `services/LifePanelTools.ets` | 看板卡片、看板布局与刷新任务工具 |
| `services/MailTools.ets` | 邮箱连接、查询与正文读取工具 |
| `services/providers/ProtocolProvider.ets` | NetworkKit 请求、取消、UTF-8 增量解码与空闲超时 |
| `services/providers/WireProtocols.ets` | Chat Completions、Responses、Anthropic 的请求体、请求头与端点拼接 |
| `services/providers/ChatCompletionsProtocol.ets` | Chat Completions 的消息转换与地址校验 |
| `services/providers/EventStreams.ets` | Responses 与 Anthropic 流式解析 |
| `services/providers/GeminiProtocol.ets` / `GeminiStream.ets` | Gemini 请求编码与流式解析 |
| `services/providers/ProviderErrors.ets` | 临时错误、上下文溢出与 HTTP 错误分类 |
| `services/CredentialStore.ets` / `ProfileSettings.ets` | 系统安全存储、服务配置提交与密钥生命周期 |
| `services/HuaweiAccount.ets` | 华为账号登录、状态校验与 `requireLogin()` |
| `services/Backup.ets` / `CloudBackup.ets` | 本机导出与华为云备份 |
| `services/StorageUsage.ets` | Ability/Application 双私有目录扫描、分类计数、孤儿附件与残留工作区识别、读取失败标记、部分删除按实际字节统计 |
| `services/BackupArchive.ets` | v3 二进制归档、256 KiB 分块、整包 SHA-256 与临时解包 |
| `services/BackupKeys.ets` / `BackupKeyRestore.ets` | OpenID 派生密钥、API Key 认证加密与安全存储恢复 |
| `services/StartupBackup.ets` | 新安装识别、云端最新备份查询与一次性提示记录 |
| `services/MiniApps.ets` / `MiniAppTools.ets` | 小程序发布、数据版本、归档与工具入口 |
| `services/AttachmentDrop.ets` | 拖入数据的类型识别、去重、导入与取消清理 |
| `services/BackgroundGeneration.ets` | 后台网络传输的长时任务、时限与中止处理 |
| `services/CompletionNotifications.ets` | 完成通知授权与点击回到会话 |
| `services/SearchSettings.ets` | 搜索提供方草稿、密钥切换与保存 |
| `services/NativeActions.ets` | 系统选择器、导出、分享与系统分享入口 |
| `model/Diagnostics.ets` / `services/NativeDiagnosticLog.ets` | 埋点聚合、脱敏白名单与唯一 HiLog 输出适配器 |
| `services/WebTools.ets`、`McpTools.ets`、`SkillTools.ets`、`PresentTools.ets` 等 | 各组工具的实现，统一注册进 `ToolSet` |

## model

| 文件 | 说明 |
| --- | --- |
| `model/Conversation.ets` | `AppData`、`ThreadData`、`MessageData`、`ModelConfig`；历史回放与 `parseAppData` 校验 |
| `model/ConversationStore.ets` | 旧版 v2 会话索引与独立文件，仅用于迁移与回溯 |
| `services/ArkDataRecords.ets` / `ArkDataConversationStore.ets` | 加密数据库、分块记录、事务提交与旧版导入 |
| `model/Agent.ets` | 步骤、工具调用、`ModelMessage` 与各项上限常量 |
| `model/Provider.ets` | 内置服务元数据（ID、名称、协议、默认地址、模型预设、密钥入口） |
| `model/ProviderEndpoint.ets` | 聊天与图片协议的端点拼接、凭据作用域与图片同源校验 |
| `model/ProviderProfiles.ets` | 服务配置实例、模型引用、图片服务解析、校验与迁移 |
| `model/DesktopCommandPalette.ets` | 命令面板的搜索、排序与结果截断 |
| `model/GeneratedImageMetadata.ets` | 生成图片的 TC260 AIGC XMP 字段与 PNG/JPEG/WebP 写入 |
| `model/ConversationContext.ets` | 上下文窗口、输入预算、压缩规划 |
| `model/ContextProjection.ets` | 完整历史到模型可见投影的切分 |
| `model/SystemPrompt.ets` | 固定身份提示、运行规则与用户文档 |
| `model/PendingInput.ets` | 待发送指令结构与入队顺序 |
| `model/ConversationTitle.ets` | 标题提示词、字符截断与清洗 |
| `model/SessionManagement.ets` | 会话名称校验与列表搜索排序 |
| `model/WorkspaceStore.ets` | 应用级工作区根目录与目录校验 |
| `model/Diagnostics.ets` / `DiagnosticLog.ets` | 事件、计时与字段白名单 |
| `model/Usage*.ets` | 用量记录、统计、查询与归属 |
| `model/StoragePlan.ets` | 存储分类、孤儿判定、缓存/临时文件过期规则与报表结构 |
| `model/BackupRestore.ets` | 备份中服务、MCP 与会话模型引用的重映射 |
| `model/MiniApp.ets` | 小程序清单、ID、路径、版本历史与页面校验 |
| `model/ToolGroups.ets` | 只读分组与 14 项可选能力清单 |

## common

| 文件 | 说明 |
| --- | --- |
| `common/Theme.ets` | 颜色、字号、间距、圆角与动效令牌 |
| `common/Widgets.ets` | 通用按钮、徽标、横幅等控件 |
| `common/AppearanceStyle.ets` | 外观样式替换值，组件共同观察 |
| `common/AppMaterials.ets` | 设备材质能力的一次性读取 |
| `common/LiquidToggle.ets` / `LiquidToggleMotion.ets` | 液态开关控件与动效 |
| `common/SwipeRow.ets` / `SwipeRowMotion.ets` | 滑动操作行与手势距离换算 |
| `common/SegmentedMotion.ets` | 分段选择动效 |
| `common/SendBubbleMotion.ets` | 发送气泡从输入区落入列表 |
| `common/SpeechOrb.ets` / `VoiceHoldButton.ets` | 语音输入反馈与按住说话 |
| `common/ProviderBrand.ets` / `WebsiteIcon.ets` | 服务商品牌与站点图标 |
| `common/DeviceForm.ets` | 设备形态判断（手机、平板、2in1 与大屏组合） |
| `common/PaneDivider.ets` | 可拖动分隔线、键盘调整、双击复位与桌面光标 |
| `common/MaterialMenu.ets` | 材质菜单构建与设备能力降级 |

## 测试与脚本

`entry/src/test/` 使用 Hypium，运行在本地测试环境，不依赖真机和真实模型密钥；`List.test.ets` 是全部用例的注册入口。

| 文件 | 覆盖重点 |
| --- | --- |
| `SessionService.test.ets` | 队列调度、收尾保存、停止与恢复、草稿隔离、配置与密钥回滚、压缩回滚 |
| `Runtime.test.ets` | 运行生命周期、事件顺序、禁止重入、收尾持久化 |
| `Agent.test.ets` | 多轮执行、工具回执、步数限制、取消、历史协议还原 |
| `Core.test.ets` / `Advanced.test.ets` | 流式分帧、工具参数组装、执行前落盘失败、工具错误恢复 |
| `Providers.test.ets` / `ProviderProfiles.test.ets` | 注册表、配置快照、绑定与凭据、配置校验与迁移 |
| `ContextManagement.test.ets` | 上下文预算、压缩与请求投影 |
| `PendingInput.test.ets` | 追加指令与队列顺序、边界校验 |
| `ChatTeam.test.ets` / `Team.test.ets` | 团队招募、交接与恢复 |
| `SystemPrompt.test.ets` | 提示词分层、旧配置迁移、条件章节 |
| `ToolParallelism.test.ets` | 工具批次调度与并发边界 |

`scripts/` 按用途分类：

| 类别 | 代表文件 | 用途 |
| --- | --- | --- |
| 测试入口 | `test.ps1` | 依次运行词条校验、批量 `.cjs` 测试与 Hypium 用例；可用 `DEVECO_STUDIO_HOME` 指定 SDK |
| 构建后校验 | `test-usage-performance.cjs`、`test-tool-schemas.cjs`、`test-tool-catalog.cjs`、`test-markdown-performance.cjs` | 针对实际编译产物验证协议、性能与渲染回调 |
| 界面与功能 | `test-tablet-workbench.cjs`、`test-productivity-native.cjs`、`test-file-attachments.cjs` | 窗口断点与分栏、命令面板、图片附件与生成、看板与邮件等原生适配 |
| 模拟服务 | `request-context-smoke-server.cjs`、`team-smoke-server.cjs`、`interactive-ui-smoke-server.cjs`、`web-ui-preflight-smoke-server.cjs` | 本地起服务，验证流式协议、团队与预览路径 |
| 资源生成 | `build-locales.cjs`、`build-builtin-skills.cjs`、`build-app-icons.cjs`、`build-web-ui-vendor.cjs` | 由源文件生成词条、内置 Skill、图标与 Web 运行库 |
| 发布 | `prepare-distribution.ps1`、`check-release-package.ps1` | 整理分发目录与检查发布包 |

测试命令与环境见[测试与冒烟验证](/dev/testing)。

## 新增功能落点

| 要改的东西 | 首选位置 | 需要同步 |
| --- | --- | --- |
| 新的聊天界面或面板 | `views/`，必要时在 `pages/Index.ets` 注册导航目的地 | ViewModel 增加只读投影；状态变化走 `SessionEvent` |
| 新的会话命令 | `services/SessionService.ets` | 准入检查、`SessionEvent`（如界面需要）、失败文案 |
| 新的持久化字段 | `model/Conversation.ets` 的接口与 `parseAppData` 校验 | 存储适配器无需改动；备份导入导出与 `AppData` 快照 |
| 新的模型协议 | `services/providers/`：请求体、请求头、端点后缀、流解析 | `validateProfile` 的协议白名单与 `applyReasoningEffort`，见[新增模型服务](/dev/add-provider) |
| 新的图片协议 | `services/ImageGenerationProtocol.ets` 的请求编码与响应解析，`model/ProviderEndpoint.ets` 的后缀与同源规则 | 编辑器协议列表、`IMAGE_PROTOCOLS` 与图片工具测试 |
| 新的桌面窗口行为 | `model/WorkbenchLayout.ets` 的几何与 `pages/Index.ets` 的窗口分支 | `services/DesktopLayoutPreferences.ets`、`test-tablet-workbench.cjs` |
| 新的旁聊行为 | `services/SessionService.ets` 的创建、发送与带回；`views/SideChatPanel.ets` | `viewmodel/ChatViewModel.ets`、`model/Project.ets` 的校验、旁聊工具白名单 |
| 新的内置模型服务预设 | `model/Provider.ets` 的 `builtinProviderInfos()` | 密钥入口链接、图标资源 `common/ProviderBrand.ets` |
| 新的工具 | `services/*Tools.ets` 并注册进 `ToolSet` | 工具分组 `model/ToolGroups.ets`、审批与只读规则，见[新增工具](/dev/add-tool) |
| 新的界面文案 | `locales/*.json` | 运行 `node scripts/build-locales.cjs`，见[词条维护](/dev/i18n) |

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/pages/Index.ets` | 应用外壳与导航 |
| `entry/src/main/ets/views/ChatPanel.ets` | 聊天主体 |
| `entry/src/main/ets/viewmodel/ChatViewModel.ets` | 状态投影与命令转发 |
| `entry/src/main/ets/services/SessionService.ets` | 会话服务 |
| `entry/src/main/ets/services/AgentLoop.ets` | 模型/工具循环 |
| `entry/src/main/ets/model/ConversationStore.ets` | 旧版会话文件与迁移 |
| `entry/src/main/ets/services/ArkDataConversationStore.ets` | 会话持久化 |
| `entry/src/main/ets/services/providers/ProviderRegistry.ets` | 服务注册与绑定 |
| `entry/src/test/List.test.ets` | 本地测试注册入口 |
| `scripts/test.ps1` | 自动化测试入口 |