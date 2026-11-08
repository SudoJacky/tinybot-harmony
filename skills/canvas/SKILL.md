---
name: canvas
description: 创建或管理 Tinybot 生活看板，以及小组件的摆放、移动、尺寸和布局核对；看板采用响应式 12 列网格，不支持层叠无限画布。小组件内容修改使用 widget。
---

# 看板布局

Canvas here means Tinybot's Life Panel boards. Use `list_life_boards`, `get_life_board` and `manage_life_board`. These tools manage references/placement; they do not define HTML or copy card data.

1. Resolve the intended board from the user request or current board context. Read its saved layout before editing. If the target is genuinely ambiguous, ask which board; a clear current board does not require reconfirmation.
2. For placement or resizing, read [layout geometry](references/layout.md). Use actual `viewportWidth` from board context in `get_life_board`; do not assume tablet columns on a phone. Decide rendered width/height from content and pass them to widget validation/publication.
3. Use `manage_life_board` action `place` with existing `boardId`, board owner `workspaceId`, card `panelWorkspaceId/panelId`, and `layout:{x,y,w,h}` to mount or move one card. This retains the other references and pushes collisions down. Layouts then compact upward, preserving horizontal positions, sizes and vertical order; requested `y` may settle higher to close gaps. Use `save` with `items` only when intentionally replacing the complete layout; omit `items` to preserve it.
4. Reread `get_life_board` after editing and compare `mountId`, card identity and rectangles. A clickable receipt navigates; it does not prove the visual result. Report saved geometry separately from screenshot review.

`save` without `boardId` creates a named board. `archive`/`restore` manage boards without deleting cards. Removing a card reference does not delete its definition/data. One card may be mounted in several boards, sharing acquired data and user edits; each placement retains its own presentation state. Read the `widget` runtime reference only when authoring code that saves presentation state.

Board operations do not automatically show a board in chat. To show it, optionally copy the returned `reference` verbatim on its own line outside code fences in the final answer. Without a reference, no board is appended. Use `get_life_board` to obtain a reference for an existing board. When both a card and its board are referenced, the board omits that separately shown card to avoid repeating it.
