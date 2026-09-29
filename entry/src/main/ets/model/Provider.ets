export const DEFAULT_PROVIDER_ID: string = 'deepseek';
export const LEGACY_PROVIDER_ID: string = 'openai-compatible';

export interface ProviderInfo {
  id: string;
  name: string;
  protocol: string;
  defaultBaseUrl: string;
  defaultModel: string;
  models?: string[];
  description?: string;
  endpointPlaceholder?: string;
  noApiKey?: boolean;
}

export function copyProviderInfo(info: ProviderInfo): ProviderInfo {
  return { id: info.id, name: info.name, protocol: info.protocol,
    defaultBaseUrl: info.defaultBaseUrl, defaultModel: info.defaultModel,
    models: info.models?.slice(), description: info.description,
    endpointPlaceholder: info.endpointPlaceholder, noApiKey: info.noApiKey };
}

// Keep IDs, endpoints and curated models aligned with Tinybot's built-in presets.
export function builtinProviderInfos(): ProviderInfo[] {
  return [
    { id: DEFAULT_PROVIDER_ID, name: 'DeepSeek', protocol: 'chat-completions',
      defaultBaseUrl: 'https://api.deepseek.com', defaultModel: 'deepseek-flash',
      models: ['deepseek-flash', 'deepseek-v4-pro'] },
    { id: 'dashscope', name: 'DashScope · 阿里云百炼', protocol: 'chat-completions',
      defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', defaultModel: 'qwen-plus',
      models: ['qwen-plus', 'qwen-max', 'qwen-turbo'],
      description: '默认连接北京地域；其他地域或 Coding Plan 请填写对应的服务地址和密钥。' },
    { id: 'openai', name: 'OpenAI', protocol: 'chat-completions',
      defaultBaseUrl: 'https://api.openai.com/v1', defaultModel: 'gpt-4.1', models: ['gpt-4.1'] },
    { id: 'zai', name: 'Z.ai · 智谱', protocol: 'chat-completions',
      defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4', defaultModel: 'glm-5.3',
      models: ['glm-5.3', 'glm-5.3-flash', 'glm-5.2'],
      description: '默认连接智谱通用 API；国际站或 Coding Plan 请填写对应的服务地址和密钥。' },
    { id: 'ollama', name: 'Ollama', protocol: 'chat-completions', defaultBaseUrl: '', defaultModel: '', models: [],
      noApiKey: true, endpointPlaceholder: 'http://192.168.1.100:11434/v1',
      description: '填写手机可访问的 Ollama 服务器地址和已安装的模型名称。127.0.0.1 指手机自身。HTTP 未加密，请在可信网络中使用。' },
    { id: LEGACY_PROVIDER_ID, name: '自定义兼容服务', protocol: 'chat-completions',
      defaultBaseUrl: '', defaultModel: '', models: [] }
  ];
}

export interface ProviderDraft {
  baseUrl: string;
  model: string;
  noApiKey: boolean;
}

export function providerDraft(info: ProviderInfo, currentUrl: string, currentModel: string): ProviderDraft {
  // Custom endpoints retain the draft. Presets replace it, including Ollama's intentionally empty fields.
  return { baseUrl: info.id === LEGACY_PROVIDER_ID ? currentUrl : info.defaultBaseUrl,
    model: info.id === LEGACY_PROVIDER_ID ? currentModel : info.defaultModel,
    noApiKey: info.noApiKey === true };
}
