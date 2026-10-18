import { t } from './I18n';
import { FileDiff } from './FileDiff';

export function toolTitle(name: string): string {
  const titles: Record<string, string> = {
    'browser_open': t('打开浏览器'), 'browser_snapshot': t('读取浏览器页面'), 'browser_action': t('操作浏览器'),
    'browser_handoff': t('请你接管浏览器'), 'browser_close': t('关闭浏览器'),
    'search_web': t('联网搜索'), 'present_files': t('交付文件'), 'publish_preview': t('发布预览'), 'read_reference': t('补读会话引用'),
    'team_recruit': t('招募员工'), 'team_wait': t('等待员工交接'), 'team_inspect': t('查看团队'), 'team_read_result': t('读取交接结果'),
    'team_control': t('调整团队执行'), 'team_resume': t('继续团队'), 'team_complete_task': t('提交交接'),
    'team_list_messages': t('查看团队交接'), 'team_read_message': t('读取交接'),
    'read_web': t('读取网页'), 'read_skill': t('读取 Skill'), 'list_files': t('列出文件'), 'read_file': t('读取文件'),
    'find_files': t('查找文件'), 'read_file_lines': t('读取文件片段'), 'read_attachment': t('读取附件'), 'search_file_content': t('搜索文件内容'),
    'write_file': t('写入文件'), 'edit_file': t('编辑文件'), 'generate_image': t('生成图片'),
    'tool_search': t('查找可用工具'), 'mcp_call': t('调用远程工具'), 'mcp_list_tools': t('查看远程工具'), 'mcp_search_tools': t('搜索远程工具'),
    'execute_code': t('执行代码'), 'orchestrate': t('编排工具'), 'publish_data_view': t('生成图表'),
    'update_plan': t('更新计划'), 'request_user_input': t('请你补充信息'),
    'list_skills': t('查看 Skills'), 'skill_manage': t('管理 Skills'), 'mcp_manage': t('管理 MCP 服务'),
    'memory': t('维护长期记忆'), 'read_tool_result': t('补读工具结果')
  };
  return titles[name] || name;
}

export function toolGroupTitle(id: string): string {
  const titles: Record<string, string> = {
    'workspace-read': t('文件读取与检索'), 'workspace-write': t('文件编辑'), 'context-read': t('附件与历史结果'),
    'web': t('网页读取与搜索'), 'browser': t('浏览器'), 'calculation': t('代码计算'), 'orchestration': t('工具编排'),
    'interaction': t('用户交互与计划'), 'delivery': t('预览与交付'), 'image': t('图片生成'), 'skill-read': t('Skills 读取'),
    'mcp-discovery': t('MCP 工具发现'), 'mcp-execution': t('MCP 工具调用'), 'extension-management': t('扩展管理'),
    'memory': t('长期记忆'), 'team-coordination': t('团队管理'), 'team-handoff': t('员工交接'),
    'research': t('资料与检索'), 'execution': t('执行与协作'), 'extensions': t('MCP 服务'),
    'user-input': t('信息确认'), 'plan': t('任务计划'), 'team': t('团队协作'), 'preview': t('预览与图表'),
    'file-delivery': t('文件交付'), 'skill-manage': t('Skills 管理'), 'mcp': t('MCP 远程工具'), 'mcp-manage': t('MCP 服务管理')
  };
  return titles[id] || id;
}

export function toolCapabilityDescription(id: string): string {
  const descriptions: Record<string, string> = {
    'context-read': t('读取附件、会话引用和历史工具结果'), 'web': t('搜索互联网并读取网页内容'),
    'browser': t('打开网页、查看页面、操作与接管浏览器'), 'calculation': t('在代码沙箱中计算和处理数据'),
    'orchestration': t('通过代码组合调用已授权工具'), 'user-input': t('通过表单向你确认信息'),
    'plan': t('创建和更新任务步骤'), 'team': t('招募、管理团队并完成员工交接'),
    'preview': t('发布交互预览、图表和数据表格'), 'file-delivery': t('展示可预览、分享和导出的文件'),
    'image': t('生成或编辑图片，需配置图片模型'), 'skill-read': t('查看 Skills 目录并读取使用说明'),
    'skill-manage': t('安装、更新和管理 Skills'), 'mcp': t('发现并调用已配置的远程工具'),
    'mcp-manage': t('配置和管理 MCP 服务'), 'memory': t('维护长期记忆和自动记忆整理')
  };
  return descriptions[id] || '';
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

export function toolFavicon(name: string, icon: string | undefined, status: string, webEnabled: boolean): string {
  if (name !== 'read_web' || status !== 'complete' || !webEnabled) { return ''; }
  // Historical receipts without icon metadata keep their generic icon; never re-read a page for decoration.
  if (typeof icon !== 'string' || icon.length > 4096 || /[\s\u0000-\u001f\\]/.test(icon)) { return ''; }
  const match = /^https?:\/\/([^/?#]+)(?:[/?#]|$)/i.exec(icon);
  return match && !match[1].includes('@') ? icon : '';
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
export function toolStat(name: string, argumentsText: string, output: string, status: string, diff?: FileDiff): string {
  if (status !== 'complete') { return ''; }
  if (diff && ['edit_file', 'write_file'].includes(name)) { return '+' + diff.added + ' −' + diff.removed; }
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
