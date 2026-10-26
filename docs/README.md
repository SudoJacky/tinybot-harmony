# Tinybot 文档

这是 Tinybot 的文档源码目录，用 VitePress 构建为文档站：<https://sudojacky.github.io/tinybot-harmony/>

## 结构

| 目录 | 内容 |
| --- | --- |
| `index.md` | 站点首页 |
| `getting-started/` | 安装与第一次对话 |
| `guide/` | 使用指南：对话、文件、项目、模型、团队、网页与 Skills、语音、备份、设置、隐私、常见问题 |
| `internals/` | 架构与子系统：总览、代码地图、会话、轮次、模型服务、提示词、工具、权限、工作区、预览、诊断 |
| `reference/` | 工具参考、回执与错误、设置项、磁盘布局、词条 |
| `dev/` | 开发手册：环境与构建、测试、新增工具、新增模型服务、词条、文档站、发布 |
| `ui/` | 交互与动效细节 |
| `.vitepress/` | 站点配置与主题 |
| `local/`、`distribution/` | 本机资料与交付材料，不参与构建 |

## 本地预览

```powershell
cd docs
npm install
npm run dev      # http://localhost:5173/tinybot-harmony/
npm run build    # 产物在 docs/.vitepress/dist
```

写作约定、链接规则与发布方式见[文档站维护](/dev/docs)。

## 约定

- 站内链接使用绝对站点路径（`/internals/tools`），不写 `.md` 后缀。
- 行为描述以 `entry/src/main/ets` 源码和 `scripts/` 验证脚本为准；参考页给出字段与默认值。
- 页面末尾保留“代码入口”表，方便从文档跳到实现。