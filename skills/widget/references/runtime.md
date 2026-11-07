# HTML runtime and state ownership

Write self-contained HTML/CSS/JavaScript. The isolated iframe has DOM/Canvas and visibility-aware `tinybot.animate`; it has no arbitrary network, filesystem, credentials, imports, external fonts/libraries or localStorage. Inline data/blob assets are supported. Do not use `tinybot.save` on cards.

Render the current context, then subscribe:

```js
function render(context) {
  document.querySelector('#value').textContent = String(context.data.total ?? '—');
  document.querySelector('#refresh').disabled = !context.canRefresh || context.status === 'running';
}
render(tinybot.panel.context);
const unsubscribe = tinybot.panel.onUpdate(render);
document.querySelector('#refresh').onclick = async () => {
  try { await tinybot.panel.refresh(); }
  catch (error) { document.querySelector('#error').textContent = error.message; }
};
```

Context includes `data`, `inputs`, `title`, `status` (`ready`, `running`, `failed`), `canRefresh`, `locale`, `theme` and theme `tokens`. Updates arrive without reloading HTML. Use the context locale for user-facing formatting. `refresh({symbol:"B"})` passes declared/validated inputs to the same source; it does not add a new action. Query only on an explicit user action, never on startup, a timer or `onUpdate`. Hidden validation cannot run live refresh tasks. `refresh` is rejected without a source or when the view is not an interactive foreground card.

There are three distinct kinds of state:

| State | Owner and API |
| --- | --- |
| Acquired data | Native source task → `tinybot.panel.context.data` |
| Shared user edits | `tinybot.storage.load()/save(value,revision)` across placements |
| Placement presentation | `tinybot.panel.viewState.load()/save(value,revision)` for one `mountId` |

Save user edits only on user interaction, after loading the current snapshot:

```js
let saved = await tinybot.storage.load();
button.onclick = async () => {
  try {
    saved = await tinybot.storage.save({count: (saved.value?.count || 0) + 1}, saved.revision);
    output.textContent = String(saved.value.count);
  } catch (error) {
    saved = await tinybot.storage.load();
    status.textContent = error.message;
  }
};
```

Both storage APIs return `{value,revision}` and reject stale writes. Reload and show conflicts; never overwrite silently. Do not write storage while initializing. Shared edits survive source refresh, resizing and reopening; unsaved DOM state does not.

`tinybot.panel.viewState.available` is true on a board, its expanded card, and detached validation hosts. Use it for local selected tabs, sort/filter and presentation choices. Outside those surfaces, use in-memory defaults. Do not migrate existing shared user data into local view state automatically. Removing and re-adding a placement resets presentation state, not shared card data.

HTML is the surface itself, without a native decorative header/footer. In the all-cards list the height follows content; on a board the grid supplies a fixed viewport with internal scrolling. Keep the root content-driven and avoid `100vh`, artificial spacers and minimum heights for compact content. The host's top-left/bottom-right long-press move/resize corners are normally 48vp and shrink on small cards; keep important controls clear of them.
