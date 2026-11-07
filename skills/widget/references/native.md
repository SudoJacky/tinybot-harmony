# Native v1 cards

For native v1 cards: no HTML/CSS/UI scripts or secrets; use v2 for HTML cards. Synchronous JavaScript is supported only in source.transform. Bindings are {value:literal} or {path:"/data/..."}; JSON Pointer escaping applies. Source snapshot and app-owned checklist state are separate. Parents precede children. Max 32 nodes, depth 4. Keep S very concise; overflow can be opened in detail.

## Components

- `Row`: Horizontal children, parent references this node ID. Host controls spacing.
- `Column`: Vertical children.
- `Text`: text binding (string/number/boolean), optional tone.
- `Metric`: value binding (number), optional text label, decimals 0–4, suffix <=12 chars, private boolean (tap to reveal; concealed on reopen), tone.
- `Progress`: value and max numeric bindings, 0<=value<=max, max>0; optional text, tone.
- `ItemList`: items binding to [{id,label,value?:string}], limit 1–20 (default 5).
- `Checklist`: items binding to [{id,label,done?:boolean}], limit 1–20. Native completion count/progress and persistent toggles. Stable item/node IDs preserve user state across refreshes.
- `Sparkline`: value binding to 2–120 finite numbers, optional text and tone. Native line chart.
- `ActionButton`: text binding, action:"refresh"; requires source. No arbitrary actions.

Tones: accent, neutral, positive, warning, negative.

```json
{
  "version": 1,
  "title": "Daily plan",
  "size": "L",
  "data": {
    "tasks": [
      {
        "id": "walk",
        "label": "Go for a walk",
        "done": false
      }
    ]
  },
  "nodes": [
    {
      "id": "tasks",
      "kind": "Checklist",
      "items": {
        "path": "/data/tasks"
      },
      "tone": "positive",
      "limit": 8
    }
  ]
}
```

Board placement still uses the 12-column geometry from the canvas Skill, not the legacy size presets.
