// Run the shipped extractor in Chromium. --live additionally checks current Bing pages.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { chromium, devices } = require('playwright');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const exported = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/model/BingSearch.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exported, require: name => { throw Error('Unexpected dependency ' + name); } });
const { bingSearchScript } = exported;
const item = (href, title = 'Title', snippet = 'Evidence') => `<li class="b_algo"><h2><a href="${href}">${title}</a></h2><div class="b_caption"><p>${snippet}</p></div></li>`;
const root = html => `<ol id="b_results">${html}</ol>`;
(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage();
    let html = '';
    await page.route('**/*', route => route.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
    async function extract(body, { query = '鸿蒙 & browser', maximum = 5, url } = {}) {
      html = body;
      await page.goto(url || 'https://www.bing.com/search?q=' + encodeURIComponent(query));
      return JSON.parse(await page.evaluate(bingSearchScript(query, maximum)));
    }
    const target = 'https://example.com/中文?q=鸿蒙', redirect = 'https://www.bing.com/ck/a?u=a1' + Buffer.from(target).toString('base64url');
    let result = await extract(root('<li class="b_ad"><h2><a href="https://ad.example">Ad</a></h2></li>' + item(redirect, '中文标题', '正文摘要') + item(redirect) + item('https://second.example/page')));
    assert.equal(result.state, 'results'); assert.equal(result.sources.length, 2);
    assert.deepEqual(result.sources[0], { url: new URL(target).href, title: '中文标题', snippet: '正文摘要' });
    assert.equal(result.sources.some(source => source.url.includes('bing.com')), false);
    result = await extract(root(item('https://one.example') + item('https://two.example')), { maximum: 1 });
    assert.equal(result.sources.length, 1); assert.equal(result.candidates, 2);
    result = await extract(root(item('https://one.example') + '<li class="b_algo" hidden><h2>Hidden placeholder</h2></li>'));
    assert.equal(result.state, 'results'); assert.equal(result.candidates, 1);
    for (const href of ['javascript:alert(1)', 'https://user:password@example.com', 'https://www.bing.com/ck/a?u=unknown', 'https://www.bing.com/ck/a?u=a1%%%']) {
      result = await extract(root(item(href))); assert.equal(result.state, 'invalid_results'); assert.equal(result.invalid, 1);
    }
    assert.equal((await extract(root('<li class="b_algo"><h2>Missing anchor</h2></li>'))).state, 'invalid_results');
    assert.equal((await extract(root('<li class="b_no">No results found</li>'))).state, 'empty');
    assert.equal((await extract(root('<li class="b_no" hidden>No results found</li>'))).state, 'pending');
    assert.equal((await extract('<main>New layout, not an empty search</main>')).state, 'pending');
    assert.equal((await extract('<div id="b_captcha">Please verify</div>' + root(item('https://one.example')))).state, 'verification');
    assert.equal((await extract('<div id="b_captcha" hidden>Placeholder</div>' + root(item('https://one.example')))).state, 'results');
    assert.equal((await extract('<div id="turnstile-widget">Verification in a closed shadow root</div>')).state, 'verification');
    assert.equal((await extract('<main>Challenge</main>', { url: 'https://www.bing.com/turing/captcha' })).state, 'verification');
    assert.equal((await extract(root(item('https://one.example', 'How to solve a captcha')))).state, 'results', 'Search content mentioning captcha is not a challenge');
    assert.equal((await extract(root(item('https://one.example')), { url: 'https://www.bing.com/search?q=different' })).state, 'unexpected_page');
    assert.equal((await extract(root(item('https://one.example')), { url: 'https://bing.com.example/search?q=test' })).state, 'unexpected_page');
    result = await extract(root(item('https://one.example')), { query: `x'); globalThis.injected=true; // 中文` });
    assert.equal(result.state, 'results'); assert.equal(await page.evaluate('globalThis.injected'), undefined);
    console.log('PASS real DOM: organic results, Unicode redirect decoding, deduplication, caps, invalid links, empty pages, challenges, page identity and injection safety');
    await page.close();

    if (process.argv.includes('--live')) {
      for (const [name, options] of [['desktop', {}], ['mobile', devices['Pixel 7']]]) {
        console.log('LIVE starting ' + name);
        const context = await browser.newContext(options), live = await context.newPage();
        try {
          for (const query of ['HarmonyOS ArkWeb', '鸿蒙 应用开发 文档']) {
            console.log('LIVE navigating ' + name + ': ' + query);
            await live.goto('https://www.bing.com/search?q=' + encodeURIComponent(query), { waitUntil: 'domcontentloaded', timeout: 30000 });
            console.log('LIVE document loaded ' + name);
            const deadline = Date.now() + 10000;
            let observation;
            do {
              let timeout;
              try {
                observation = JSON.parse(await Promise.race([live.evaluate(bingSearchScript(query, 5)),
                  new Promise((_, reject) => { timeout = setTimeout(() => reject(Error('Live Bing renderer did not finish extraction within 10 seconds')), 10000); })]));
              } finally { clearTimeout(timeout); }
              if (observation.state !== 'pending') break;
              await live.waitForTimeout(250);
            } while (Date.now() < deadline);
            console.log('LIVE ' + name + ' ' + JSON.stringify({ query, state: observation.state, count: observation.sources.length, candidates: observation.candidates, invalid: observation.invalid }));
            if (observation.state !== 'results') {
              console.log('LIVE page diagnostics ' + JSON.stringify(await live.evaluate(() => ({
                title: document.title, text: document.body.innerText.slice(0, 1500),
                markers: [...document.querySelectorAll('[id]')].map(node => ({ id: node.id, tag: node.tagName, visible: node.getClientRects().length > 0 })).filter(node => /capt|chall|verify|b_results|turnstile/i.test(node.id)),
                frames: [...document.querySelectorAll('iframe')].map(node => ({ src: node.src, visible: node.getClientRects().length > 0 }))
              }))));
            }
            assert.ok(['results', 'verification'].includes(observation.state), 'Live page needs inspection; do not treat failure as no results');
            if (observation.state === 'verification') {
              console.log('LIVE ' + name + ': manual verification required; not completed by this smoke test'); break;
            }
          }
        } catch (error) { console.error('LIVE failed: ' + error.message); throw error; }
        finally { await context.close(); }
      }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
