---
name: lieflat-charts
description: 采用 Lieflat Charts 的模板制作交互式 HTML 图表、数据故事和完整报告。适用于需要编辑排版、可读的数据标注、一致配色或 HTML 图表演示的任务。默认做图表，明确要求完整报告或演示时才切换模式。
---

# Lieflat Charts

上游：[lieflat-charts @ 75c6978](https://github.com/larashero3-dotcom/lieflat-charts/tree/75c697872e622a34471bec875874c038b37da89f)。许可证为 PolyForm Noncommercial 1.0.0，商业使用需要另行授权。

使用 `read_skill` 读取 `upstream/SKILL.md` 和所需目录。参考文件较长时按返回的 `nextOffset` 续读，`offset` 是从 0 开始的字符偏移。目录中的模板路径可直接用作 `read_skill` 的 `path`。

- 图表从 `catalog.md` 选型，再读对应 gallery 的实际模板，优先考虑 Lupi Editorial 和 Basics。按数据和阅读场景选择一套颜色系统，地图仅在用户明确需要时启用。
- 完整报告读 `report-catalog.md` 并按语言读取对应的 `templates/reports/` 文件。
- HTML 图表演示读 `presentation-catalog.md` 和 `references/presentation.md`。用户明确要求 `.pptx` 时，使用可编辑 PowerPoint 生成工具，并沿用本技能的设计原则。
- 将真实数据和来源填入所选结构，将所用的颜色、样式和脚本嵌入交付文件。优先在 Tinybot 中预览原生 SVG 模板。Chart.js、ECharts、在线字体和地图服务需要网络或自包含资源，Tinybot 的预览沙箱不访问 CDN。需要在线依赖时，可将生成的 HTML 作为文件交付，并注明打开所需条件。
