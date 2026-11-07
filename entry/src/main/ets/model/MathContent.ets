import { MarkdownSpan, markdownSpans } from './Markdown';

export function hasMath(text: string): boolean {
  return (text.includes('$') || text.includes('\\(')) && markdownSpans(text).some((span: MarkdownSpan) => span.kind === 'math');
}
export interface MathContent {
  revision: number; spans: MarkdownSpan[]; display: boolean; size: number; bold: boolean;
  color: string; accent: string; selectable: boolean;
}
export function mathHost(script: string, css: string, host: string): string {
  return '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; font-src data:;">' +
    '<style>' + css + '\nhtml,body{margin:0;background:transparent;font-family:system-ui,sans-serif}#content{line-height:1.62;overflow-wrap:anywhere;white-space:pre-wrap;padding:2px 0}' +
    '.formula{display:inline-block;max-width:100%;overflow-x:auto;overflow-y:hidden;vertical-align:middle;white-space:normal;padding:2px 0}' +
    '.display{display:block}.katex-display{margin:4px 0}.code{font-family:monospace;padding:1px 3px;background:rgba(127,127,127,.12);border-radius:4px}a{text-decoration:underline}</style>' +
    '</head><body><div id="content"></div><script>' + script + '</script><script>' + host + '</script></body></html>';
}
