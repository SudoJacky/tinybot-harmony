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
    keywords: '模型设置 专用模型 模型能力 model capabilities', requiresEditable: true },
  { id: 'model-memory', section: 'models', group: '模型分工与能力', title: '记忆整理', route: 'model-settings',
    keywords: '长期记忆模型 memory model', requiresEditable: true },
  { id: 'model-title', section: 'models', group: '模型分工与能力', title: '会话起名', route: 'model-settings',
    keywords: '会话命名 对话命名 自动标题 title model conversation naming', requiresEditable: true },
  { id: 'model-team-worker', section: 'models', group: '模型分工与能力', title: '团队执行', route: 'model-settings',
    keywords: '子 Agent 团队模型 worker model', requiresEditable: true },
  { id: 'capability-images', section: 'models', group: '模型分工与能力', title: '支持图片输入', route: 'model-settings',
    keywords: '识图 视觉 多模态 vision image input', requiresEditable: true },
  { id: 'capability-usage', section: 'models', group: '模型分工与能力', title: '请求流式用量', route: 'model-settings',
    keywords: 'stream_options streaming token usage', requiresEditable: true },
  { id: 'capability-reasoning', section: 'models', group: '模型分工与能力', title: '推理强度', route: 'model-settings',
    keywords: '思考深度 reasoning effort thinking', requiresEditable: true },
  { id: 'capability-context', section: 'models', group: '模型分工与能力', title: '上下文窗口', route: 'model-settings',
    keywords: '上下文长度 context length context window', requiresEditable: true },
  { id: 'open-image-generation', section: 'models', title: '图片生成', route: 'image-generation',
    keywords: '生图 文生图 画图 图片模型 image_gen OpenAI Images Seedream Gemini DashScope', requiresEditable: true },
  { id: 'open-user-document', section: 'assistant', title: '称呼与回答偏好', route: 'user-document', keywords: '提示词 用户文档 prompt', requiresEditable: true },
  { id: 'save-summary', section: 'assistant', title: '自动保存任务结果', keywords: '归档 archive summaries' },
  { id: 'auto-memory', section: 'assistant', group: '记忆与上下文', title: '自动提取长期记忆', keywords: '自动记忆 auto memory' },
  { id: 'open-memory', section: 'assistant', group: '记忆与上下文', title: '管理长期记忆', route: 'productivity', param: 'memory', requiresEditable: true },
  { id: 'auto-compact', section: 'assistant', group: '记忆与上下文', title: '自动压缩历史', keywords: '上下文 摘要 compact summarize context' },
  { id: 'read-only', section: 'tools', title: '只读模式', keywords: '权限 read only' },
  { id: 'open-sandbox-management', section: 'tools', title: '沙盒管理', route: 'sandbox-management',
    keywords: 'Linux Runtime QEMU Alpine Python 自检 停止 任务超时 预热 内存 持久目录 挂载 sandbox mounts' },
  { id: 'web-enabled', section: 'tools', title: '允许网页读取与搜索', keywords: '网页权限 联网 web access' },
  { id: 'open-search-settings', section: 'tools', title: '搜索服务', route: 'search-settings',
    keywords: '联网搜索 DeepSeek Tavily SearXNG Bing 必应 web search', requiresEditable: true },
  { id: 'open-mail-settings', section: 'tools', title: '邮箱连接', route: 'mail-settings', keywords: '邮件 email IMAP' },
  { id: 'mail-add', section: 'tools', group: '邮箱连接', title: '添加邮箱连接', route: 'mail-settings',
    keywords: '邮箱账号 IMAP 授权码 邮件服务器 mail account' },
  { id: 'open-knowledge-base-settings', section: 'tools', title: '知识库', route: 'knowledge-base-settings',
    keywords: '资料源 启用知识库 knowledge sources' },
  { id: 'configure-ima-knowledge-base', section: 'tools', group: '知识库', title: '腾讯 ima 知识库', route: 'ima-settings',
    keywords: '腾讯知识库 Tencent IMA OpenAPI Client ID API Key' },
  { id: 'browser-enabled', section: 'tools', title: '应用内浏览器', keywords: '浏览器权限 接管 web browser' },
  { id: 'open-skills', section: 'tools', title: 'Skills', route: 'skills', keywords: '技能', requiresEditable: true },
  { id: 'open-mcp', section: 'tools', title: 'MCP 服务', route: 'productivity', param: 'mcp', keywords: '工具服务器 server', requiresEditable: true },
  { id: 'open-appearance', section: 'appearance', title: '界面与外观', route: 'appearance',
    keywords: '外观 个性化 appearance personalization' },
  { id: 'appearance-mode', section: 'appearance', group: '界面与外观', title: '明暗模式', route: 'appearance-choice', param: 'mode',
    keywords: '深色 浅色 暗色 夜间模式 黑暗模式 跟随系统 dark mode light mode' },
  { id: 'appearance-font', section: 'appearance', group: '界面与外观', title: '界面字体', route: 'appearance-choice', param: 'font',
    keywords: '字形 font typeface' },
  { id: 'appearance-font-size', section: 'appearance', group: '界面与外观', title: '字号', route: 'appearance',
    keywords: '字体大小 文字大小 font size text size' },
  { id: 'appearance-accent', section: 'appearance', group: '界面与外观', title: '主题色', route: 'appearance',
    keywords: '配色 强调色 accent color theme color' },
  { id: 'appearance-custom-color', section: 'appearance', group: '界面与外观', title: '自定义颜色', route: 'appearance-choice', param: 'custom',
    keywords: '自定义主题色 十六进制 hex custom accent' },
  { id: 'appearance-effect', section: 'appearance', group: '界面与外观', title: '光感效果', route: 'appearance-choice', param: 'effect',
    keywords: '光效 动效 动画 材质 通透 玻璃 motion animation material' },
  { id: 'appearance-reset', section: 'appearance', group: '界面与外观', title: '恢复默认外观', route: 'appearance',
    keywords: '重置主题 reset appearance' },
  { id: 'open-language', section: 'appearance', title: '语言', route: 'language', keywords: '中文 英文 language locale', requiresEditable: true },
  { id: 'new-chat-on-startup', section: 'appearance', title: '启动时打开',
    keywords: '冷启动 启动时新建空会话 上次会话 上次对话 恢复对话 startup last conversation new chat' },
  { id: 'open-usage', section: 'data', title: 'Token 用量', route: 'usage', keywords: '统计 账单 tokens usage' },
  { id: 'open-storage', section: 'data', title: '存储空间', route: 'storage', keywords: '缓存 清理 cache storage space', requiresEditable: true },
  { id: 'open-backup', section: 'data', title: '备份与恢复', route: 'backup', keywords: '数据迁移 backup restore', requiresEditable: true },
  { id: 'webdav-backup-settings', section: 'data', group: '备份与恢复', title: 'WebDAV', route: 'webdav-backup',
    keywords: '第三方备份位置 第三方云备份 网盘备份 服务器地址 WebDAV backup', requiresEditable: true },
  { id: 'cloud-backup', section: 'data', group: '备份与恢复', title: '华为云空间', route: 'backup',
    keywords: '云备份 云端恢复 自动备份 Huawei Cloud backup', requiresEditable: true },
  { id: 'export-local-backup', section: 'data', group: '备份与恢复', title: '导出完整备份', route: 'backup',
    keywords: '本地备份 导出数据 export local backup', requiresEditable: true },
  { id: 'import-local-backup', section: 'data', group: '备份与恢复', title: '从备份导入', route: 'backup',
    keywords: '本地恢复 导入数据 数据导入 import local backup', requiresEditable: true },
  { id: 'device-sync-send', section: 'data', group: '备份与恢复', title: '发送到其他设备', route: 'backup',
    keywords: '设备迁移 设备同步 附近传输 device transfer sync', requiresEditable: true },
  { id: 'open-help', section: 'help', title: '使用帮助', route: 'support', param: 'help', keywords: '教程 guide' },
  { id: 'open-rating', section: 'help', title: '评分和评论', route: 'support', param: 'rating', keywords: '评价 review rating' },
  { id: 'open-about', section: 'help', title: '关于 Tinybot', route: 'support', param: 'about', keywords: '版本 version about GitHub' },
  { id: 'about-diagnostic-logs', section: 'help', group: '关于 Tinybot', title: '诊断日志', route: 'support', param: 'about',
    keywords: '导出诊断日志 调试 采集 脱敏 diagnostics debug log export' },
  { id: 'open-release-notes', section: 'help', group: '关于 Tinybot', title: '更新说明', route: 'support', param: 'updates',
    keywords: '更新日志 release notes changelog' },
  { id: 'about-feedback', section: 'help', group: '关于 Tinybot', title: '反馈与建议', route: 'support', param: 'feedback',
    keywords: '报告问题 bug feedback' },
  { id: 'open-startup-guide', section: 'help', group: '使用帮助', title: '首次使用指引', route: 'support', param: 'guide',
    keywords: '新手引导 onboarding tutorial' },
  { id: 'user-agreement', section: 'help', group: '协议与政策', title: '用户协议', route: 'support', param: 'terms',
    keywords: '服务条款 terms of use' },
  { id: 'privacy-policy', section: 'help', group: '协议与政策', title: '隐私政策', route: 'support', param: 'privacy',
    keywords: '隐私声明 数据保护 privacy policy' },
  { id: 'open-third-party-licenses', section: 'help', group: '协议与政策', title: '第三方开源许可协议', route: 'support', param: 'licenses',
    keywords: '许可证 软件许可 third party licenses OSS' },
  { id: 'open-developer', section: 'help', title: '开发者模式', route: 'support', param: 'developer', keywords: '诊断日志 性能 diagnostics performance' }
];

