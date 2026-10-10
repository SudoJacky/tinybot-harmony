import { t } from './I18n';
import { prettyToolText, toolPreview } from './ToolPresentation';
import { Attachment, validateAttachments } from './Productivity';

export interface DetailRow { label: string; value: string; }
export interface DetailSection { title: string; body: string; style: string; rows: DetailRow[]; }
export interface ToolDetailContent {
  path: string;
  summary: string;
  sections: DetailSection[];
  logs: DetailSection[];
  inputs: DetailSection[];
  notices: string[];
  image?: Attachment;
}

export function compactDetailValue(value: string): string {
  try { return JSON.stringify(JSON.parse(value)); } catch (_) { return value; }
}

function record(value: Object | undefined | null): Record<string, Object> {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : {};
}
function parse(value: string): Object | null {
  try { return JSON.parse(value) as Object; } catch (_) { return null; }
}
function str(value: Object | undefined): string { return typeof value === 'string' ? value as string : ''; }
function numeric(value: Object | undefined): number { return typeof value === 'number' ? value as number : 0; }
function show(value: Object | undefined | null): string {
  if (value === undefined) { return ''; }
  return typeof value === 'string' ? value as string : JSON.stringify(value, null, 2);
}
function section(title: string, body: string, style: string = 'text', rows: DetailRow[] = []): DetailSection {
  return { title: title, body: body, style: style, rows: rows };
}
function fields(value: Object | null, title: string): DetailSection[] {
  const obj = record(value);
  if (Object.keys(obj).length > 0) {
    return [section(title, '', 'list', Object.keys(obj).map((key: string): DetailRow => ({ label: key, value: show(obj[key]) })))];
  }
  return [section(title, show(value), typeof value === 'string' ? 'text' : 'code')];
}
function numbered(content: string, start: number, column: number): string {
  return content.split('\n').map((line: string, index: number) =>
    (start + index) + (index === 0 && column > 1 ? ':' + column : '') + '  ' + line).join('\n');
}

function imageAttachment(value: Object | undefined): Attachment | undefined {
  if (!value) { return undefined; }
  const attachment = value as Attachment;
  try { validateAttachments([attachment]); } catch (_) { return undefined; }
  return attachment.mime === 'image/jpeg' ? attachment : undefined;
}

