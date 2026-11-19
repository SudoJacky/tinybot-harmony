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
const deck = Buffer.from(office.pptx([{ title: 'Review this slide', body: ['Slide content'] }])).toString('base64');
const labels = { annotate: 'Annotate', placeholder: 'Describe a change', add: 'Add annotation', cancel: 'Cancel',
  previous: 'Previous', next: 'Next', thumbnails: 'Slide thumbnails' };
const viewport = { width: 400, height: 800 };

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

async function main() {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport, isMobile: true, hasTouch: true });
    await page.route('https://office-preview.test/**', (route) => route.fulfill({
      path: path.join(assets, new URL(route.request().url()).pathname.slice(1)),
    }));
    await page.goto('https://office-preview.test/preview.html');
    await page.evaluate(({ deck, labels }) => {
      window.appendOfficeBytes(deck);
      window.renderOffice('pptx', labels);
    }, { deck, labels });
    assert.equal(JSON.parse((await page.title()).slice(7)).type, 'ready');
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
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
