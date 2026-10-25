# 文档站维护

本站是 VitePress 站点，源码在 `docs/`，与 GitHub 上可直接阅读的 Markdown 是同一份文件。

## 本地运行

```powershell
cd docs
npm install        # 首次
npm run dev        # 本地预览，默认 http://localhost:5173/tinybot-harmony/
npm run build      # 生成 docs/.vitepress/dist
npm run preview    # 预览构建产物
```

Node.js 20+ 即可；`node_modules` 与构建产物都已忽略。

## 目录与导航

```text
docs/
├─ index.md               首页（hero + 功能卡）
├─ .vitepress/
│  ├─ config.mts          导航、侧边栏、搜索、页脚
│  └─ theme/              主题入口与自定义 CSS
├─ getting-started/       安装与第一次对话
├─ guide/                 使用指南
├─ internals/             架构与子系统
├─ reference/             工具、回执、设置、磁盘布局、词条
├─ dev/                   开发手册（本页所在）
├─ ui/                    交互与动效
├─ public/                静态资源（logo 等）
├─ local/                 本机资料，不构建
└─ distribution/          交付材料，不构建
```

新增页面时同时改两处：写 Markdown，并在 `.vitepress/config.mts` 的 `sidebar` 中登记。`nav` 只放一级入口。

## 写作规范

- 一个页面只写一个 H1；标题层级连续，不跳级。
- 站内链接用绝对站点路径，例如 `[工具注册与执行](/internals/tools)`，不带 `.md` 后缀。跨页引用时优先链接到最具体的一节（`/internals/tools#执行流水线`）。
- 术语首次出现附英文；不写营销词，不用表情符号。
- 表格用于职责、参数、默认值、边界；结构图用 ```text 代码块，本站没有安装 Mermaid。
- 涉及行为的描述必须能对应到源码或测试；代码入口表放在页面末尾。
- 页面之间不要重复讲同一件事：用法放 `guide/`，机制放 `internals/`，可查的表放 `reference/`。

## 构建检查

```powershell
cd docs
npm run build
```

构建会报告死链；出现 `dead link` 时修正链接或补页面，不要用 `ignoreDeadLinks` 掩盖。产物在 `docs/.vitepress/dist`。

## 发布

`.github/workflows/docs.yml` 在推送到 `main` 且改动 `docs/` 时构建并部署到 GitHub Pages。仓库设置中需要把 Pages 的来源设为 **GitHub Actions**。站点地址为 `https://sudojacky.github.io/tinybot-harmony/`，对应 `config.mts` 的 `base`；仓库改名或迁移时必须同步修改。

同一次工作流还会独立构建并自动发布到 <https://sudotinybot.cn/docs/>。文档合入 `main` 后无需手动部署官网；仅应用代码变化不会触发文档构建。可在 Actions 的 **Docs** 工作流查看 `Publish sudotinybot.cn documentation` 结果或手动重新运行。

镜像构建设置 `DOCS_TARGET=sudotinybot`，使用 `/docs/` 基路径、官网 sitemap 和返回官网入口。默认构建仍面向 GitHub Pages。两个站点的文章来自同一次提交，不需维护两份 Markdown。

发布凭据保存在仓库的 `DOCS_DEPLOY_KEY` 和 `DOCS_DEPLOY_KNOWN_HOSTS` Actions Secrets。独立 SSH 密钥只允许调用服务器的文档发布程序，无 root、Shell、端口转发或后台数据权限。服务器校验归档后原子切换文档目录；构建或发布失败保留上一版。官网、公告、反馈服务无需重启。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 本地页面 404 | `base` 是 `/tinybot-harmony/`，直接访问 `http://localhost:5173/` 会 404，请带前缀 |
| 侧边栏没有新页面 | 忘记在 `config.mts` 的 `sidebar` 登记 |
| 搜索找不到中文 | 本地搜索按词切分，标题与正文同时命中才稳定；补全标题关键词 |
| 构建报 dead link | 链接写成了相对路径或指向未创建页面 |
