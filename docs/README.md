# 文档索引

[返回项目首页](../README.md)

根 README 保留项目介绍、快速开始和主要边界。功能操作、协议细节、架构约定和开发验证在这里按主题维护；后续行为变更更新对应专题，首页只在功能概览或开始步骤变化时同步。

## 使用与配置

| 文档 | 内容 |
| --- | --- |
| [使用指南](user-guide.md) | 聊天、附件、引用、记忆、队列、设置和用量 |
| [项目与共享工作区](projects-and-workspaces.md) | 项目归属、目录生命周期、分支、文件审阅与旧数据 |
| [模型服务与上下文](models-and-context.md) | 服务配置、模型预设、预算、固定限制及历史参数对照 |
| [团队协作](teams.md) | 招募、任务、交接、停止、恢复和用量 |
| [网页、搜索与 Skills](web-and-skills.md) | 网页读取、搜索配置、Skill 导入与调用 |
| [云备份](cloud-backup.md) | 华为云空间备份、恢复和验证边界 |
| [语音输入](speech-input.md) | 语音听写操作与系统接入 |
| [关于与帮助](about-and-help.md) | 首次使用、帮助、版本与市场评价 |

## 架构与实现

| 文档 | 内容 |
| --- | --- |
| [架构与运行管理](architecture.md) | SessionService、AgentRuntime、Provider、持久化及代码入口 |
| [工具执行与权限](tools-and-permissions.md) | 文件协议、修改校验、回执、错误、MCP 和权限边界 |
| [系统提示词](system-prompt.md) | 固定指令、用户偏好、Skills 与团队上下文 |
| [代码沙箱与工具编排](code-sandbox.md) | execute_code、orchestrate、预算与隔离 |
| [交互回答](interactive-ui.md) | 原生交互协议、Web 场景及状态恢复 |
| [推理强度](reasoning-effort.md) | 模型推理设置与输入框交互 |
| [滑动操作行](swipe-rows.md) | 手势与行操作 |
| [分段选择动效](segmented-motion.md) | 选择器动效 |
| [LiquidToggle](liquid-toggle.md) | 原生开关交互 |

## 开发与交付

- [开发与验证](development.md)：环境、构建、签名、测试入口及历史验证记录。
- [词条维护](../locales/README.md)：双语 JSON 与生成检查。
- [交付包准备](distribution/START-HERE.txt)、[更新说明](distribution/RELEASE-NOTES.txt)、[云测试步骤](distribution/CLOUD-TEST.txt)。
- 发布准备材料：[发布缺口](distribution/RELEASE-GAPS.txt)、[商店介绍](distribution/STORE-LISTING.txt)、[隐私草案](distribution/PRIVACY-DRAFT.txt)。
- [Tinybot MIT 许可文本](licenses/tinybot-MIT.txt)。

`docs/local/` 用于本机资料和验证证据，不发布到 GitHub。历史验证记录保留日期与当时范围，不作为当前构建通过的证明。
