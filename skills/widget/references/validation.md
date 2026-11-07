# Validate candidates and report evidence

`validate_life_panel` checks a candidate without publishing or modifying live data. `publish_life_panel` repeats the same checks before saving. Pass candidate `path`, optional `htmlPath`, and original card identity/revision for an update.

Choose `placementWidth` and `placementHeight` from the intended board size and pass both. Only that viewport is checked. If omitted, the host checks half/full `viewportWidth` (default full width 360vp). Do not claim verification at other sizes. See the `canvas` Skill for grid-to-viewport conversion.

Checks include definition/schema validation, configured source acquisition (unless explicitly deferred), real hidden Web startup, horizontal overflow, visible control labels and declared interactions. For user-state tests the host uses detached copies. It reopens the HTML with state produced by the checks to verify persistence without replaying them. A source test does not permanently replace an existing card's data; the old snapshot is also checked when retained.

Declare at most 12 checks:

```json
[
  {"action":"input","selector":"#amount","value":"3"},
  {"action":"select","selector":"#unit","value":"minutes"},
  {"action":"click","selector":"#save"},
  {"action":"text","selector":"#result","value":"3"},
  {"action":"stored","path":"/amount","expected":3}
]
```

Selectors must match one visible element. `text` checks a substring; text/storage assertions wait up to two seconds for asynchronous work. Establish a known test value rather than assume a user's counter starts at zero. Display-only cards may declare `[]`; report that no interaction checks ran. Source refresh is probed separately and cannot be triggered from hidden interaction checks. Startup cannot write storage.

Fix reported stage/path/check diagnostics before publication. A failed source check blocks publishing. `checkSource:false` is only for explicitly pending connection/setup, with that limitation disclosed; it must not turn a tested failure into a success claim. After supplying a missing connection, run the relevant validation again.

Read `evidence`, `sourceStatus`, `checks`, `widths` and `warnings` from receipts. Schema success is not successful acquisition; successful acquisition is not placement verification. `screenshot:not_provided` / `visualReview:not_performed` mean no visual review occurred. The host does not prove all interactions or compatibility with every existing placement's local state.
