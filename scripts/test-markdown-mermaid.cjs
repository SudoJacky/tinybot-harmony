const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ channel: 'msedge' });
  try {
    const page = await browser.newPage({ viewport: { width: 600, height: 300 } });
    const requests = [];
    const errors = [];
    page.on('request', request => { if (/^https?:/.test(request.url())) requests.push(request.url()); });
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(path.resolve(__dirname, '../entry/src/main/resources/rawfile/mermaid/index.html')).href);
    let revision = 0;
    async function render(source, { dark = false, selectable = true, status = 'ok' } = {}) {
      const input = { revision: ++revision, source, dark, selectable, errorLabel: 'Diagram rendering failed' };
      await page.evaluate(input => window.renderMermaid(input), input);
      await page.waitForFunction(({ revision, status }) =>
        new RegExp('^mermaid:' + revision + ':[1-9]\\d*:' + status + '$').test(document.title), { revision, status });
    }

    await render('flowchart LR\n  A[Start] --> B[Finish]');
    assert.match(await page.locator('#diagram > svg').textContent(), /Start.*Finish/s);
    const wide = await page.locator('#diagram > svg').boundingBox();
    await page.setViewportSize({ width: 140, height: 300 });
    const narrow = await page.locator('#diagram > svg').boundingBox();
    assert.ok(narrow.width <= 140 && narrow.width < wide.width);
    assert.ok(narrow.height < wide.height);
    await page.waitForFunction(height => document.title === 'mermaid:1:' + height + ':ok', Math.ceil(narrow.height + 24));

    await render('sequenceDiagram\n  Alice->>Bob: Hello', { dark: true, selectable: false });
    assert.match(await page.locator('#diagram > svg').textContent(), /Hello/);
    assert.match(await page.locator('#diagram').getAttribute('class'), /dark unselectable/);

    const invalid = '<img src="https://example.invalid/leak" onerror="alert(1)">';
    await render(invalid, { status: 'error' });
    assert.equal(await page.locator('#diagram pre').textContent(), invalid);
    assert.equal(await page.locator('#diagram img, #diagram svg').count(), 0);

    await render('%%{init: {"securityLevel":"loose"}}%%\nflowchart LR\n  A --> B\n  click A "https://example.invalid/leak"');
    assert.equal(await page.locator('#diagram a[href], #diagram a[xlink\\:href]').count(), 0);
    assert.deepEqual(requests, []);
    assert.deepEqual(errors, []);
    console.log('PASS offline Mermaid diagrams, resize, dark mode, invalid source and locked security settings');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
