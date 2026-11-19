const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { chromium } = require('playwright');

const assets = path.resolve(__dirname, '../entry/src/main/resources/rawfile/office');
const office = vm.runInNewContext('Uint8Array.fromBase64 = value => new Uint8Array(decode(value));\n' +
  fs.readFileSync(path.join(assets, 'office.bundle.js'), 'utf8') + '\nOfficeJob', {
  decode: (value) => Buffer.from(value, 'base64'),
});
const labels = { annotate: 'Annotate', placeholder: 'Describe a change', add: 'Add annotation', cancel: 'Cancel',
  previous: 'Previous', next: 'Next', thumbnails: 'Slide thumbnails' };
const viewport = { width: 400, height: 800 };

async function openOffice(page, format, input) {
  const bytes = Buffer.from(office[format](input)).toString('base64');
  await page.route('https://office-preview.test/**', (route) => route.fulfill({
    path: path.join(assets, new URL(route.request().url()).pathname.slice(1)),
  }));
  await page.goto('https://office-preview.test/preview.html');
  await page.evaluate(({ bytes, format, labels }) => {
    window.appendOfficeBytes(bytes);
    window.renderOffice(format, labels);
  }, { bytes, format, labels });
  assert.equal(JSON.parse((await page.title()).slice(7)).type, 'ready');
}

async function expectCommentInView(page) {
  await page.waitForFunction(() => {
    const { offsetLeft, offsetTop, width, height } = visualViewport;
    const form = document.getElementById('comment');
    const bounds = form.getBoundingClientRect();
    return !form.hidden && bounds.left >= offsetLeft && bounds.top >= offsetTop &&
      bounds.right <= offsetLeft + width && bounds.bottom <= offsetTop + height &&
      [...form.querySelectorAll('textarea, button')].every((control) => {
        const { left, top, right, bottom, height: controlHeight } = control.getBoundingClientRect();
        return controlHeight > 0 && left >= bounds.left && top >= bounds.top &&
          right <= bounds.right && bottom <= bounds.bottom;
      });
  }, undefined, { timeout: 2500 });
}

async function checkMouseHighlight(browser) {
  const page = await browser.newPage({ viewport: { width: 960, height: 700 } });
  await openOffice(page, 'pptx', { slides: [{ elements: [
    { id: 'back', type: 'shape', shape: 'rect', x: 2, y: 1, w: 7, h: 4, fill: 'accent' },
    { id: 'front', type: 'text', text: 'Front shape', x: 5, y: 2, w: 3, h: 1.5, rotate: 15 },
  ] }] });
  const slide = page.locator('.stage .slide');
  const back = slide.locator('[data-element=back]');
  const front = slide.locator('[data-element=front]');
  const outline = slide.locator('.slide-hover');
  const annotate = page.getByRole('button', { name: labels.annotate });
  async function expectOutlineAt(shape) {
    const highlight = await outline.boundingBox({ timeout: 2500 });
    const target = await shape.boundingBox();
    for (const key of ['x', 'y', 'width', 'height']) {
      assert.ok(Math.abs(highlight[key] - target[key]) < 0.5, `Highlight ${key} should match the hit shape`);
    }
  }

  await front.hover();
  assert.equal(await outline.isVisible(), false);
  await annotate.click();
  await back.hover({ position: { x: 10, y: 10 } });
  await expectOutlineAt(back);
  await front.hover();
  await expectOutlineAt(front);
  await slide.hover({ position: { x: 8, y: 8 } });
  assert.equal(await outline.isVisible(), false);
  await front.hover();
  await page.mouse.move(0, 0);
  assert.equal(await outline.isVisible(), false);

  await front.hover();
  await page.mouse.down();
  assert.equal(await outline.isVisible(), false);
  await page.mouse.up();
  const note = page.getByRole('textbox', { name: labels.placeholder });
  await note.fill('This annotation belongs to the top shape');
  await page.getByRole('button', { name: labels.add }).click();
  const { target } = await page.evaluate(() => JSON.parse(window.getOfficeAnnotation()));
  assert.equal(target.elementId, 'front');
  await page.evaluate(() => window.ackOfficeAnnotation(true));

  await front.hover();
  await page.mouse.down();
  const bounds = await slide.boundingBox();
  await page.mouse.move(bounds.x + bounds.width * .8, bounds.y + bounds.height * .8);
  assert.equal(await slide.locator('.slide-selection').isVisible(), true);
  assert.equal(await outline.isVisible(), false);
  await page.mouse.up();
  await page.getByRole('button', { name: labels.cancel }).click();
  await page.close();
}

