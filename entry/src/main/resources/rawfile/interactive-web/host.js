/* Trusted outer host. Generated code runs only in an opaque-origin sandbox frame. */
(() => {
  'use strict';
  const config = JSON.parse(document.getElementById('vendor').textContent);
  const library = config.library;
  let port, frame, initialized = false;
  const send = data => port.postMessage(JSON.stringify(data));
  const script = text => '<script>' + text.replace(/<\/script/gi, '<\\/script') + '</script>';
  function childRuntime(initial) {
    let state = initial.values, active = initial.active, seq = 0, pending, animate, raf = 0, previous = 0, failed = false;
    const listeners = new Set();
    const storagePending = new Map();
    let panel = initial.panel || null, refreshPending, mailPending, checking = false;
    const panelListeners = new Set();
    function theme() {
      if (!panel) return;
      document.documentElement.style.colorScheme = panel.theme || 'light';
      for (const [name, value] of Object.entries(panel.tokens || {})) document.documentElement.style.setProperty('--tinybot-' + name, value);
      document.documentElement.lang = panel.locale || 'zh-CN';
    }
    theme();
    const copy = value => JSON.parse(JSON.stringify(value));
    const send = value => parent.postMessage({ channel: 'tinybot-frame', ...value }, '*');
    const failure = error => {
      failed = true;
      let detail = String(error?.stack || error?.message || error);
      if (detail.includes('THREE.OrbitControls')) detail = 'Use new OrbitControls(camera, renderer.domElement); OrbitControls is a separate preloaded global, not THREE.OrbitControls.\n' + detail;
      send({ type: 'error', message: detail });
    };
    function tick(time) {
      raf = 0;
      if (!active || document.hidden || !animate) return;
      try { animate(time / 1000, previous ? Math.min((time - previous) / 1000, 0.1) : 0); previous = time; raf = requestAnimationFrame(tick); }
      catch (error) { animate = undefined; failure(error); }
    }
    function resume() {
      cancelAnimationFrame(raf); raf = 0; previous = 0;
      if (active && !document.hidden && animate) raf = requestAnimationFrame(tick);
    }
    addEventListener('visibilitychange', resume);
    addEventListener('error', event => failure(event.error || event.message || ('Resource failed: ' + event.target?.tagName)), true);
    addEventListener('unhandledrejection', event => failure(event.reason));
    addEventListener('securitypolicyviolation', event => failure('Blocked resource: ' + event.violatedDirective));
    const consoleError = console.error.bind(console);
    console.error = (...args) => { consoleError(...args); failure(args.map(value => String(value?.stack || value)).join(' ')); };
    addEventListener('message', event => {
      if (event.source !== parent || event.data?.channel !== 'tinybot-host') return;
      const data = event.data;
      if (data.type === 'state') {
        state = data.values; active = data.active;
        if (!active && mailPending) {
          const request = mailPending; mailPending = undefined;
          request.reject(new Error('Mail reading is unavailable in this view.'));
        }
        panel = data.panel || null; theme();
        for (const listener of panelListeners) listener(copy(panel));
        for (const listener of listeners) listener(copy(state));
        resume();
      } else if (data.type === 'panelResult' && refreshPending?.id === data.id) {
        const request = refreshPending; refreshPending = undefined;
        if (data.error) request.reject(new Error(data.error)); else request.resolve();
      } else if (data.type === 'panelMailResult' && mailPending?.id === data.id) {
        const request = mailPending; mailPending = undefined;
        if (data.error) request.reject(new Error(data.error)); else request.resolve(copy(data.mail));
      } else if (data.type === 'snapshot' && initial.snapshotMode) {
        requestAnimationFrame(() => requestAnimationFrame(() => { if (!failed) send({ type: 'snapshotReady' }); }));
      } else if (data.type === 'storageResult' && storagePending.has(data.id)) {
        const request = storagePending.get(data.id); storagePending.delete(data.id);
        if (data.error) request.reject(new Error(data.error));
        else request.resolve(copy(data.snapshot));
      } else if (data.type === 'ack' && pending?.id === data.id) {
        const saved = pending; pending = undefined;
        if (data.error) saved.reject(new Error(data.error));
        else { state = data.values; saved.resolve(copy(state)); }
      }
    });
    function storageRequest(type, value, revision, scope) {
      if (type === 'storageSave' && ((initial.preflight && !checking) || initial.snapshotMode || !active)) {
        return Promise.reject(new Error('Save mini app data only during an active user interaction.'));
      }
      if (type === 'storageSave' && (value === undefined || typeof revision !== 'string' || !revision)) {
        return Promise.reject(new Error('Use the revision returned by tinybot.storage.load() or save().'));
      }
      const request = JSON.parse(JSON.stringify({ type, id: ++seq, value, revision, scope }));
      return new Promise((resolve, reject) => { storagePending.set(request.id, { resolve, reject }); send(request); });
    }
    Object.defineProperty(window, 'tinybot', { value: Object.freeze({
      get state() { return copy(state); }, get active() { return active; },
      onState(listener) { listeners.add(listener); return () => listeners.delete(listener); },
      animate(callback) { animate = callback; resume(); return () => { animate = undefined; resume(); }; },
      storage: Object.freeze({
        load() { return storageRequest('storageLoad'); },
        save(value, revision) { return storageRequest('storageSave', value, revision); }
      }),
      panel: Object.freeze({
        get context() { return copy(panel); },
        viewState: Object.freeze({
          get available() { return initial.placement === true; },
          load() { return initial.placement ? storageRequest('storageLoad', undefined, undefined, 'placement') : Promise.reject(new Error('View state requires a board placement')); },
          save(value, revision) { return initial.placement ? storageRequest('storageSave', value, revision, 'placement') : Promise.reject(new Error('View state requires a board placement')); }
        }),
        onUpdate(listener) { panelListeners.add(listener); return () => panelListeners.delete(listener); },
        readMail(request) {
          if (!active || initial.preflight || initial.snapshotMode || !panel?.canReadMail) return Promise.reject(new Error('Mail reading is unavailable in this view.'));
          if (!request || typeof request !== 'object' || Array.isArray(request) ||
            Object.keys(request).some(key => !['uidValidity', 'uid'].includes(key)) ||
            ![request.uidValidity, request.uid].every(value => Number.isInteger(value) && value >= 1 && value <= 4294967295)) {
            return Promise.reject(new Error('Use the uidValidity and uid from the mail source message.'));
          }
          if (mailPending) return Promise.reject(new Error('A mail read is already in progress.'));
          return new Promise((resolve, reject) => {
            mailPending = { id: ++seq, resolve, reject };
            send({ type: 'panelMailRead', id: seq, mail: { uidValidity: request.uidValidity, uid: request.uid } });
          });
        },
        refresh(inputs) {
          if (!active || initial.preflight || initial.snapshotMode || !panel?.canRefresh) return Promise.reject(new Error('Card refresh is unavailable in this view.'));
          if (refreshPending) return Promise.reject(new Error('A refresh is already in progress.'));
          return new Promise((resolve, reject) => { refreshPending = { id: ++seq, resolve, reject }; send({ type: 'panelRefresh', id: seq, inputs }); });
        }
      }),
      save(values) {
        if (initial.preflight) return Promise.reject(new Error('Save state only on user interaction, not during initialization/preflight.'));
        if (!active) return Promise.reject(new Error('This interface is currently read-only.'));
        if (pending) return Promise.reject(new Error('A save is already in progress.'));
        const serialized = JSON.stringify(values);
        return new Promise((resolve, reject) => { pending = { id: ++seq, resolve, reject }; send({ type: 'save', id: seq, values: JSON.parse(serialized) }); });
      }
    }), writable: false });
    window.__tinybotReady = () => {
      if (initial.autoHeight) {
        let lastHeight = -1;
        const measure = () => {
          const body = document.body, style = getComputedStyle(body);
          const height = Math.ceil(Math.max(body.getBoundingClientRect().height, body.scrollHeight) +
            (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0));
          if (height !== lastHeight) { lastHeight = height; send({ type: 'resize', height }); }
        };
        new ResizeObserver(measure).observe(document.body);
        measure();
      }
      // Exercise the initial animation callback even if an invisible Web component throttles RAF.
      if (initial.preflight && animate && !failed) {
        try { animate(0, 0); } catch (error) { failure(error); }
      }
      // Catch initial unhandled rejections, timers and WebGL errors before publication.
      setTimeout(async () => {
        if (failed) return;
        try {
          if (initial.panelProbe) {
            const pause = () => new Promise(resolve => setTimeout(resolve, 100));
            const eventually = async assertion => {
              const deadline = Date.now() + 2000;
              for (;;) {
                try { await assertion(); return; }
                catch (error) { if (failed || Date.now() >= deadline) throw error; await pause(); }
              }
            };
            const checks = initial.panelProbe.checks || [];
            for (let index = 0; index < checks.length; index++) {
              const check = checks[index];
              try {
                if (check.action === 'stored') {
                  await eventually(async () => {
                    const saved = await tinybot.storage.load();
                    const actual = check.path.split('/').slice(1).reduce((value, key) => value?.[key.replace(/~1/g, '/').replace(/~0/g, '~')], saved.value);
                    if (JSON.stringify(actual) !== JSON.stringify(check.expected)) throw Error('Saved value does not match expected value at ' + check.path);
                  });
                } else {
                  const nodes = document.querySelectorAll(check.selector);
                  if (nodes.length !== 1) throw Error('Selector must match exactly one element, found ' + nodes.length);
                  const element = nodes[0], rect = element.getBoundingClientRect();
                  if (!rect.width || !rect.height || getComputedStyle(element).visibility === 'hidden') throw Error('Element is not visible');
                  if (['click', 'input', 'select'].includes(check.action) && element.disabled) throw Error('Control is disabled');
                  if (['click', 'input', 'select'].includes(check.action)) checking = true;
                  if (check.action === 'click') element.click();
                  else if (check.action === 'input' || check.action === 'select') {
                    element.value = check.value; element.dispatchEvent(new Event('input', {bubbles:true})); element.dispatchEvent(new Event('change', {bubbles:true}));
                  } else if (check.action === 'text') await eventually(() => {
                    if (!element.textContent.includes(check.value)) throw Error('Expected text not found: ' + check.value);
                  });
                  await pause();
                }
              } catch (error) { throw Error('check[' + index + '] ' + check.action + ' ' + (check.selector || check.path) + ': ' + error.message); }
              if (failed) return;
            }
            if (Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) > innerWidth + 2) throw Error('Horizontal overflow at width ' + innerWidth);
            const unnamed = [...document.querySelectorAll('button,input:not([type=hidden]),select,textarea')].find(el => el.getBoundingClientRect().width &&
              !el.textContent.trim() && !el.getAttribute('aria-label') && !el.getAttribute('aria-labelledby') && !el.labels?.length && !el.getAttribute('title'));
            if (unnamed) throw Error('Control needs an accessible label: ' + unnamed.tagName.toLowerCase() + (unnamed.id ? '#' + unnamed.id : ''));
            await eventually(() => { if (storagePending.size) throw Error('Storage operation did not finish'); });
            await pause(); checking = false;
          }
          if (!failed) send({ type: 'ready' });
        } catch (error) { checking = false; failure(error); }
      }, initial.preflight ? 250 : 0);
    };
    window.__tinybotError = failure;
  }
  const panelStyle = 'html{--tinybot-font:system-ui,sans-serif;--tinybot-text-secondary:color-mix(in srgb,var(--tinybot-text,#17251f) 65%,transparent);--tinybot-surface-muted:color-mix(in srgb,var(--tinybot-text,#17251f) 6%,var(--tinybot-surface,white));--tinybot-border:color-mix(in srgb,var(--tinybot-text,#17251f) 18%,transparent);--tinybot-on-accent:#fff;--tinybot-danger:#b3261e;--tinybot-space-1:4px;--tinybot-space-2:8px;--tinybot-space-3:12px;--tinybot-space-4:16px;--tinybot-space-5:24px;--tinybot-space-6:32px;--tinybot-radius:16px;--tinybot-control-radius:10px}.tb-card{padding:var(--tinybot-space-4);font-family:var(--tinybot-font);color:var(--tinybot-text,#17251f);background:var(--tinybot-surface,white);border-radius:var(--tinybot-radius);overflow-wrap:anywhere;width:100%}.tb-stack{display:flex;flex-direction:column;gap:var(--tinybot-space-3);min-width:0}.tb-row{display:flex;flex-wrap:wrap;align-items:center;gap:var(--tinybot-space-2)}.tb-title{font-size:18px;font-weight:500;line-height:1.4;margin:0}.tb-meta{font-size:12px;line-height:1.5;color:var(--tinybot-text-secondary);margin:0}.tb-number{font-size:32px;line-height:1.2;font-weight:500;font-variant-numeric:tabular-nums}.tb-button{font:inherit;min-height:40px;padding:8px 16px;border:1px solid var(--tinybot-border);border-radius:var(--tinybot-control-radius);background:var(--tinybot-surface,white);color:var(--tinybot-text,#17251f);max-width:100%;white-space:normal;cursor:pointer}.tb-primary{background:var(--tinybot-accent,#246959);color:var(--tinybot-on-accent);border-color:transparent}.tb-button:disabled{opacity:.5;cursor:default}.tb-field{display:flex;flex-direction:column;gap:8px;min-width:0}.tb-input{font:inherit;min-height:40px;width:100%;max-width:100%;padding:8px 12px;border:1px solid var(--tinybot-border);border-radius:var(--tinybot-control-radius);background:var(--tinybot-surface,white);color:var(--tinybot-text,#17251f)}.tb-error{font-size:12px;color:var(--tinybot-danger);overflow-wrap:anywhere}';
  function mount(data) {
    if (initialized) throw new Error('Web UI already initialized');
    initialized = true;
    const spec = data.spec;
    frame = document.createElement('iframe');
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.setAttribute('allow', "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'");
    frame.title = 'Interactive content';
    const bootstrap = '(' + childRuntime.toString() + ')(' + JSON.stringify({ values: data.values, panel: data.panel, placement: data.placement, panelProbe: data.panelProbe, active: data.active, preflight: data.preflight === true, autoHeight: data.autoHeight === true, snapshotMode: data.snapshotMode === true }).replace(/</g, '\\u003c') + ');';
    const csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
    frame.srcdoc = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta http-equiv="Content-Security-Policy" content="' + csp + '">' +
      '<style>html{color-scheme:light;-webkit-tap-highlight-color:transparent}body{margin:0;font:15px system-ui;color:var(--tinybot-text,#17251f);background:var(--tinybot-surface,white)}*{box-sizing:border-box}canvas{display:block;max-width:100%;touch-action:none}button,input,select{font:inherit}button{min-height:40px}button,input,select,textarea{transition:background-color 160ms,box-shadow 160ms,transform 120ms}button:active{transform:scale(.97)}:focus-visible{outline:2px solid var(--tinybot-accent,#246959);outline-offset:2px}@media(prefers-reduced-motion:reduce){button,input,select,textarea{transition:none}}</style>' +
      (data.panel ? '<style>' + panelStyle + '</style>' : '') +
      '<style>' + spec.css.replace(/<\/style/gi, '<\\/style') + '</style>' +
      (data.autoHeight ? '<style>html,body{min-height:0!important;overflow:auto}</style>' : '') + script(bootstrap) +
      ((data.automation || data.annotations) && config.browserScript ? script(config.browserScript) : '') +
      (spec.library === 'three' ? script(library) : '') + '</head><body>' + spec.html +
      script('Promise.resolve((async()=>{\n' + spec.js + '\n})()).then(__tinybotReady).catch(__tinybotError);\n//# sourceURL=tinybot-generated.js') + '</body></html>';
    document.body.append(frame);
  }
  addEventListener('message', event => {
    if (!port && event.data === 'tinybot-web-port' && event.ports.length === 1 && !frame) {
      port = event.ports[0];
      port.onmessage = event => {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'init') mount(data);
          else if (frame) frame.contentWindow.postMessage({ channel: 'tinybot-host', ...data }, '*');
        } catch (error) { send({ type: 'error', message: String(error.stack || error.message) }); }
      };
      port.start();
    } else if (frame && event.source === frame.contentWindow && event.data?.channel === 'tinybot-frame') {
      const data = event.data;
      if (data.type === 'browserResult' && typeof data.message === 'string') {
        send({type:'browserResult',id:data.id,message:data.message});
      }
      else if (data.type === 'annotationTarget') send({ type: 'annotationTarget', target: data.target });
      else if (data.type === 'storageLoad') send({ type: 'storageLoad', id: data.id, scope: data.scope });
      else if (data.type === 'panelRefresh') send({ type: 'panelRefresh', id: data.id, inputs: data.inputs });
      else if (data.type === 'panelMailRead') send({ type: 'panelMailRead', id: data.id, mail: data.mail });
      else if (data.type === 'storageSave') send({ type: 'storageSave', id: data.id, value: data.value, revision: data.revision, scope: data.scope });
      else if (data.type === 'save') send({ type: 'save', id: data.id, values: data.values });
      else if (data.type === 'resize') send({ type: 'resize', height: data.height });
      else if (data.type === 'ready') send({ type: 'ready' });
      else if (data.type === 'snapshotReady') send({ type: 'snapshotReady' });
      else if (data.type === 'error') send({ type: 'error', message: String(data.message) });
    }
  });
  window.__tinybotHostReady = true;
})();
