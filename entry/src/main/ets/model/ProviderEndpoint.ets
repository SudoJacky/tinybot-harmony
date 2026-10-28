import { t } from './I18n';

export function isSupportedProtocol(protocol: string): boolean {
  return ['chat-completions', 'responses', 'anthropic-messages', 'gemini'].includes(protocol);
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
    if (/\/(chat\/completions|responses|messages)$/.test(base) || /:(streamGenerateContent|generateContent)$/.test(base)) {
      throw new Error(t('服务地址的接口路径与所选协议不一致。'));
    }
    return /^https?:\/\/[^/]+$/.test(base) ? base + '/v1beta' : base;
  }
  const suffix = protocol === 'chat-completions' ? '/chat/completions' : protocol === 'responses' ? '/responses' :
    protocol === 'anthropic-messages' ? '/messages' : '';
  if (!suffix) { throw new Error(t("不支持的模型协议：") + protocol); }
  for (const ending of ['/chat/completions', '/responses', '/messages']) {
    if (base.endsWith(ending) && ending !== suffix) { throw new Error(t("服务地址的接口路径与所选协议不一致。")); }
  }
  if (base.endsWith(suffix)) { return base; }
  if (protocol === 'anthropic-messages' && /^https?:\/\/[^/]+$/.test(base)) { return base + '/v1/messages'; }
  return base + suffix;
}

// Credentials belong to the API service root, not its request wire format.
// Keep scheme, host, port and base path scoped; strip only the protocol's endpoint.
export function sameCredentialScope(oldProtocol: string, oldUrl: string, protocol: string, baseUrl: string): boolean {
  try {
    const previous = protocolUrl(oldProtocol, oldUrl, true).replace(/\/(chat\/completions|responses|messages)$/, '');
    const next = protocolUrl(protocol, baseUrl, true).replace(/\/(chat\/completions|responses|messages)$/, '');
    return previous === next;
  } catch (_) { return false; }
}
