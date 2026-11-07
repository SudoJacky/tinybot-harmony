---
name: widget
description: 创建、修改或排查 Tinybot 生活看板小组件，包括 HTML、数据源、输入与持久状态、验证、发布及刷新任务；调整看板位置和尺寸时使用 canvas，编写 HTML/CSS 前读取 widget-design。
---

# 看板小组件

Life Panel is a persistent card, separate from temporary previews and Mini apps. Use the existing `publish_life_panel` tools; Skills do not add tools or permissions.

## Create or edit

1. Identify the intended card and board from the request and board context. For updates, page `list_life_panels` if needed, then read `get_life_panel` for its definition, data and current `configRevision`. Keep its owner `workspaceId` and `panelId`; updating is not creating a replacement.
2. Before HTML/CSS, read `read_skill({name:"widget-design"})`. Read `references/definition.md` and `references/runtime.md` for the actual host contract. For a simple starting point, read `assets/counter.html` and `assets/counter.panel.json`. Use native v1 only when its fixed component vocabulary fits; then read `references/native.md` instead of the HTML references.
3. Write candidate `.panel.json` and optional `.html` files in the current conversation workspace, outside managed `life-panels/`, `life-boards/` and `mini-apps/` directories. Generated HTML is the card surface, with its own title/content. Preserve an existing custom design unless a restyle was requested.
4. Read `references/validation.md`, add a data schema and meaningful interaction checks, then call `validate_life_panel`. Repair returned diagnostics and repeat. `publish_life_panel` repeats validation. Use a stable `requestId` when creating, or the original `panelId`, owner `workspaceId` and `expectedRevision` when updating. Keep `replaceData` omitted unless replacing live source data is intended; ordinary UI updates retain live data and user edits.
5. When placing or resizing on a board, read `read_skill({name:"canvas"})`. Use the actual rendered width/height for validation. Publish, place, then reread the board. A successful publication remains valid if pinning fails: recover the returned card ID rather than create a duplicate.

Choose only the additional references needed:

- Read [data sources](references/sources.md) for local JSON, public/API queries or mail; [transforms](references/transforms.md) for response calculations.
- Read [refresh tasks](references/tasks.md) for Agent-backed acquisition, periodic updates, pause/resume or run failures. Tinybot has no separate Automation/Binding objects: `source`, `inputs`, `dataSchema` and `refreshMinutes` on the card define that connection.
- Read [provider balances](references/provider-balance.md) for balance/quota widgets. Use `get_life_panel_catalog({section:"balance"})` for current allowed accounts and a matching definition; read `assets/balance.html` only when using that reference design.

## Delivery evidence

Distinguish saved layout, runtime validation, successful data acquisition and visual review. Tools return JSON, not automatic screenshots. Do not claim screenshot review without an actual image. Missing credentials can be explicitly deferred with `checkSource:false`; report setup as pending, not tested. A tested failure must be repaired rather than hidden by deferring the check.
