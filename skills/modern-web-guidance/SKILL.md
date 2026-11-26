---
name: modern-web-guidance
description: 查阅 Modern Web Guidance 的前端实践与浏览器兼容性。适用于编写或修改 HTML、CSS 和浏览器端 JavaScript，包括界面布局、表单、动画、无障碍和性能。
---

# Modern Web Guidance

在实现前端需求前，先用 Modern Web Guidance 查找相关的 Web 平台做法。框架中的标准 HTML、CSS 和浏览器 API 同样适用。后端、构建工具、Git 和纯文案修改无需查阅。

1. 把需求拆成具体的 Web 能力，例如 `light dismiss dialog` 或 `responsive data table`。用 `read_skill` 读取本技能的 [指南索引](references/index.md)，按主题、指南名称和浏览器 API 选出最相关的条目。
2. 把索引的 `分类/指南名` 拼到 `https://raw.githubusercontent.com/GoogleChrome/modern-web-guidance/main/skills/modern-web-guidance/guides/` 后并加 `.md`，用 `read_web` 获取正文。例如 `ui-behaviors/animate-to-from-top-layer` 对应 `https://raw.githubusercontent.com/GoogleChrome/modern-web-guidance/main/skills/modern-web-guidance/guides/ui-behaviors/animate-to-from-top-layer.md`。有 `nextOffset` 时继续读取。复杂任务可同时查阅相应的 CSS、HTML、无障碍或性能通用指南。
3. 以用户指定的浏览器或 WebView 为目标，核对指南的兼容性、交互和无障碍要求。对目标环境尚未普及的特性，根据指南做特性检测、渐进增强或采用适用的兼容方案。实现后回查相关做法，并在交付时链接实际采用的指南。

指南正文需要联网。如果网页读取未启用、来源不可访问或索引无匹配条目，说明哪些做法未经上游指南核实。Tinybot 通过 `read_skill` 和 `read_web` 完成此流程。