// Project the recorded receipt only. Opening a detail never reads files or executes tools.
export function toolDetailContent(name: string, argumentsText: string, output: string, status: string): ToolDetailContent {
  const args = record(parse(argumentsText)); const parsed = parse(output); const result = record(parsed);
  const preview = toolPreview(name, argumentsText, output, status);
  const content: ToolDetailContent = { path: str(result.path) || str(result.name) || preview.path,
    summary: '', sections: [], logs: [], inputs: fields(parse(argumentsText), t('参数')), notices: [] };
  // Unparseable historical arguments must remain readable too.
  if (parse(argumentsText) === null && argumentsText !== 'null') { content.inputs = [section(t('参数'), argumentsText, 'code')]; }
  if (['request_user_input', 'update_plan', 'publish_data_view'].includes(name) && typeof args.data === 'string') {
    content.inputs = fields(parse(str(args.data)), t('参数'));
  }
  if (result.truncated === true) { content.notices.push(t('工具仅返回了部分内容')); }
  if (numeric(result.nextOffset) > 0) {
    content.notices.push(t('工具返回的续读位置：第 {0} 行，第 {1} 列', [numeric(result.nextOffset), numeric(result.nextColumn) || 1]));
  }
  if (status === 'pending' || status === 'running') {
    content.summary = status === 'pending' ? t('等待中') : t('执行中');
  }
  if (status === 'cancelled' || status === 'interrupted') {
    content.notices.push(status === 'cancelled' ? t('已取消') : t('已中断'));
  }
  if (name === 'execute_code' || name === 'orchestrate') {
    content.path = '';
    if (numeric(result.durationMs) > 0) { content.summary = numeric(result.durationMs) + ' ms'; }
    if (result.error !== undefined && result.error !== null && result.error !== '') {
      content.sections.push(section(t('错误'), show(result.error), 'error'));
    }
    if (result.result !== undefined) { content.sections = content.sections.concat(fields(result.result, t('返回值'))); }
    if (Array.isArray(result.calls)) {
      const calls = result.calls as Object[];
      const failed = calls.filter((call: Object) => str(record(call).status) === 'failed').length;
      content.summary += (content.summary ? ' · ' : '') + t('{0} 次工具调用', [calls.length]) +
        (failed ? ' · ' + t('{0} 次失败', [failed]) : '');
    }
    if (str(result.stdout)) { content.logs.push(section('stdout', str(result.stdout), 'code')); }
    if (str(result.stderr)) { content.logs.push(section('stderr', str(result.stderr), 'code')); }
    if (result.logsTruncated === true) { content.notices.push(t('执行日志已被工具截断')); }
    if (result.resultTruncated === true) { content.notices.push(t('返回值已被工具截断')); }
    if (str(args.code)) { content.inputs = [section(t('代码'), str(args.code), 'code')]; }
    if (args.input !== undefined) { content.inputs.push(section(t('输入'), prettyToolText(show(args.input)), 'code')); }
    if (!content.sections.length && content.logs.length) { content.sections.push(section(t('结果'), t('执行输出见日志'))); }
  } else if (status === 'complete' && name === 'generate_image') {
    content.image = imageAttachment(result.attachment);
    if (content.image) {
      content.sections = [section(content.image.name, content.image.mime + ' · ' + content.image.size + ' B')];
    }
  } else if (status === 'complete' && name === 'publish_data_view' && typeof result.title === 'string') {
    content.sections = [section(str(result.title), str(result.insight)), section(t('来源'), str(result.source))];
  } else if (status === 'complete' && name === 'edit_file' && preview.changed) {
    content.summary = t('已完成替换');
    content.sections = [section(t('替换前'), preview.before || t('空文本'), 'removed'),
      section(t('替换后'), preview.after || t('空文本'), 'added')];
  } else if (status === 'complete' && name === 'write_file' && typeof args.content === 'string') {
    content.summary = numeric(result.bytes) + ' B';
    content.sections = [section(t('写入内容'), numbered(str(args.content), 1, 1), 'code')];
  } else if (status === 'complete' && ['read_file', 'read_file_lines', 'read_attachment', 'read_skill'].includes(name) &&
    (typeof result.content === 'string' || typeof result.text === 'string')) {
    const start = numeric(result.startLine) || numeric(args.startLine) || numeric(args.offset) || 1;
    content.summary = numeric(result.totalLines) ? t('从第 {0} 行起 · 共 {1} 行', [start, numeric(result.totalLines)]) : '';
    content.sections = [section(t('读取内容'), numbered(preview.content, start, numeric(args.column) || 1), 'code')];
  } else if (status === 'complete' && name === 'search_file_content' && Array.isArray(result.matches)) {
    const matches = result.matches as Object[];
    if (matches.every((item: Object) => typeof record(item).path === 'string' && typeof record(item).line === 'number' && typeof record(item).text === 'string')) {
      content.summary = t('{0} 处匹配', [matches.length]);
      const paths: string[] = [];
      const groups = new Map<string, DetailRow[]>();
      for (const item of matches) {
        const match = record(item); const path = str(match.path);
        if (!groups.has(path)) { paths.push(path); groups.set(path, []); }
        groups.get(path)?.push({ label: t('第 {0} 行', [numeric(match.line)]), value: str(match.text) });
      }
      content.sections = paths.map((path: string) => section(path, '', 'list', groups.get(path) || []));
      if (!matches.length) { content.sections = [section(t('结果'), t('没有匹配项'))]; }
      if (Array.isArray(result.skipped) && result.skipped.length) { content.notices.push(t('跳过的文件') + ': ' + show(result.skipped)); }
    }
  } else if (status === 'complete' && name === 'list_files' && Array.isArray(result.entries)) {
    const entries = result.entries as Object[];
    if (entries.every((item: Object) => typeof record(item).name === 'string' && typeof record(item).kind === 'string')) {
      content.summary = t('{0} 项', [entries.length]);
      content.sections = [section(t('目录内容'), entries.length ? '' : t('空目录'), 'list', entries.map((item: Object): DetailRow => {
        const entry = record(item);
        return { label: str(entry.name), value: entry.kind === 'directory' ? t('文件夹') : entry.kind === 'symlink' ? t('符号链接') : t('文件') };
      }))];
    }
  } else if (status === 'complete' && name === 'read_web' && typeof result.content === 'string') {
    content.path = str(result.url) || str(args.url);
    content.sections = [section(str(result.title) || t('网页正文'), str(result.content))];
    if (Array.isArray(result.links)) {
      const links = (result.links as Object[]).filter((item: Object) => typeof record(item).url === 'string');
      if (links.length) { content.sections.push(section(t('页面链接'), '', 'list', links.map((item: Object): DetailRow =>
        ({ label: str(record(item).title) || str(record(item).url), value: str(record(item).url) })))); }
    }
    if (result.linksTruncated === true) { content.notices.push(t('页面链接已被工具截断')); }
  } else if (status === 'complete' && name === 'update_plan' && Array.isArray(result.steps)) {
    const steps = result.steps as Object[];
    if (steps.every((item: Object) => typeof record(item).step === 'string' && ['pending', 'in_progress', 'completed'].includes(str(record(item).status)))) {
      content.sections = [section(t('计划'), str(result.explanation), 'list', steps.map((item: Object): DetailRow => {
        const step = record(item);
        return { label: step.status === 'completed' ? '✓ ' + t('完成') : step.status === 'in_progress' ? '◉ ' + t('执行中') : '○ ' + t('等待中'), value: str(step.step) };
      }))];
    }
  } else if (name === 'request_user_input' && status === 'complete') {
    const form = record(parse(str(args.data)));
    const values = record(result.values);
    if (result.status === 'submitted' && Array.isArray(form.fields) && Object.keys(values).length > 0) {
      content.sections = [section(str(form.title) || t('已提交的回答'), '', 'list', Object.keys(values).map((key: string): DetailRow => {
        const field = (form.fields as Object[]).find((item: Object) => record(item).name === key);
        return { label: field ? str(record(field).label) || key : key, value: show(values[key]) };
      }))];
    }
  } else if (name === 'mcp_call' && Array.isArray(result.content)) {
    for (const item of result.content as Object[]) {
      const block = record(item);
      if (block.type === 'text' && typeof block.text === 'string') { content.sections.push(section(t('结果'), str(block.text))); }
      else {
        // Binary content remains available in the raw receipt, never as a giant base64 paragraph.
        content.sections.push(section(str(block.type) || t('结果'), str(block.mimeType) || show(block.resource) || str(block.uri)));
      }
    }
    if (result.structuredContent !== undefined) { content.sections = content.sections.concat(fields(result.structuredContent, t('结构化结果'))); }
  }
  if (!content.sections.length) {
    if (!output) { content.sections = [section(t('结果'), content.summary || t('暂无返回内容'))]; }
    else if (status === 'failed') { content.sections = [section(t('错误'), result.error !== undefined ? show(result.error) : prettyToolText(output), 'error')]; }
    else { content.sections = parsed !== null || output.trim() === 'null' ? fields(parsed, t('结果')) : [section(t('结果'), output)]; }
  }
  return content;
}