async function checkSheetAnnotation(browser) {
  const page = await browser.newPage();
  await openOffice(page, 'xlsx', [{ name: 'Budget', rows: [['Cost', 5, 8], ['Sales', 6, 10]] }]);
  const first = page.locator('td[data-location="Budget!B1"]');
  const last = page.locator('td[data-location="Budget!C2"]');
  const range = page.locator('#cell-range');
  await first.hover();
  assert.equal(await page.locator('.cell-hover').count(), 0);
  await page.getByRole('button', { name: labels.annotate }).click();
  await first.hover();
  assert.equal(await first.evaluate((cell) => cell.classList.contains('cell-hover')), true);
  await page.mouse.down();
  await last.hover();
  assert.equal(await page.locator('.cell-hover').count(), 0);
  assert.equal(await range.innerText(), 'B1:C2');
  assert.equal(await first.getAttribute('data-edges'), 'top left ');
  assert.equal(await last.getAttribute('data-edges'), 'bottom right');
  assert.equal(await page.locator('td.selected').count(), 4);
  await page.mouse.up();
  await page.getByRole('button', { name: labels.cancel }).click();
  assert.equal(await page.locator('td.selected').count(), 0);
  assert.equal(await range.isVisible(), false);

  await last.click();
  await page.getByRole('textbox', { name: labels.placeholder }).fill('Check the value');
  await page.getByRole('button', { name: labels.add }).click();
  const { target } = await page.evaluate(() => JSON.parse(window.getOfficeAnnotation()));
  assert.equal(target.location, 'Budget!C2');
  await page.evaluate(() => window.ackOfficeAnnotation(true));
  assert.equal(await page.locator('td.selected').count(), 0);
  assert.equal(await range.isVisible(), false);
  await page.close();
}

async function checkWordAnnotation(browser) {
  const page = await browser.newPage({ viewport: { width: 440, height: 700 } });
  await openOffice(page, 'docx', [
    { text: 'The delivery team completed testing. The remaining work focuses on operational readiness.' },
    { text: 'Keep this second paragraph in view.' },
  ]);
  const selected = await page.evaluate(() => {
    const paragraphs = document.querySelectorAll('.word p');
    const range = document.createRange();
    range.setStart(paragraphs[0].querySelector('span').firstChild, 4);
    range.setEnd(paragraphs[1].querySelector('span').firstChild, 16);
    const selection = getSelection();
    selection.addRange(range);
    return { text: range.toString().trim(), excerpt: selection.toString().trim() };
  });
  await page.getByRole('button', { name: labels.annotate }).click();
  const note = page.getByRole('textbox', { name: labels.placeholder });
  assert.equal(await note.evaluate((node) => node === document.activeElement), true);
  await page.evaluate(() => getSelection().removeAllRanges());
  const highlight = await page.evaluate(() => {
    const [range] = CSS.highlights.get('office-annotation');
    return { text: range.toString().trim(), rectangles: range.getClientRects().length };
  });
  assert.equal(highlight.text, selected.text);
  assert.ok(highlight.rectangles > 1);
  assert.equal(await page.locator('#comment-excerpt').textContent(), selected.excerpt);
  await page.getByRole('button', { name: labels.cancel }).click();
  assert.equal(await page.evaluate(() => CSS.highlights.has('office-annotation')), false);
  assert.equal(await page.locator('#comment-excerpt').isVisible(), false);
  await page.close();
}

async function main() {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport, isMobile: true, hasTouch: true });
    await openOffice(page, 'pptx', [{ title: 'Review this slide', body: ['Slide content'] }]);
    await page.getByRole('button', { name: labels.annotate }).tap();

    await page.locator('.stage .shape').filter({ hasText: 'Slide content' }).tap();
    const note = page.getByRole('textbox', { name: labels.placeholder });
    await note.fill('Keep this draft');
    const originalTop = await note.evaluate((node) => node.getBoundingClientRect().top);
    // Simulate both layout and visual viewports shrinking when the keyboard appears.
    await page.setViewportSize({ width: 400, height: 235 });
    await expectCommentInView(page);
    await page.setViewportSize({ width: 400, height: 125 });
    await expectCommentInView(page);
    assert.equal(await note.evaluate((node) => node === document.activeElement), true);
    await page.setViewportSize(viewport);
    await page.waitForFunction((top) => document.querySelector('#comment textarea').getBoundingClientRect().top === top,
      originalTop, { timeout: 2500 });
    assert.equal(await note.inputValue(), 'Keep this draft');
    await page.getByRole('button', { name: labels.cancel }).tap();

    const slide = await page.locator('.stage .slide').boundingBox();
    await page.mouse.move(slide.x + slide.width * .2, slide.y + slide.height * .5);
    await page.mouse.down();
    await page.mouse.move(slide.x + slide.width * .8, slide.y + slide.height * .9, { steps: 4 });
    await page.mouse.up();
    await note.fill('Check this region');
    // Shrink only the visual viewport while the layout viewport keeps its original size.
    const session = await page.context().newCDPSession(page);
    await session.send('Emulation.setPageScaleFactor', { pageScaleFactor: 2 });
    await page.waitForFunction(() => visualViewport.height < innerHeight);
    await expectCommentInView(page);
    assert.equal(await note.inputValue(), 'Check this region');
    await page.getByRole('button', { name: labels.add }).tap();
    const { target, comment } = await page.evaluate(() => JSON.parse(window.getOfficeAnnotation()));
    assert.match(target.location, / to x=/);
    assert.equal(comment, 'Check this region');
    console.log('Office annotation stays visible after layout and visual viewport changes');
    await page.close();

    await checkMouseHighlight(browser);
    console.log('PowerPoint mouse highlight matches the click target and clears during region selection');
    await checkSheetAnnotation(browser);
    console.log('Excel highlights the hit cell and clears the addressed range after cancelling or saving');
    await checkWordAnnotation(browser);
    console.log('Word keeps the selected text highlighted while the comment has focus');
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
