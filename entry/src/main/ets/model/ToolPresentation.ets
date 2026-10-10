import { t } from './I18n';

export function toolTitle(name: string): string {
  const titles: Record<string, string> = {
    'team_recruit': t('招募员工'), 'team_wait': t('等待员工交接'), 'team_inspect': t('查看团队'), 'team_read_result': t('读取交接结果'),
    'team_control': t('调整团队执行'), 'team_resume': t('继续团队'), 'team_complete_task': t('提交交接'),
    'team_list_messages': t('查看团队交接'), 'team_read_message': t('读取交接'),
    'read_web': t('读取网页'), 'read_skill': t('读取 Skill'), 'list_files': t('列出文件'), 'read_file': t('读取文件'),
    'read_file_lines': t('读取文件片段'), 'read_attachment': t('读取附件'), 'search_file_content': t('搜索文件内容'),
    'write_file': t('写入文件'), 'edit_file': t('编辑文件'), 'generate_image': t('生成图片'),
    'mcp_call': t('调用远程工具'), 'mcp_list_tools': t('查看远程工具'), 'mcp_search_tools': t('搜索远程工具'),
    'execute_code': t('执行代码'), 'orchestrate': t('编排工具'), 'publish_data_view': t('生成图表'),
    'update_plan': t('更新计划'), 'request_user_input': t('请你补充信息')
  };
  return titles[name] || name;
}

export function toolStatusLabel(status: string): string {
  switch (status) {
    case 'pending': return t('等待中');
    case 'running': return t('执行中');
    case 'complete': return t('完成');
    case 'failed': return t('失败');
    case 'cancelled': return t('已取消');
    default: return t('已中断');
  }
}

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
  else if (['read_file', 'read_file_lines', 'read_attachment', 'read_skill', 'read_web'].includes(name)) {
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
  if (['read_file', 'read_file_lines', 'read_attachment'].includes(name) && typeof result.content === 'string') {
    return t('{0} 行', [lineCount(result.content)]);
  }
  if (name === 'search_file_content' && Array.isArray(result.matches)) { return t('{0} 处匹配', [result.matches.length]); }
  if (name === 'list_files' && Array.isArray(result.entries)) { return t('{0} 项', [result.entries.length]); }
  return '';
}