// A page contains bounded text/rows. Paging changes presentation only, never the stored receipt.
export function detailPages(sections: DetailSection[], size: number = 8000): DetailSection[] {
  const pages: DetailSection[] = [];
  for (const item of sections) {
    const chunks: string[] = [];
    for (let offset = 0; offset < item.body.length;) {
      let end = Math.min(offset + size, item.body.length);
      const unit = item.body.charCodeAt(end - 1);
      if (end < item.body.length && unit >= 0xD800 && unit <= 0xDBFF) { end--; }
      chunks.push(item.body.slice(offset, end)); offset = end;
    }
    for (const chunk of chunks) { pages.push(section(item.title, chunk, item.style)); }
    let rows: DetailRow[] = []; let length = 0;
    for (const row of item.rows) {
      const rowPages = detailPages([section(row.label, row.value, 'text')], size);
      if (!rowPages.length) { rowPages.push(section(row.label, '')); }
      for (const page of rowPages) {
        if (rows.length && (rows.length >= 30 || length + page.body.length + row.label.length > size)) {
          pages.push(section(item.title, '', item.style, rows)); rows = []; length = 0;
        }
        rows.push({ label: row.label, value: page.body }); length += page.body.length + row.label.length;
      }
    }
    if (rows.length) { pages.push(section(item.title, '', item.style, rows)); }
    if (!item.body && !item.rows.length) { pages.push(item); }
  }
  return pages;
}
