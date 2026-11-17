// Run in the rendered BalancePanelTemplate frame with motion enabled and a native port
// that acknowledges panelRefresh without changing the balance.
async () => {
  const amount = document.getElementById('amount');
  const refresh = document.getElementById('refresh');
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  check(!matchMedia('(prefers-reduced-motion:reduce)').matches, 'Enable motion for this regression test');
  check(!document.getElementById('privacy'), 'Balance cards have no hide control');
  document.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
  const before = amount.getAttribute('aria-label');
  check(before === '$123.45', 'Start with the rendered fixture balance');
  for (let i = 0; i < 2; i++) {
    const pending = refresh.onclick();
    check(amount.dataset.loading === 'true' && !amount.textContent, 'Loading must replace the digits');
    await pending;
    check(!document.getElementById('status').textContent, 'Refresh must succeed through the host');
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
}
