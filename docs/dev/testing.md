# 测试与冒烟验证

仓库的验证分三层：Hypium 本地单元测试、基于编译产物的原生适配测试（`scripts/*.cjs`），以及必须在真机或模拟器上完成的手动检查。`scripts/test.ps1` 把前两层串成一次可重复的入口。

## 一次跑完

```powershell
devecocli check arkts
devecocli build
.\scripts\test.ps1
```

`test.ps1` 先跑 Node 验证脚本（词条与内置 Skill 检查、账号、日志、浏览器、渲染、设置、预览、工具、编排、团队、文件备份恢复、引导、法务文档），再用 DevEco 的 `hvigorw test` 跑 Hypium 单元测试，并检查报告确实刷新且 `Failure: 0, Error: 0`、通过数非零。

很多脚本读取的是编译产物——**先构建，再运行**。文中标注“需构建”的项在没有产物时会失败，这不是代码回归。

## 脚本矩阵

| 脚本 | 覆盖内容 | 需构建 |
| --- | --- | --- |
| `build-locales.cjs --check` | 词条键一致性、占位符、代码中的 `t()` 引用 | 否 |
| `build-builtin-skills.cjs --check` | 内置 Skill 打包是否为最新 | 否 |
| `test-conversation-export.cjs` | 导出时的 Markdown/HTML 标识、PNG 元数据 CRC 与像素载荷、长会话完整拼接、失败清理 | 否 |
| `test-workspace-backup-ui.cjs` | 编译后文件页的失败保存、内容无法预览时导出原始备份、重试与新文件状态 | 是 |
| `test-huawei-account.cjs` | 登录/取消、错误码脱敏、重启恢复、账号切换、退出与迟到回调、存储失败、未登录请求拦截 | 否 |
| `test-app-information.cjs` | 实际评分入口打开当前应用写评论页、重复点击、跳转或包信息读取失败提示与重试 | 否 |
| `test-developer-diagnostics.cjs` | 诊断采集、导出与生命周期 | 否 |
| `test-unified-logging.cjs` | 日志级别、脱敏、导出与禁用路径 | 否 |
| `test-browser.cjs` | 浏览器权限、接管与运行暂停 | 否 |
| `test-browser-annotation.cjs` | 批注几何、导出与图片投递 | 否 |
| `test-code-highlight.cjs` | Markdown 代码高亮 | 否 |
| `test-stream-reveal.cjs` | 流式文字渐显 | 否 |
| `test-markdown-performance.cjs` | 增量解析与全文一致性（含逐字符到达的图片行）、稳定块复用、离屏高度占位、渐显收尾 | 是 |
| `test-speech-orb.cjs` | 语音输入 UI 生命周期 | 是 |
| `test-voice-composer.cjs` | 语音输入区交互 | 是 |
| `test-drawing-board.cjs` | 画板初始化/导出/像素释放/附件保存 | 是 |
| `test-skill-completion.cjs` | Skill 补全与输入框回调 | 是 |
| `test-appearance.cjs` | 外观偏好、保存回滚、启动应用顺序 | — |
| `test-settings-performance.cjs` | 设置响应与持久化 | 是 |
| `test-settings-navigation.cjs` | 设置子页草稿、保存失败、凭据保留与返回 | 是 |
| `test-history-drawer.cjs` | 侧栏关闭动画、拖动与中断恢复 | 是 |
| `test-harness-features.cjs` | 搜索、交付、引用与运行时可靠性 | 否 |
| `test-preview-publication.cjs` | 预览发布集成 | 否 |
| `test-preview-lifecycle.cjs` | 预览资源与惰性生命周期 | 是 |
| `test-turn-workflow.cjs` | 流式时间线投影与保留的过程行 | 是 |
| `test-resources.cjs` | 资源管理集成 | 否 |
| `test-tool-schemas.cjs` | 用 SDK 的 JSON Schema 校验器检查工具参数、编辑必填字段与三种协议请求结构 | 否 |
| `test-tool-discovery.cjs` | BM25 排序与中英分词、递归参数检索、默认工具、按需 schema、权限撤销、串行执行 | 否 |
| `test-context-usage.cjs` | 上下文预算与用量 | 否 |
| `test-memory.cjs` | 记忆候选、来源与保存失败回滚 | 否 |
| `test-code-sandbox.cjs` | 沙箱执行、限额与恢复 | 否 |
| `test-orchestration.cjs` | 编排子调用、串行边界与回执 | 否 |
| `test-tool-details.cjs` | 分类回执、失败状态与无损分页 | 否 |
| `test-window-viewport.cjs` | 窗口与视口尺寸 | 是 |
| `test-answer-speech-native.cjs` | 回答朗读分段、取消、后台释放 | 是 |
| `test-team-toggle.cjs` | 团队开关与继承 | 否 |
| `test-custom-tools.cjs` | 完整版/自定义选择、12 项能力覆盖、旧配置迁移、目录与执行限制 | 否 |
| `test-custom-tools-renderer.cjs` | 能力行回调、联动开关、忙碌/归档时禁用 | 是 |
| `test-help-demo.cjs` | 帮助演示动画生命周期 | 是 |
| `test-hosted-privacy.cjs` | 系统签署版本、拒绝/重签、事件重新查询和 EntryAbility 同意前业务隔离 | 否 |
| `test-legal-documents.cjs` | 本地用户协议的实际编译读取路径、完整正文、错误展示与不再携带隐私正文 | 是 |
| `test-onboarding.cjs` | 首次使用判断、持久化、旧草稿保护、六幕引导的账号同意/登录/稍后登录、唤醒与暂停恢复 | 是 |

