import { t } from './I18n';

export function isSupportedProtocol(protocol: string): boolean {
  return ['chat-completions', 'responses', 'anthropic-messages', 'gemini'].includes(protocol);
}

export const IMAGE_PROTOCOLS: string[] = ['openai-images', 'gemini-images', 'seedream-images', 'dashscope-images'];
const FIXED_ENDPOINTS: string[] = ['/chat/completions', '/responses', '/messages',
  '/images/generations', '/images/edits', '/interactions', '/services/aigc/multimodal-generation/generation'];

export function isImageProtocol(protocol: string): boolean { return IMAGE_PROTOCOLS.includes(protocol); }

export function isProviderProtocol(protocol: string): boolean {
  return isSupportedProtocol(protocol) || isImageProtocol(protocol);
}

export function providerEndpointRoot(endpoint: string): string {
  const suffix = FIXED_ENDPOINTS.find((item) => endpoint.endsWith(item));
  return suffix ? endpoint.slice(0, -suffix.length) : endpoint;
}

export function completionUrl(baseUrl: string, allowHttp: boolean = false): string {
  const base = baseUrl.trim().replace(/\/+$/, '');
  if (!/^https?:\/\/[^\s/?#@:\\]+(?::\d+)?(?:\/[^\s?#\\]*)?$/.test(base) ||
    (!allowHttp && !base.startsWith('https://'))) {
    throw new Error(t("服务地址必须是 {0} 地址，不能包含账号、查询参数、反斜杠或片段。", [allowHttp ? t('HTTP 或 HTTPS') : 'HTTPS']));
  }
  return base.endsWith('/chat/completions') ? base : base + '/chat/completions';
}

export function protocolUrl(protocol: string, baseUrl: string, allowHttp: boolean): string {
  completionUrl(baseUrl, allowHttp);
  const base = baseUrl.trim().replace(/\/+$/, '');
  if (protocol === 'gemini') {
    if (providerEndpointRoot(base) !== base || /:(streamGenerateContent|generateContent)$/.test(base)) {
      throw new Error(t('服务地址的接口路径与所选协议不一致。'));
    }
    return /^https?:\/\/[^/]+$/.test(base) ? base + '/v1beta' : base;
  }
  const suffix = protocol === 'chat-completions' ? '/chat/completions' : protocol === 'responses' ? '/responses' :
    protocol === 'anthropic-messages' ? '/messages' : protocol === 'dashscope-images' ? '/services/aigc/multimodal-generation/generation' :
    protocol === 'gemini-images' ? '/interactions' : ['openai-images', 'seedream-images'].includes(protocol) ? '/images/generations' : '';
  if (!suffix) { throw new Error(t("不支持的模型协议：") + protocol); }
  if (protocol === 'openai-images' && base.endsWith('/images/edits')) {
    return providerEndpointRoot(base) + suffix;
  }
  for (const ending of FIXED_ENDPOINTS) {
    if (base.endsWith(ending) && ending !== suffix) { throw new Error(t("服务地址的接口路径与所选协议不一致。")); }
  }
  if (base.endsWith(suffix)) { return base; }
  if (['anthropic-messages', 'gemini-images'].includes(protocol) && /^https?:\/\/[^/]+$/.test(base)) { return base + '/v1' + suffix; }
  return base + suffix;
}

// Credentials belong to the API service root, not its request wire format.
// Keep scheme, host, port and base path scoped; strip only the protocol's endpoint.
export function sameCredentialScope(oldProtocol: string, oldUrl: string, protocol: string, baseUrl: string): boolean {
  try {
    const previous = providerEndpointRoot(protocolUrl(oldProtocol, oldUrl, true));
    const next = providerEndpointRoot(protocolUrl(protocol, baseUrl, true));
    return previous === next;
  } catch (_) { return false; }
}

export function sharedImageBaseUrl(chatProtocol: string, chatUrl: string, imageProtocol: string, imageUrl?: string): string {
  const chatRoot = providerEndpointRoot(protocolUrl(chatProtocol, chatUrl, true));
  const base = imageUrl || chatRoot;
  const endpoint = protocolUrl(imageProtocol, base, true);
  const origin = /^https?:\/\/[^/]+/;
  if (origin.exec(chatRoot)?.[0] !== origin.exec(endpoint)?.[0]) {
    throw new Error(t('复用 API Key 时，图片服务的协议、主机和端口必须与聊天服务一致。'));
  }
  return base;
}
