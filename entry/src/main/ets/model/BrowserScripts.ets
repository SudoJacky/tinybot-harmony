import { BrowserAction } from '../services/BrowserSession';
import { BrowserElementMark, BrowserPropertyChange } from './BrowserAnnotation';

export const BROWSER_STYLE_PROPERTIES: string[] = [
  'color', 'background-color', 'font-size', 'font-weight', 'padding', 'border-width', 'opacity', 'font-family', 'text'
];

export interface BrowserInspectorCommand {
  action: 'select' | 'read' | 'style' | 'reset' | 'clear';
  id?: number;
  x?: number;
  y?: number;
  property?: string;
  value?: string;
}

export interface BrowserElementSelection {
  id: number;
  label: string;
  tag: string;
  location: string;
  mark?: BrowserElementMark;
  viewport: string;
  values: string[];
  edited: boolean;
  textEditable: boolean;
  changes: BrowserPropertyChange[];
}

// Fixed scripts only: the model never supplies JavaScript, selectors, native bridges or cookies.
const SENSITIVE_INPUT: string = `const sensitive = node => node.matches('input[type="password"],input[type="hidden"],input[type="file"]') || /password|one-time-code|cc-number|cc-csc/.test(node.autocomplete || '') || /password|passwd|secret|token|otp|verification|验证码|密码/i.test((node.name || '') + ' ' + (node.id || ''));`;
const PAGE_STATE: string = `
  const rawLabel = node => (node.getAttribute('aria-label') || node.labels?.[0]?.innerText || node.innerText || node.getAttribute('placeholder') || node.title || node.name || '').trim();
  const label = node => rawLabel(node).slice(0, 240);
  const viewport = () => JSON.stringify([scrollX, scrollY, innerWidth, innerHeight, visualViewport?.offsetLeft, visualViewport?.offsetTop, visualViewport?.scale, visualViewport?.width, visualViewport?.height]);
  const identity = node => {
    const r = node.getBoundingClientRect();
    return JSON.stringify([node.tagName, node.getAttribute('role'), label(node), node.getAttribute('href'), node.getAttribute('type'),
      Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height),
      node.tagName === 'SELECT' ? [...node.options].map(o => [o.value, o.text]) : null]);
  };`;

function snapshotScript(idExpression: string): string {
  return `(() => {
    ${SENSITIVE_INPUT}
    ${PAGE_STATE}
    const snapshotId = ${idExpression};
    const reductions = new Set();
    const clip = (text, max, field) => { if (text.length > max) reductions.add(field + ' shortened to ' + max + ' characters.'); return text.slice(0, max); };
    const visible = node => { const r = node.getBoundingClientRect(); const s = getComputedStyle(node); return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none'; };
    const nodes = [...document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[role="link"],[contenteditable="true"]')].filter(visible);
    const retained = nodes.slice(0, 80);
    globalThis.__tinybotBrowserSnapshot = { id: snapshotId, nodes: retained, viewport: viewport(), identities: retained.map(identity) };
    const elements = retained.map((node, index) => ({ id: index + 1,
      role: node.getAttribute('role') || node.tagName.toLowerCase(),
      label: clip(rawLabel(node), 240, 'Element label'),
      value: sensitive(node) ? undefined : clip(String(node.value ?? ''), 1000, 'Input value'), checked: sensitive(node) ? undefined : node.checked,
      type: sensitive(node) ? 'user-only' : (node.type || ''), disabled: !!node.disabled || node.getAttribute('aria-disabled') === 'true',
      options: node.tagName === 'SELECT' ? [...node.options].slice(0, 50).map(o => ({ value: clip(o.value, 200, 'Option value'), label: clip(o.text, 200, 'Option label') })) : undefined
    }));
    const text = document.body?.innerText || '';
    if (nodes.length > 80) reductions.add('Only the first 80 visible interactive elements are included. Scroll and take a new snapshot for other controls.');
    if (retained.some(node => node.tagName === 'SELECT' && node.options.length > 50)) reductions.add('Select option lists shortened to 50 options.');
    if (retained.some(sensitive)) reductions.add('Sensitive control values were redacted; use user handoff for these fields.');
    const title = clip(document.title, 300, 'Page title');
    const body = clip(text, 16000, 'Document text');
    return JSON.stringify({ snapshotId, url: location.href, title, text: body, elements, reductions: [...reductions],
      textScope: 'document', elementsScope: 'viewport',
      viewport: { x: scrollX, y: scrollY, width: innerWidth, height: innerHeight, scrollHeight: Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0) },
      truncated: reductions.size > 0, embeddedFrames: document.querySelectorAll('iframe,frame').length, trust: 'untrusted' });
  })()`;
}

