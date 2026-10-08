/* Trusted outer host. Generated code runs only in an opaque-origin sandbox frame. */
(() => {
  'use strict';
  const library = JSON.parse(document.getElementById('vendor').textContent).library;
  let port, frame, initialized = false;
  const send = data => port.postMessage(JSON.stringify(data));
  const script = text => '<script>' + text.replace(/<\/script/gi, '<\\/script') + '</script>';
  function childRuntime(initial) {
    let state = initial.values, active = initial.active, seq = 0, pending, animate, raf = 0, previous = 0;
    const listeners = new Set();
    const copy = value => JSON.parse(JSON.stringify(value));
    const send = value => parent.postMessage({ channel: 'tinybot-frame', ...value }, '*');
    const failure = error => send({ type: 'error', message: String(error?.message || error).slice(0, 2000) });
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
    addEventListener('error', event => failure(event.error || event.message));
    addEventListener('unhandledrejection', event => failure(event.reason));
    addEventListener('securitypolicyviolation', event => failure('Blocked resource: ' + event.violatedDirective));
    addEventListener('message', event => {
      if (event.source !== parent || event.data?.channel !== 'tinybot-host') return;
      const data = event.data;
      if (data.type === 'state') {
        state = data.values; active = data.active;
        for (const listener of listeners) listener(copy(state));
        resume();
      } else if (data.type === 'ack' && pending?.id === data.id) {
        const saved = pending; pending = undefined;
        if (data.error) saved.reject(new Error(data.error));
        else { state = data.values; saved.resolve(copy(state)); }
      }
    });
    Object.defineProperty(window, 'tinybot', { value: Object.freeze({
      get state() { return copy(state); }, get active() { return active; },
      onState(listener) { listeners.add(listener); return () => listeners.delete(listener); },
      animate(callback) { animate = callback; resume(); return () => { animate = undefined; resume(); }; },
      save(values) {
        if (!active) return Promise.reject(new Error('This interface is currently read-only.'));
        if (pending) return Promise.reject(new Error('A save is already in progress.'));
        const serialized = JSON.stringify(values);
        if (serialized.length > 12000) return Promise.reject(new Error('State exceeds 12,000 characters.'));
        return new Promise((resolve, reject) => { pending = { id: ++seq, resolve, reject }; send({ type: 'save', id: seq, values: JSON.parse(serialized) }); });
      }
    }), writable: false });
    window.__tinybotReady = () => send({ type: 'ready' });
    window.__tinybotError = failure;
  }
  function mount(data) {
    if (initialized) throw new Error('Web UI already initialized');
    initialized = true;
    const spec = data.spec;
    frame = document.createElement('iframe');
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.setAttribute('allow', "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'");
    frame.title = 'Interactive content';
    const bootstrap = '(' + childRuntime.toString() + ')(' + JSON.stringify({ values: data.values, active: data.active }).replace(/</g, '\\u003c') + ');';
    const csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
    frame.srcdoc = '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta http-equiv="Content-Security-Policy" content="' + csp + '">' +
      '<style>html{color-scheme:light}body{margin:0;font:15px system-ui;color:#17251f;background:white}*{box-sizing:border-box}canvas{display:block;max-width:100%;touch-action:none}button,input,select{font:inherit}button{min-height:40px}</style>' +
      '<style>' + spec.css.replace(/<\/style/gi, '<\\/style') + '</style>' + script(bootstrap) +
      (spec.library === 'three' ? script(library) : '') + '</head><body>' + spec.html +
      script('Promise.resolve((async()=>{\n' + spec.js + '\n})()).then(__tinybotReady).catch(__tinybotError);') + '</body></html>';
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
        } catch (error) { send({ type: 'error', message: String(error.message).slice(0, 2000) }); }
      };
      port.start();
    } else if (frame && event.source === frame.contentWindow && event.data?.channel === 'tinybot-frame') {
      const data = event.data;
      if (data.type === 'save') send({ type: 'save', id: data.id, values: data.values });
      else if (data.type === 'ready') send({ type: 'ready' });
      else if (data.type === 'error') send({ type: 'error', message: String(data.message).slice(0, 2000) });
    }
  });
  window.__tinybotHostReady = true;
})();
