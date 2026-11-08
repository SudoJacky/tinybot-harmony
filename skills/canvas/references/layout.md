# Placement geometry

The board uses 12 responsive columns, 32vp rows and 12vp gaps. Positions/sizes are integer grid cells: `x,y >= 0`, `w=2..12`, `h=2..33`, `x+w <= 12`. Saved explicit item layouts cannot overlap; rows may extend below the screen. Layouts automatically compact upward on read and save, retaining horizontal positions, sizes and vertical order. Requested `y` may settle higher; read the returned layout instead of relying on empty rows. This is not a stackable infinite canvas; there is no layer/z-index tool.

For actual board content width `W` in vp:

```text
columnStep = (W + 12) / 12
renderedWidth = w * columnStep - 12
renderedHeight = h * 44 - 12
renderedX = x * columnStep
renderedY = y * 44
```

Choose desired rendered dimensions from the content, then `w=ceil((desiredWidth+12)/columnStep)` and `h=ceil((desiredHeight+12)/44)`, clamped to allowed spans. Recompute the actual dimensions before authoring and pass `placementWidth`/`placementHeight` to `validate_life_panel` and `publish_life_panel`. `get_life_board` reports computed rectangles when supplied with `viewportWidth`; omit unknown width rather than invent exact phone dimensions.

Examples at board width 344vp: `5×8 = 136.3×340vp`, `6×4 = 166×164vp`, `12×8 = 344×340vp`. At 1092vp, columns are 80vp wide and `5×8 = 448×340vp`. The same span has very different usable width on a phone and tablet.

Starting points, not hard limits: a metric may need about 160vp, a form/list 240vp, a chart 300vp. Use full width if needed; choose height from content. The automatic pin fallback is the first free 5×8 space, not a prescribed shape. Definition `size:S/M/L` is legacy compatibility and does not resize a board placement.

Use `place` to change one reference and preserve other cards. For deliberate complete rearrangement use `save` with all intended references `{workspaceId,panelId,x,y,w,h}`. Removing/re-adding a reference resets that placement's presentation state; moving/resizing an existing reference preserves it. The native UI also lets the user move/resize by long-pressing the top-left/bottom-right corners.
