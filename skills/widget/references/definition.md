# Card definitions

HTML cards use v2. A minimal candidate:

```json
{
  "version": 2,
  "title": "Counter",
  "size": "M",
  "nodes": [],
  "data": {},
  "dataSchema": {"type": "object"},
  "checks": []
}
```

Supply `htmlPath` to `validate_life_panel` / `publish_life_panel`, or embed `view:{version:1,html,css,js,library:"none",height:320,autoHeight:true}`. `size` is a legacy field, not the board's actual dimensions. Board placements use `x/y/w/h`; read the `canvas` Skill when placement is needed.

`data` is an initial, already transformed JSON object/array. `source` describes acquisition; HTML only renders the resulting snapshot. Optional `inputs` declare allowed parameters for the same source:

```json
{"symbol":{"type":"string","default":"A","options":["A","B"]}}
```

The supported input types are `string`, `number` and `boolean`; defaults and optional options must match. For API/json-url sources, `source.query:{ticker:"symbol"}` maps fixed query parameter names to declared input names. Inputs cannot select arbitrary URLs, credentials or other cards.

HTML authoring requires `dataSchema` and `checks`; `checks:[]` is valid for display-only cards. Schemas support `type` (`object`, `array`, `string`, `number`, `integer`, `boolean`, `null`), `properties`, `required`, `additionalProperties`, `items`, `enum`, `minimum`, `maximum`; maximum nesting depth is 8. Example:

```json
{"type":"object","properties":{"total":{"type":"number"}},"required":["total"]}
```

The host checks source output against the schema on each refresh. Keep stable IDs in list data. Use `get_life_panel` to inspect definitions/data/tasks instead of editing app-owned manifests directly. For `workspace-json`, retain the source owner's explicit `source.workspaceId`, especially when modifying from another conversation.

Publication updates require `expectedRevision` equal to current `configRevision`; a conflict requires rereading the card before editing. Default updates retain live source data and shared user state. `replaceData:true` intentionally adopts the tested source/initial snapshot; it is not required for UI-only changes. There is no published-version restore tool.
