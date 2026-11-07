---
name: widget-design
description: 为 Tinybot 生活看板小组件编写或调整 HTML/CSS 时使用，提供主题、字体、间距、触控与状态设计规范；摆放和尺寸计算读取 canvas，运行接口与数据读取 widget。
---

# 小组件视觉设计

Read [the design system](references/design-system.md) before writing card HTML/CSS. It describes the actual mobile host, not a desktop browser framework. Preserve a working custom design unless the user asks for a restyle.

Lead with useful content and choose a target size that fits the task. The HTML is the card surface: use one root, without a second ornamental header/footer or nested decorative cards. Use the host's semantic theme variables and optional `tb-*` classes. Keep text readable, controls labelled and touchable, and actions clear of the corner move/resize gestures.

When mounting/resizing on a board, read `read_skill({name:"canvas"})` for actual geometry. A 5×8 fallback is not a required aspect ratio; a phone's columns are narrower than a tablet's. Validate the selected dimensions, not an invented desktop width. Additional sizes are optional unless requested.

Keep loading/errors next to the affected content and retain last successful data on failure. Do not replace working behavior with decorative motion. Respect reduced motion, visibility and keyboard access. Runtime/layout validation is separate from reviewing a screenshot; only claim visual review after seeing an image.
