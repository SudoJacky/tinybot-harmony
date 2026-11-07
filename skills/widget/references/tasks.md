# Card refresh tasks

A card's `source`, `inputs`, `dataSchema` and optional `refreshMinutes` connect acquisition to its display. There is no separate Automation/Binding object or general submit-event router. HTML can invoke the same read-only task via `tinybot.panel.refresh(inputs?)`; it cannot submit arbitrary work or change endpoints.

Omit `refreshMinutes` for manual-only refresh. Values 1–1440 enable expiry-based refresh while the app is foreground. Overdue tasks run on return; do not promise scheduled execution while the app is closed. Native API/mail/balance queries do not use an LLM. Failed refresh retains the last successful data and exposes the error.

`manage_life_panel_task({workspaceId,panelId,action:"pause"|"resume"|"refresh",inputs?})` controls an existing card. Pausing stops queued/running automatic updates; manual refresh remains available. Read `get_life_panel({workspaceId,panelId,section:"task"})` for recent runs/errors (last ten). Diagnose source/validation failures from evidence instead of discarding the card or fabricating fresh data. The original chat need not exist.

## Agent acquisition

Configure `source:{type:"agent",prompt:"precise data-acquisition task"}` when source data needs bounded model work. Specify sources, desired output matching `dataSchema`, declared inputs, stable IDs and how to identify missing data. These runs consume model quota. Native limits are 8 steps and two minutes, using current model settings.

The independent Agent can read local workspace files, public webpages, configured non-browser search, and enabled mailbox data. It cannot publish cards, edit files, use the interactive browser, call MCP, request approvals or mutate other cards. It returns one JSON success/data or error envelope, not prose or invented observations. Keep acquisition separate from presentation: updating data does not regenerate HTML on every refresh.
