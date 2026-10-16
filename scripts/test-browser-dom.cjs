// Execute the shipped browser scripts in a real browser. Requires Playwright (NODE_PATH may point to a cached install).
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { chromium } = require('playwright');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/model/BrowserScripts.ets'), 'utf8');
const exported = {};
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
  { exports: exported, require: name => { throw Error('Unexpected runtime dependency ' + name); } });
const { browserSnapshotScript, browserActionScript } = exported;
(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 800, height: 900 } });
    await page.setContent(`<main><h1>Interactive page</h1>
      <label>Search<input name="search" value="existing"></label><textarea name="draft">Initial</textarea>
      <label>Password<input type="password" value="secret-password"></label><input name="otp" autocomplete="one-time-code" value="123456">
      <input type="file"><input type="text" name="shown" id="password-field" value="secret-password"><select name="filter"><option value="one">One</option><option value="two">Two</option></select>
      <button onclick="document.querySelector('output').textContent='Submitted';window.clicks=(window.clicks||0)+1">Submit</button><output></output>
      <button disabled>Disabled</button><button style="display:none">Hidden</button><iframe srcdoc="<button>Frame button</button>"></iframe>
      <div style="height:3000px">Tall page</div></main>`);
    const snapshot = JSON.parse(await page.evaluate(browserSnapshotScript('first')));
    assert.equal(snapshot.trust, 'untrusted'); assert.equal(snapshot.embeddedFrames, 1);
    assert.equal(snapshot.elements.some(item => item.label === 'Hidden'), false);
    assert.equal(JSON.stringify(snapshot).includes('secret-password'), false);
    assert.equal(JSON.stringify(snapshot).includes('123456'), false);
    assert.equal(snapshot.elements.filter(item => item.type === 'user-only').length, 4);
    const invoke = args => page.evaluate(browserActionScript({ snapshotId: 'first', ...args })).then(JSON.parse);
    const preview = args => page.evaluate(browserActionScript({ snapshotId: 'first', ...args }, true)).then(JSON.parse);
    const input = snapshot.elements.find(item => item.label === 'Search');
    assert.ok(input);
    const typePreview = await preview({ action: 'type', elementId: input.id, text: 'Must not be entered yet' });
    assert.equal(typePreview.ok, true); assert.ok(typePreview.target.x >= 0 && typePreview.target.x <= 1);
    assert.equal(await page.locator('input[name=search]').inputValue(), 'existing', 'Preview must not edit the input');
    const text = `quoted " value'); globalThis.unwanted = true; //`;
    assert.equal((await invoke({ action: 'type', elementId: input.id, text })).ok, true);
    assert.equal(await page.locator('input[name=search]').inputValue(), text);
    assert.equal(await page.evaluate('globalThis.unwanted'), undefined);
    assert.equal((await invoke({ action: 'type', elementId: input.id, text: 'line one\nline two' })).code, 'INVALID_INPUT_VALUE');
    assert.equal(await page.locator('input[name=search]').inputValue(), text, 'Rejected values must not overwrite the field');
    const draft = snapshot.elements.find(item => item.role === 'textarea');
    assert.equal((await invoke({ action: 'type', elementId: draft.id, text: 'line one\nline two' })).ok, true);
    assert.equal(await page.locator('textarea').inputValue(), 'line one\nline two');
    const select = snapshot.elements.find(item => item.role === 'select');
    assert.deepEqual(select.options, [{ value: 'one', label: 'One' }, { value: 'two', label: 'Two' }]);
    assert.equal((await invoke({ action: 'select', elementId: select.id, text: 'two' })).ok, true);
    assert.equal(await page.locator('select').inputValue(), 'two');
    assert.equal((await invoke({ action: 'select', elementId: select.id, text: 'absent' })).code, 'INVALID_OPTION');
    for (const element of snapshot.elements.filter(item => item.type === 'user-only')) {
      assert.equal((await invoke({ action: 'type', elementId: element.id, text: 'secret' })).code, 'USER_INPUT_REQUIRED');
    }
    const submit = snapshot.elements.find(item => item.label === 'Submit');
    const clickPreview = await preview({ action: 'click', elementId: submit.id });
    const rect = await page.locator('button').first().boundingBox();
    assert.ok(Math.abs(clickPreview.target.x - (rect.x + rect.width / 2) / 800) < 0.001);
    assert.ok(Math.abs(clickPreview.target.y - (rect.y + rect.height / 2) / 900) < 0.001);
    assert.equal(await page.evaluate('window.clicks'), undefined, 'Preview must not click or dispatch input events');
    assert.equal((await preview({ action: 'click', elementId: snapshot.elements.find(item => item.label === 'Disabled').id })).code, 'ELEMENT_DISABLED');
    assert.equal((await invoke({ action: 'click', elementId: submit.id })).ok, true);
    assert.equal(await page.locator('output').textContent(), 'Submitted');
    assert.equal(await page.evaluate('window.clicks'), 1);
    assert.equal((await invoke({ action: 'click', elementId: snapshot.elements.find(item => item.label === 'Disabled').id })).code, 'ELEMENT_DISABLED');
    await page.locator('button').first().evaluate(node => node.remove());
    assert.equal((await invoke({ action: 'click', elementId: submit.id })).code, 'STALE_BROWSER_ELEMENT');
    await page.evaluate(browserSnapshotScript('second'));
    assert.equal((await invoke({ action: 'type', elementId: input.id, text: 'Old snapshot' })).code, 'STALE_BROWSER_SNAPSHOT');
    assert.equal((await invoke({ action: 'scroll', deltaY: 500 })).ok, true);
    assert.ok(await page.evaluate('scrollY') > 0);
    await page.evaluate(() => scrollTo(0, 0));
    await page.evaluate(browserSnapshotScript('first'));
    await page.evaluate(() => scrollTo(0, 300));
    assert.equal((await invoke({ action: 'type', elementId: input.id, text: 'Stale edit' })).code, 'STALE_BROWSER_SNAPSHOT');
    assert.equal(await page.locator('input[name=search]').inputValue(), text, 'Viewing must invalidate old actions without editing the page');
    await page.evaluate(() => scrollTo(0, 0));
    let fresh = JSON.parse(await page.evaluate(browserSnapshotScript('first')));
    let current = fresh.elements.find(item => item.label === 'Search');
    await page.locator('input[name=search]').evaluate(node => node.setAttribute('aria-label', 'New lazy-loaded control'));
    assert.equal((await invoke({ action: 'type', elementId: current.id, text: 'Wrong control' })).code, 'STALE_BROWSER_ELEMENT');
    fresh = JSON.parse(await page.evaluate(browserSnapshotScript('first')));
    current = fresh.elements.find(item => item.label === 'New lazy-loaded control');
    assert.equal((await invoke({ action: 'type', elementId: current.id, text: 'Fresh edit' })).ok, true);
    await page.setViewportSize({ width: 600, height: 900 });
    assert.equal((await invoke({ action: 'type', elementId: current.id, text: 'Resized edit' })).code, 'STALE_BROWSER_SNAPSHOT');
    assert.equal(await page.locator('input[name=search]').inputValue(), 'Fresh edit');
    console.log('PASS viewing scroll/resize and lazy-loaded target changes reject stale actions; fresh observations remain actionable');
    console.log('PASS actual browser DOM: rendered text, labels, options, click/type/select/scroll, secret redaction, input restrictions and stale snapshots');
    await page.setViewportSize({ width: 800, height: 900 });
    await page.setContent('<button style="position:absolute;left:350px;top:100px;width:150px;height:60px" onclick="window.effects=(window.effects||0)+1">Target</button>');
    await page.evaluate(browserSnapshotScript('zoom'));
    const zoomAction = { action: 'click', snapshotId: 'zoom', elementId: 1 };
    const session = await page.context().newCDPSession(page);
    await session.send('Emulation.setPageScaleFactor', { pageScaleFactor: 2 });
    assert.equal(JSON.parse(await page.evaluate(browserActionScript(zoomAction, true))).code, 'STALE_BROWSER_SNAPSHOT');
    await page.evaluate(browserSnapshotScript('zoom'));
    const zoomPreview = JSON.parse(await page.evaluate(browserActionScript(zoomAction, true)));
    assert.equal(zoomPreview.ok, true);
    assert.ok(Math.abs(zoomPreview.target.x - 0.9375) < 0.002, 'Pinch zoom uses the visible portion of a partially clipped target');
    assert.ok(Math.abs(zoomPreview.target.y - 130 / 450) < 0.002);
    await page.locator('button').evaluate(node => node.setAttribute('aria-label', 'Changed during the cue'));
    assert.equal(JSON.parse(await page.evaluate(browserActionScript(zoomAction))).code, 'STALE_BROWSER_ELEMENT');
    assert.equal(await page.evaluate('window.effects'), undefined, 'Revalidate after the cue before issuing any effect');
    console.log('PASS side-effect-free previews, normalized target positions, zoom/clipping and revalidation before committing an action');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