function actionScript(actionExpression: string, preview: boolean): string {
  return `(() => {
    ${SENSITIVE_INPUT}
    ${PAGE_STATE}
    const args = ${actionExpression};
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

export function browserSnapshotScript(id: string): string { return snapshotScript(JSON.stringify(id)); }
export function browserActionScript(action: BrowserAction, preview: boolean = false): string {
  return actionScript(JSON.stringify(action), preview);
}

function inspectorScript(expression: string): string {
  return `(() => {
    ${SENSITIVE_INPUT}
    const command = ${expression};
    const properties = ${JSON.stringify(BROWSER_STYLE_PROPERTIES)};
    const viewport = window.visualViewport;
    const left = viewport?.offsetLeft ?? 0, top = viewport?.offsetTop ?? 0;
    const width = viewport?.width ?? innerWidth, height = viewport?.height ?? innerHeight;
    const fail = code => JSON.stringify({code});
    const restore = selection => {
      const {node, originals, hadStyle} = selection;
      for (const [property, previous] of originals) {
        if (previous.value) node.style.setProperty(property, previous.value, previous.priority);
        else node.style.removeProperty(property);
      }
      if (originals.size && !hadStyle && !node.style.length) node.removeAttribute('style');
      originals.clear();
      if (selection.before.has('text') && selection.textNode?.parentNode === node) {
        selection.textNode.data = selection.before.get('text');
      }
      selection.before.clear();
    };
    const state = globalThis.__tinybotElementInspector ??= {sequence: 0, selection: null};
    const clear = () => {
      if (state.selection) restore(state.selection);
      state.selection = null;
    };
    if (state.sequence === 0 && !state.listening) {
      addEventListener('pagehide', clear);
      state.listening = true;
    }
    const describe = node => {
      const path = [];
      for (let part = node; part?.parentElement && part !== document.body; part = part.parentElement) {
        if (part.id && !sensitive(part)) {
          const id = '#' + CSS.escape(part.id);
          if (document.querySelectorAll(id).length === 1) { path.unshift(id); break; }
        }
        const peers = [...part.parentElement.children].filter(peer => peer.localName === part.localName);
        path.unshift(CSS.escape(part.localName) + ':nth-of-type(' + (peers.indexOf(part) + 1) + ')');
      }
      const label = sensitive(node) || node.isContentEditable ? '' :
        (node.getAttribute('aria-label') || node.getAttribute('alt') ||
          (node.matches('input,textarea,select') ? '' : node.innerText) || '').trim().slice(0, 160);
      return {label, location: path.join(' > ').slice(0, 1000)};
    };
    if (command.action === 'select') {
      if (![command.x, command.y].every(value => Number.isFinite(value) && value >= 0 && value <= 1)) return fail('NO_ELEMENT');
      const hit = document.elementFromPoint(left + command.x * width, top + command.y * height);
      if (!hit || hit === document.documentElement || hit === document.body || hit.closest('iframe,frame')) return fail('NO_ELEMENT');
      const node = hit.closest('button,a,h1,h2,h3,h4,h5,h6,img,p,input,textarea,select,[role="button"],[contenteditable]') || hit;
      const box = node.getBoundingClientRect();
      if (!node.style || !box.width || !box.height) return fail('NO_ELEMENT');
      clear();
      const textNode = !sensitive(node) && !node.isContentEditable && !node.matches('input,textarea,select,script,style') &&
        node.childNodes.length === 1 && node.firstChild.nodeType === Node.TEXT_NODE && node.firstChild.data.length <= 160
        ? node.firstChild : null;
      state.selection = {id: ++state.sequence, node, textNode, ...describe(node), originals: new Map(), before: new Map(),
        hadStyle: node.hasAttribute('style')};
    } else if (!state.selection || state.selection.id !== command.id) {
      return command.action === 'clear' ? '{}' : fail('STALE_ELEMENT');
    }
    const selection = state.selection;
    const node = selection.node;
    if (command.action === 'clear') { clear(); return '{}'; }
    const computed = getComputedStyle(node);
    if (!node.isConnected || computed.display === 'none' || computed.visibility !== 'visible' || !node.getClientRects().length) {
      clear(); return fail('STALE_ELEMENT');
    }
    const textEditable = !!selection.textNode && selection.textNode.parentNode === node && !node.isContentEditable && !sensitive(node);
    const read = property => (property === 'text' ? (textEditable ? selection.textNode.data : '') :
      computed.getPropertyValue(property)).slice(0, 160);
    if (command.action === 'reset') restore(selection);
    if (command.action === 'style') {
      const {property, value} = command;
      if (!properties.includes(property) || typeof value !== 'string' || value.includes(String.fromCharCode(0)) ||
        (property === 'text' ? (!textEditable || value.length > 160) : (!value.trim() || value.length > 120 || !CSS.supports(property, value)))) {
        return fail('INVALID_STYLE');
      }
      if (!selection.before.has(property)) selection.before.set(property, read(property));
      if (property === 'text') selection.textNode.data = value;
      else {
        const sides = ['top', 'right', 'bottom', 'left'];
        const affected = property === 'padding' ? sides.map(side => 'padding-' + side) :
          property === 'border-width' ? sides.map(side => 'border-' + side + '-width') : [property];
        for (const name of affected) {
          if (!selection.originals.has(name)) {
            selection.originals.set(name, {value: node.style.getPropertyValue(name), priority: node.style.getPropertyPriority(name)});
          }
        }
        node.style.setProperty(property, value, 'important');
      }
    }
    const {label, location} = selection;
    const box = node.getBoundingClientRect();
    const x0 = Math.max(box.left, left), y0 = Math.max(box.top, top);
    const x1 = Math.min(box.right, left + width), y1 = Math.min(box.bottom, top + height);
    const mark = x1 > x0 && y1 > y0 ? {x:(x0-left)/width,y:(y0-top)/height,width:(x1-x0)/width,height:(y1-y0)/height,label,location} : undefined;
    const changes = [...selection.before]
      .filter(([property, before]) => (property !== 'text' || textEditable) && before !== read(property))
      .map(([property, before]) => ({property, before,
        after: property === 'text' ? read(property) : node.style.getPropertyValue(property).slice(0, 160)}))
      .filter(change => change.before !== change.after);
    return JSON.stringify({selection: {id: selection.id, label, location, mark, tag: node.localName.slice(0, 80), textEditable, changes,
      viewport: JSON.stringify([scrollX, scrollY, left, top, width, height, viewport?.scale]),
      values: properties.map(read), edited: selection.before.size > 0}});
  })()`;
}

export function browserInspectorScript(command: BrowserInspectorCommand): string { return inspectorScript(JSON.stringify(command)); }

// Trusted code installed inside the opaque iframe; no eval or model-supplied scripts/selectors.
export function browserAutomationScript(): string {
  return `(() => {
    const observe = inputId => ${snapshotScript('inputId')};
    const act = inputAction => ${actionScript('inputAction', false)};
    const inspect = inputCommand => ${inspectorScript('inputCommand')};
    addEventListener('message', event => {
      const data = event.data;
      if (event.source !== parent || data?.channel !== 'tinybot-host' || data.type !== 'browserCommand') return;
      try {
        const args = JSON.parse(data.argumentsJson);
        if (data.operation === 'paint') {
          requestAnimationFrame(() => requestAnimationFrame(() => {
            parent.postMessage({channel:'tinybot-frame',type:'browserResult',id:data.id,message:'{}'}, '*');
          }));
        } else {
          const message = data.operation === 'snapshot' ? observe(args.snapshotId) :
            data.operation === 'inspect' ? inspect(args) : act(args);
          parent.postMessage({channel:'tinybot-frame',type:'browserResult',id:data.id,message}, '*');
        }
      } catch (error) {
        parent.postMessage({channel:'tinybot-frame',type:'browserResult',id:data.id,
          message:JSON.stringify({code:'BROWSER_ACTION_FAILED',message:String(error.message)})}, '*');
      }
    });
  })();`;
}