## 需要单独运行的验证

Hypium `ProjectFolders` 覆盖共享文件夹名称、数量、URI 去重、加载校验与模型上下文路径。`test-productivity-native.cjs` 还覆盖共享目录列表、嵌套创建、路径穿越与符号链接拒绝、不依赖重命名的直接写入、备份失败时禁止写入、部分写入后的备份保留与恢复，以及跨项目别名的版本竞争；系统选择器、持久化授权与设备重启后的激活需在 API 26 真机验证。

以下脚本不在 `test.ps1` 中，按改动范围单独执行：

| 脚本 | 场景 |
| --- | --- |
| `test-productivity-native.cjs` | 原生文件迁移、云备份、MCP 传输与确认流程；也可用 `DEVECO_STUDIO_HOME` 指定 SDK |
| `test-release-models.cjs` | Release 混淆产物的 Ability 初始化、画板全局上下文与模型兼容性 |
| `test-send-motion.cjs` | 发送动效的编译后生命周期与坐标换算 |
| `test-thinking-motion.cjs` | 思考状态循环、交叉渐变与离屏暂停 |
| `test-project-tree.cjs` | 侧栏项目分组、普通聊天、空项目、同名项目、置顶与归档 |
| `test-thread-list-renderer.cjs` | 会话改名/删除/归档/置顶的排序与菜单、项目分组刷新 |
| `test-message-actions-renderer.cjs` | 改写、重新生成、分支按钮的忙碌/保存失败禁用，以及仅回答展示的 AI 标记 |
| `test-team-renderer.cjs` | 团队、工具详情与编排子调用更新回调 |
| `test-chat-disclosures.cjs` | 流式更新、过程重开、历史加载时的展开状态 |
| `test-launch-actions-renderer.cjs` | 快捷入口保存草稿、创建独立会话、忙碌拒绝 |
| `test-interactive-ui.cjs` / `test-interactive-ui-renderer.cjs` | 交互预览渲染与生命周期 |
| `test-usage-performance.cjs` | 10 万条请求的统计、分页、取消与事件循环响应 |
| `test-i18n-native.cjs` | 语言偏好与持久化 |

## 单元测试覆盖什么

`entry/src/test/` 下的 Hypium 测试不依赖真机和模型密钥，覆盖：流式分帧与工具参数组装、多轮执行、取消、步数上限、执行前落盘失败、工具错误恢复、历史协议还原、工作区路径边界、Provider 注册、配置快照、事件顺序、运行收尾、指令顺序、压缩与历史回放、会话隔离。

新增工具或 Provider 时，连同对应单测一起提交；测试文件与被测代码同模块，命名 `*.test.ets`。

## 手动检查

编译产物测试替代不了设备验证。至少检查：

1. 冷启动进入会话、发送与停止、长回答滚动。
2. 工具审批弹层、拒绝后模型如何继续。
3. 文件修改后的差异审阅与恢复。
4. 交互预览卡片的渲染、截图与重新打开会话后的恢复。
5. 明暗主题切换、字号切换、英文界面换行。
6. 覆盖升级后会话、草稿、工作区与凭据仍在。

## 历史验证记录

2026-10-02 阶段：154 项 Hypium、16 项原生适配测试通过，81 个 ArkTS 源文件检查无错误；Mate 70 Pro+ 真机验证表单提交续跑、计划更新、原生图表、文件创建/唯一替换/搜索/按行读取、差异预览与恢复。OAuth、图片接口和模型发现使用模拟服务验证协议、取消/确认及凭据边界，尚未完成实际 OAuth 服务与图片模型的端到端联调。

同日记忆修正后：Hypium 增至 158 项全部通过，83 个 ArkTS 文件检查无错误，新增覆盖候选不落盘、空/无效结果不回退原文、取消、来源与范围、去重及保存失败回滚。

2026-10-02 自动测试：88 个 ArkTS 源文件检查无错误，186 项 Hypium 与 16 项原生适配测试通过，覆盖运行中追加、第二批招募、权限与会话隔离、持久化交接、等待与取消、产物变化检测、同轮整合及重启恢复。

以上数字属于当时版本，不代表当前构建通过；当前验证以 `scripts/test.ps1` 的实际输出为准。
