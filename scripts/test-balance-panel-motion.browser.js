// Run as an async function in the rendered BalancePanelTemplate preview, with motion enabled.
// The refresh bridge is intercepted: no real provider request is made.
async () => {
  const amount = document.getElementById('amount');
  const refresh = document.getElementById('refresh');
  const original = tinybot.panel.refresh;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  check(!matchMedia('(prefers-reduced-motion:reduce)').matches, 'Enable motion for this regression test');
  check(!document.getElementById('privacy'), 'Balance cards have no hide control');
  document.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
  let release;
  let pending;
  try {
    for (let i = 0; i < 2; i++) {
      const before = amount.getAttribute('aria-label');
      tinybot.panel.refresh = () => new Promise(resolve => { release = resolve; });
      pending = refresh.onclick();
      check(amount.dataset.loading === 'true' && !amount.textContent, 'Loading must replace the digits');
      await wait(20);
      release();
      await pending;
      check(amount.getAttribute('aria-label') === before, 'An unchanged balance must still be restored');
      const digits = amount.querySelector('.amount-layer:not(.amount-out)');
      check(digits && digits.getAnimations({ subtree: true }).length > 0, 'Missing staggered digit entrance after loading');
      check(amount.querySelector('.loading-layer.amount-out'), 'Missing loading exit transition');
      // The next refresh interrupts this entrance rather than waiting for it to finish.
    }
    await Promise.all(amount.getAnimations({ subtree: true }).filter(animation =>
      animation.effect.getTiming().iterations !== Infinity).map(animation => animation.finished));
    await new Promise(requestAnimationFrame);
    check(!amount.querySelector('.amount-out') && !amount.querySelector('.amount-loading'), 'Transition layers must be removed');
    return { unchangedRefreshAnimated: true, interruptedRefreshAnimated: true, transitionCleanup: true };
  } finally {
    release?.();
    if (pending) await pending;
    tinybot.panel.refresh = original;
  }
}
