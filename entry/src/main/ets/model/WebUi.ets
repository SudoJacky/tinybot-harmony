// Versioned Web content embedded in a completed native UI surface.
export interface WebUiSpec { version: number; html: string; css: string; js: string; library: string; height: number; }
export interface WebUiMessage { type: string; id?: number; values?: Record<string, string | number | boolean>; message?: string; }
export function parseWebUi(source: string): WebUiSpec {
  if (source.length > 64000) { throw new Error('Web UI: content exceeds 64,000 characters'); }
  const spec = JSON.parse(source) as WebUiSpec;
  if (!spec || typeof spec !== 'object' || Array.isArray(spec) || Object.keys(spec).some((key) => !['version', 'html', 'css', 'js', 'library', 'height'].includes(key)) ||
    spec.version !== 1 || typeof spec.html !== 'string' || typeof spec.css !== 'string' || typeof spec.js !== 'string' ||
    !['none', 'three'].includes(spec.library) || !Number.isFinite(spec.height) || spec.height < 200 || spec.height > 800) {
    throw new Error('Web UI: expected version 1, html/css/js strings, library none/three and height 200..800');
  }
  return spec;
}
export function parseWebUiMessage(source: string): WebUiMessage {
  if (source.length > 18000) { throw new Error('Web UI: bridge message too large'); }
  const message = JSON.parse(source) as WebUiMessage;
  if (!message || typeof message !== 'object' || Array.isArray(message) || !['ready', 'error', 'save'].includes(message.type) ||
    Object.keys(message).some((key) => !['type', 'id', 'values', 'message'].includes(key))) { throw new Error('Web UI: invalid bridge message'); }
  if (message.type === 'save' && (!Number.isSafeInteger(message.id) || (message.id || 0) < 1 || !message.values || typeof message.values !== 'object' || Array.isArray(message.values))) {
    throw new Error('Web UI: invalid state save');
  }
  if (message.type === 'error' && (typeof message.message !== 'string' || message.message.length > 2000)) { throw new Error('Web UI: invalid error'); }
  return message;
}
export const WEB_UI_ORIGIN: string = 'https://tinybot-ui.invalid/';
// No generated markup is interpolated into this privileged host document.
export function webUiHost(runtime: string, library: string): string {
  const config = JSON.stringify({ library: library }).replace(/</g, '\\u003c');
  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; script-src &#39;unsafe-inline&#39;; style-src &#39;unsafe-inline&#39;; img-src data: blob:; frame-src about:; connect-src &#39;none&#39;; base-uri &#39;none&#39;; form-action &#39;none&#39;">' +
    '<style>html,body{margin:0;height:100%;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style></head><body>' +
    '<script id="vendor" type="application/json">' + config + '</script><script>' + runtime.replace(/<\/script/gi, '<\\/script') + '</script></body></html>';
}
