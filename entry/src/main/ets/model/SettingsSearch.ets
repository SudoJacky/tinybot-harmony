import { t } from './I18n';
import { EN_MESSAGES } from './LocaleCatalog';
import { ProviderProfile } from './ProviderProfiles';

const SECTION_TITLES: Record<string, string> = {
  'account': '账号', 'models': '模型与服务', 'assistant': '助手偏好', 'tools': '工具与权限',
  'appearance': '界面与语言', 'data': '数据与用量', 'help': '帮助与关于'
};

export function settingsSectionTitle(section: string): string { return t(SECTION_TITLES[section] || '设置'); }

export interface SettingsSearchItem {
  id: string;
  section: string;
  title: string;
  group?: string;
  route?: string;
  param?: string;
  keywords?: string;
  requiresEditable?: boolean;
}

// A result without a route locates its switch on the settings page.
const ITEMS: SettingsSearchItem[] = [
  { id: 'open-huawei-account', section: 'account', title: '华为账号', route: 'account', keywords: '账户 登录 logout sign in' },
  { id: 'add-provider', section: 'models', title: '添加模型服务', route: 'provider-presets', keywords: 'provider API Key 自定义服务', requiresEditable: true },
  { id: 'open-model-settings', section: 'models', title: '模型分工与能力', route: 'model-settings',
    keywords: '记忆整理 会话起名 团队执行 推理强度 上下文窗口 支持图片输入 reasoning context window vision', requiresEditable: true },
  { id: 'open-image-generation', section: 'models', title: '图片生成', route: 'image-generation',
    keywords: '生图 文生图 画图 图片模型 image_gen OpenAI Images Seedream Gemini DashScope', requiresEditable: true },
  { id: 'open-user-document', section: 'assistant', title: '称呼与回答偏好', route: 'user-document', keywords: '提示词 用户文档 prompt', requiresEditable: true },
  { id: 'save-summary', section: 'assistant', title: '自动保存任务结果', keywords: '归档 archive summaries' },
  { id: 'auto-memory', section: 'assistant', group: '记忆与上下文', title: '自动提取长期记忆', keywords: '自动记忆 auto memory' },
  { id: 'open-memory', section: 'assistant', group: '记忆与上下文', title: '管理长期记忆', route: 'productivity', param: 'memory', requiresEditable: true },
  { id: 'auto-compact', section: 'assistant', group: '记忆与上下文', title: '自动压缩历史', keywords: '上下文 摘要 compact summarize context' },
  { id: 'read-only', section: 'tools', title: '只读模式', keywords: '权限 read only' },
  { id: 'web-enabled', section: 'tools', title: '允许网页读取与搜索', keywords: '网页权限 联网 web access' },
  { id: 'open-search-settings', section: 'tools', title: '搜索服务', route: 'search-settings',
    keywords: '联网搜索 DeepSeek Tavily SearXNG Bing 必应 web search', requiresEditable: true },
  { id: 'open-mail-settings', section: 'tools', title: '邮箱连接', route: 'mail-settings', keywords: '邮件 email IMAP' },
  { id: 'browser-enabled', section: 'tools', title: '应用内浏览器', keywords: '浏览器权限 接管 web browser' },
  { id: 'open-skills', section: 'tools', title: 'Skills', route: 'skills', keywords: '技能', requiresEditable: true },
  { id: 'open-mcp', section: 'tools', title: 'MCP 服务', route: 'productivity', param: 'mcp', keywords: '工具服务器 server', requiresEditable: true },
  { id: 'open-appearance', section: 'appearance', title: '界面与外观', route: 'appearance',
    keywords: '主题 深色 浅色 字体 颜色 动效 theme dark mode font color animation' },
  { id: 'open-language', section: 'appearance', title: '语言', route: 'language', keywords: '中文 英文 language locale', requiresEditable: true },
  { id: 'open-usage', section: 'data', title: 'Token 用量', route: 'usage', keywords: '统计 账单 tokens usage' },
  { id: 'open-storage', section: 'data', title: '存储空间', route: 'storage', keywords: '缓存 清理 cache storage space', requiresEditable: true },
  { id: 'open-backup', section: 'data', title: '备份与恢复', route: 'backup', keywords: '导入 导出 云备份 WebDAV import export cloud', requiresEditable: true },
  { id: 'open-help', section: 'help', title: '使用帮助', route: 'support', param: 'help', keywords: '教程 guide' },
  { id: 'open-rating', section: 'help', title: '评分和评论', route: 'support', param: 'rating', keywords: '评价 review rating' },
  { id: 'open-about', section: 'help', title: '关于 Tinybot', route: 'support', param: 'about', keywords: '版本 隐私 用户协议 version privacy' },
  { id: 'open-developer', section: 'help', title: '开发者模式', route: 'support', param: 'developer', keywords: '诊断日志 性能 diagnostics performance' }
];

interface SearchMatch { item: SettingsSearchItem; rank: number; }

function searchable(text: string): string { return text.normalize('NFKC').trim().toLowerCase(); }

export function findSettings(query: string, profiles: ProviderProfile[], developerEnabled: boolean): SettingsSearchItem[] {
  const phrase = searchable(query).replace(/\s+/g, ' ');
  if (!phrase) { return []; }
  const words = phrase.split(' ');
  const entries = ITEMS.filter((item) => item.id !== 'open-developer' || developerEnabled);
  for (const profile of profiles) {
    entries.push({ id: 'edit-provider-' + profile.id, title: profile.name, section: 'models', route: 'provider',
      param: profile.id, keywords: (profile.presetId || '') + ' ' + profile.protocol, requiresEditable: true });
  }
  const matches: SearchMatch[] = [];
  for (const item of entries) {
    const titles = [item.title, item.route === 'provider' ? item.title : EN_MESSAGES[item.title] || item.title].map(searchable);
    const group = item.group || SECTION_TITLES[item.section];
    const text = titles.join(' ') + ' ' + searchable(group + ' ' + (EN_MESSAGES[group] || '') + ' ' + (item.keywords || ''));
    if (!words.every((word) => text.includes(word))) { continue; }
    const rank = titles.includes(phrase) ? 0 : titles.some((title) => title.startsWith(phrase)) ? 1 :
      words.every((word) => titles.some((title) => title.includes(word))) ? 2 : 3;
    matches.push({ item: item, rank: rank });
  }
  return matches.sort((a, b) => a.rank - b.rank).map((match) => match.item);
}
