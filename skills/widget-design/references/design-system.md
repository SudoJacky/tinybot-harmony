# Tinybot mobile card design system

## surface

The HTML is the card itself. Use one root .tb-card; avoid a second decorative border/header/footer around it. Preserve an existing custom design unless asked to restyle. No external fonts, libraries or network in HTML. Keep root height content-driven; the board supplies its viewport and internal scrolling.

## tokens

Host CSS: --tinybot-text, --tinybot-text-secondary, --tinybot-surface, --tinybot-surface-muted, --tinybot-accent, --tinybot-on-accent, --tinybot-danger, --tinybot-border, --tinybot-font, --tinybot-space-1..6 (4/8/12/16/24/32px), --tinybot-radius (16px), --tinybot-control-radius (10px). Colors update with the app theme. Use semantic tokens, no separate light/dark palette. App accent is allowed for primary actions. Numbers use tabular-nums, not oversized decorative type.

## components

Opt-in preloaded classes: tb-card (single surface,16px padding), tb-stack (vertical,12px gap), tb-row (wrapping,8px gap), tb-title (18px), tb-meta (12px secondary), tb-number (32px tabular), tb-button (40px touch target), tb-primary (accent button), tb-field (label+control), tb-input (full-width input/select/textarea), tb-error (error/status). Combine tb-button tb-primary. Use semantic HTML, visible labels and aria-label for icon-only buttons. Do not rely on hover on phones. Keep controls away from the top-left/bottom-right long-press corners; do not reserve an entire desktop drag strip.

## composition

Lead with useful content: title/label, primary value or list, then actions. Base text 15px, secondary 12–14px, title 18–20px, metrics 28–40px. Prefer 4/8/12/16/24/32px spacing. Wrap action rows and allow long text to wrap. Avoid nested decorative cards, large empty areas, heavy shadows and ornamental gradients. Show status near the relevant control, disable duplicate submissions and retain last successful content on refresh errors.

For geometry read the `canvas` Skill. For shared edits and placement-local presentation state read `widget/references/runtime.md` through read_skill. No screenshot is automatically supplied by validation.
