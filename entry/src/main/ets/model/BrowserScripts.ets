import { BrowserAction } from '../services/BrowserSession';

// Fixed scripts only: the model never supplies JavaScript, selectors, native bridges or cookies.
const SENSITIVE_INPUT: string = `const sensitive = node => node.matches('input[type="password"],input[type="hidden"],input[type="file"]') || /password|one-time-code|cc-number|cc-csc/.test(node.autocomplete || '') || /password|passwd|secret|token|otp|verification|验证码|密码/i.test((node.name || '') + ' ' + (node.id || ''));`;
const PAGE_STATE: string = `
  const label = node => (node.getAttribute('aria-label') || node.labels?.[0]?.innerText || node.innerText || node.getAttribute('placeholder') || node.title || node.name || '').trim().slice(0, 240);
  const viewport = () => JSON.stringify([scrollX, scrollY, innerWidth, innerHeight, visualViewport?.offsetLeft, visualViewport?.offsetTop, visualViewport?.scale, visualViewport?.width, visualViewport?.height]);
  const identity = node => {
    const r = node.getBoundingClientRect();
    return JSON.stringify([node.tagName, node.getAttribute('role'), label(node), node.getAttribute('href'), node.getAttribute('type'),
      Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height),
      node.tagName === 'SELECT' ? [...node.options].map(o => [o.value, o.text]) : null]);
  };`;

export function browserSnapshotScript(id: string): string {
  return `(() => {
    ${SENSITIVE_INPUT}
    ${PAGE_STATE}
    const snapshotId = ${JSON.stringify(id)};
    const visible = node => { const r = node.getBoundingClientRect(); const s = getComputedStyle(node); return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none'; };
    const nodes = [...document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]')].filter(visible);
    const retained = nodes.slice(0, 80);
    globalThis.__tinybotBrowserSnapshot = { id: snapshotId, nodes: retained, viewport: viewport(), identities: retained.map(identity) };
    const elements = retained.map((node, index) => ({ id: index + 1,
      role: node.getAttribute('role') || node.tagName.toLowerCase(),
      label: label(node),
      type: sensitive(node) ? 'user-only' : (node.type || ''), disabled: !!node.disabled || node.getAttribute('aria-disabled') === 'true',
      options: node.tagName === 'SELECT' ? [...node.options].slice(0, 50).map(o => ({ value: o.value.slice(0, 200), label: o.text.slice(0, 200) })) : undefined
    }));
    const text = document.body?.innerText || '';
    return JSON.stringify({ snapshotId, url: location.href, title: document.title.slice(0, 300), text: text.slice(0, 16000), elements,
      truncated: text.length > 16000 || nodes.length > 80, embeddedFrames: document.querySelectorAll('iframe,frame').length, trust: 'untrusted' });
  })()`;
}

export function browserActionScript(action: BrowserAction, preview: boolean = false): string {
  return `(() => {
    ${SENSITIVE_INPUT}
    ${PAGE_STATE}
    const args = ${JSON.stringify(action)};
    const preview = ${preview};
    const fail = (code, message) => JSON.stringify({ code, message });
    if (args.action === 'scroll') { window.scrollBy({ top: args.deltaY, behavior: 'instant' }); return JSON.stringify({ ok: true }); }
    const snapshot = globalThis.__tinybotBrowserSnapshot;
    if (!snapshot || snapshot.id !== args.snapshotId) return fail('STALE_BROWSER_SNAPSHOT', 'Read a new browser snapshot before acting.');
    if (snapshot.viewport !== viewport()) return fail('STALE_BROWSER_SNAPSHOT', 'The page was scrolled, resized or zoomed. Read a new snapshot before acting.');
    const node = snapshot.nodes[args.elementId - 1];
    if (!node || !node.isConnected) return fail('STALE_BROWSER_ELEMENT', 'The element changed. Read a new snapshot.');
    if (sensitive(node)) return fail('USER_INPUT_REQUIRED', 'This control requires user handoff.');
    if (node.disabled || node.getAttribute('aria-disabled') === 'true') return fail('ELEMENT_DISABLED', 'The element is disabled.');
    if (snapshot.identities[args.elementId - 1] !== identity(node)) return fail('STALE_BROWSER_ELEMENT', 'The element content or position changed. Read a new snapshot before acting.');
    const target = () => {
      const r = node.getBoundingClientRect(); const v = window.visualViewport;
      const x = v?.offsetLeft ?? 0, y = v?.offsetTop ?? 0, width = v?.width ?? innerWidth, height = v?.height ?? innerHeight;
      const left = Math.max(r.left, x), top = Math.max(r.top, y), right = Math.min(r.right, x + width), bottom = Math.min(r.bottom, y + height);
      if (width <= 0 || height <= 0 || right <= left || bottom <= top) return fail('STALE_BROWSER_ELEMENT', 'The element is outside the visible viewport. Read a new snapshot.');
      return JSON.stringify({ ok: true, target: { x: ((left + right) / 2 - x) / width, y: ((top + bottom) / 2 - y) / height } });
    };
    if (args.action === 'click') { if (preview) return target(); node.click(); }
    else if (args.action === 'type') {
      if (!['INPUT', 'TEXTAREA'].includes(node.tagName) || node.readOnly) return fail('UNSUPPORTED_CONTROL', 'This is not an editable text field. Hand off unsupported controls.');
      if (node.tagName === 'INPUT' && !['text','search','email','tel','url','number'].includes(node.type)) return fail('UNSUPPORTED_CONTROL', 'This input type requires user interaction.');
      if (preview) return target();
      const prototype = node.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
      const previous = node.value; setter.call(node, args.text);
      if (node.value !== args.text) { setter.call(node, previous); return fail('INVALID_INPUT_VALUE', 'The input cannot accept this value without changing it.'); }
      node.dispatchEvent(new Event('input', { bubbles: true })); node.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (args.action === 'select') {
      if (node.tagName !== 'SELECT' || ![...node.options].some(o => o.value === args.text)) return fail('INVALID_OPTION', 'Choose a value from the select options.');
      if (preview) return target();
      node.value = args.text; node.dispatchEvent(new Event('input', { bubbles: true })); node.dispatchEvent(new Event('change', { bubbles: true }));
    } else return fail('INVALID_ARGUMENTS', 'Unknown DOM action.');
    return JSON.stringify({ ok: true });
  })()`;
}
