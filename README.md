# Tinybot for HarmonyOS

使用 ArkTS + ArkUI 编写的原生 HarmonyOS 个人 AI 助手。手机直接连接用户配置的模型服务，数据保存在应用沙箱中；不依赖 Tinybot 桌面进程。

最低与目标版本均为 **HarmonyOS API 26**。当前准备发布版本为 **1.0.0 / 1000000**，参阅[更新说明](docs/distribution/RELEASE-NOTES.txt)。

## 主要功能

- **原生聊天**：流式回答、图片与文档附件、手绘画板、语音输入、会话搜索与分支，支持中英文和系统明暗主题。
- **项目与文件**：同一项目中的多个会话共享工作区和项目说明，可浏览、编辑、审阅和导出文件；旧会话保持无项目归属。
- **Agent 与团队**：多步工具执行、运行中追加指令、任务排队，以及聊天内的团队协作。
- **工具与扩展**：完整版与自定义工具选择、网页读取与搜索、5 个内置 Skills 与自定义导入、远程 MCP、JavaScript 计算沙箱和工具编排。
- **交互回答**：在聊天中嵌入 JS、HTML、SVG 和 Three.js 预览，支持文件交付及图片生成。
- **个性化与数据**：长期记忆、提示词模板、用户偏好文档、模型用量统计、本地备份及华为云空间备份。

## 开始使用

1. 安装测试包或按下方步骤自行构建，交付说明见[安装与准备](docs/distribution/START-HERE.txt)。
2. 在设置中添加模型服务，填写地址、模型与所需密钥，并为会话选择模型。
3. 直接开始聊天；持续处理同一批文件时，可先在对话列表创建项目，再在项目内创建会话。

服务支持 Chat Completions、OpenAI Responses 和 Anthropic Messages。模型实际可用性取决于账号与服务端；Ollama 连接手机可访问的服务器，不在手机上运行模型。

具体入口、功能限制和数据行为见[使用指南](docs/user-guide.md)。

## 本地开发

准备 DevEco Studio API 26 SDK 和 DevEco CLI，在仓库根目录执行：

```powershell
# 首次克隆时创建本机配置；已有文件时不要覆盖
if (-not (Test-Path build-profile.json5)) { Copy-Item build-profile.template.json5 build-profile.json5 }
devecocli check arkts
devecocli build
.\scripts\test.ps1
```

环境变量、签名、真机运行、图标及词条维护见[开发与验证](docs/development.md)。

## 文档

完整目录见 [docs/README.md](docs/README.md)。

| 主题 | 入口 |
| --- | --- |
| 手机功能与设置 | [使用指南](docs/user-guide.md) |
| 项目、会话与文件归属 | [项目与共享工作区](docs/projects-and-workspaces.md) |
| 模块职责与运行生命周期 | [架构与运行管理](docs/architecture.md) |
| 工具协议、权限与恢复 | [工具执行与权限](docs/tools-and-permissions.md) |
| 模型配置、上下文与预算 | [模型服务与限制](docs/models-and-context.md) |
| 构建、调试与验证 | [开发与验证](docs/development.md) |

## 当前边界

文件工具只能访问当前会话绑定的工作区；项目内会话共享文件。工具结果会发送给配置的模型服务。当前没有 Shell、跨应用控制或任意外部目录访问能力；代码沙箱仅运行受限 JavaScript。

当前不支持跨项目移动、常驻后台 Agent、桌面协作或对话实时云同步。删除会话保留工作区文件，卸载应用或清除应用数据会清除本地数据。备份不导出模型及 MCP 凭据。
