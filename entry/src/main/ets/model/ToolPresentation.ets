import { t } from './I18n';

export interface ToolPreview { path: string; content: string; before: string; after: string; changed: boolean; truncated: boolean; }
interface PreviewData { path?: string; url?: string; content?: string; text?: string; oldText?: string; newText?: string;
  error?: string; truncated?: boolean; matches?: SearchPreview[]; entries?: Object[]; }
interface SearchPreview { path: string; line: number; text: string; }

export function prettyToolText(value: string): string {
  try { return JSON.stringify(JSON.parse(value), null, 2); } catch (_) { return value; }
}
function data(value: string): PreviewData {
  try { const parsed = JSON.parse(value) as PreviewData; return parsed && typeof parsed === 'object' ? parsed : {}; }
  catch (_) { return {}; }
}
export function toolPreview(name: string, argumentsText: string, output: string, status: string): ToolPreview {
  const args = data(argumentsText); const result = data(output);
  const preview: ToolPreview = { path: typeof args.path === 'string' ? args.path : typeof args.url === 'string' ? args.url : '',
    content: prettyToolText(output), before: '', after: '', changed: false, truncated: result.truncated === true };
  if (status !== 'complete') {
    if (typeof result.error === 'string') { preview.content = result.error; }
    return preview;
  }
  if (name === 'edit_file' && typeof args.oldText === 'string' && typeof args.newText === 'string') {
    preview.changed = true; preview.before = args.oldText; preview.after = args.newText;
  } else if (name === 'write_file' && typeof args.content === 'string') { preview.content = args.content; }
  else if (['read_file', 'read_file_lines', 'read_skill', 'read_web'].includes(name)) {
    if (typeof result.content === 'string') { preview.content = result.content; }
    else if (typeof result.text === 'string') { preview.content = result.text; }
  } else if (name === 'search_file_content' && Array.isArray(result.matches) && result.matches.every((item: SearchPreview) =>
    item && typeof item.path === 'string' && typeof item.line === 'number' && typeof item.text === 'string')) {
    preview.content = result.matches.map((item: SearchPreview) => item.path + ':' + item.line + '\n' + item.text).join('\n\n');
  }
  return preview;
}

function lineCount(value: string): number { return value.length ? value.split('\n').length : 0; }

// A glanceable result next to the tool name, so most rows never need opening.
export function toolStat(name: string, argumentsText: string, output: string, status: string): string {
  if (status !== 'complete') { return ''; }
  const args = data(argumentsText); const result = data(output);
  if (name === 'edit_file' && typeof args.oldText === 'string' && typeof args.newText === 'string') {
    return '+' + lineCount(args.newText) + ' −' + lineCount(args.oldText);
  }
  if (name === 'write_file' && typeof args.content === 'string') { return '+' + lineCount(args.content); }
  if ((name === 'read_file' || name === 'read_file_lines') && typeof result.content === 'string') {
    return t('{0} 行', [lineCount(result.content)]);
  }
  if (name === 'search_file_content' && Array.isArray(result.matches)) { return t('{0} 处匹配', [result.matches.length]); }
  if (name === 'list_files' && Array.isArray(result.entries)) { return t('{0} 项', [result.entries.length]); }
  return '';
}