interface SearchMatch { item: SettingsSearchItem; rank: number; }

function searchable(text: string): string {
  return text.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function searchTerms(text: string): string[] {
  return text.match(/[a-z0-9]+|[\u3400-\u9fff]+|[^\x00-\x7f\u3400-\u9fff]+/g) || [];
}

function oneLatinTypo(term: string, candidate: string): boolean {
  if (!/^[a-z][a-z0-9]{3,}$/.test(term) || !/^[a-z][a-z0-9]{2,}$/.test(candidate) ||
    Math.abs(term.length - candidate.length) > 1) { return false; }
  const shorter = term.length <= candidate.length ? term : candidate;
  const longer = term.length <= candidate.length ? candidate : term;
  let index = 0;
  while (index < shorter.length && shorter[index] === longer[index]) { index++; }
  if (shorter.length !== longer.length) { return shorter.slice(index) === longer.slice(index + 1); }
  return shorter.slice(index + 1) === longer.slice(index + 1) ||
    (shorter[index] === longer[index + 1] && shorter[index + 1] === longer[index] &&
      shorter.slice(index + 2) === longer.slice(index + 2));
}

function nearChinese(term: string, candidate: string): boolean {
  if (!/^[\u3400-\u9fff]{2,}$/.test(term)) { return false; }
  for (let start = candidate.indexOf(term[0]); start >= 0; start = candidate.indexOf(term[0], start + 1)) {
    let end = start;
    for (let index = 1; index < term.length && end >= 0; index++) { end = candidate.indexOf(term[index], end + 1); }
    if (end >= 0 && end - start + 1 <= term.length + 2) { return true; }
  }
  return false;
}

export function findSettings(query: string, profiles: ProviderProfile[], developerEnabled: boolean): SettingsSearchItem[] {
  const phrase = searchable(query);
  const words = searchTerms(phrase);
  if (words.length === 0) { return []; }
  const entries = ITEMS.filter((item) => item.id !== 'open-developer' || developerEnabled);
  for (const profile of profiles) {
    entries.push({ id: 'edit-provider-' + profile.id, title: profile.name, section: 'models', route: 'provider',
      param: profile.id, keywords: [profile.presetId || '', profile.protocol].concat(profile.models || []).join(' '), requiresEditable: true });
  }
  const matches: SearchMatch[] = [];
  for (const item of entries) {
    const titles = [item.title, item.route === 'provider' ? item.title : EN_MESSAGES[item.title] || item.title].map(searchable);
    const group = item.group || '';
    const section = SECTION_TITLES[item.section];
    const keywords = searchable(item.keywords || '');
    const titleText = titles.join(' ');
    const text = titleText + ' ' + keywords + ' ' + searchable([section, EN_MESSAGES[section], group, EN_MESSAGES[group]].join(' '));
    let rank = titles.includes(phrase) ? 0 : titles.some((title) => title.startsWith(phrase)) ? 1 :
      words.every((word) => titleText.includes(word)) ? 2 : keywords.includes(phrase) ? 3 :
      words.every((word) => text.includes(word)) ? 4 : 5;
    if (rank === 5) {
      const candidates = searchTerms(text);
      if (!words.every((word) => text.includes(word) || candidates.some((candidate) =>
        oneLatinTypo(word, candidate) || nearChinese(word, candidate)))) { continue; }
    }
    matches.push({ item: item, rank: rank });
  }
  return matches.sort((a, b) => a.rank - b.rank).map((match) => match.item);
}
