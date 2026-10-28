import { AppData } from './Conversation';
import { AGENT_MODES, AgentMode, ToolSelection, knownDisabledTool } from './AgentMode';
import { isSupportedProtocol } from './ProviderEndpoint';
import { isSupportedSearchProvider } from './WebSearch';
import { REASONING_EFFORTS } from './ReasoningEffort';
import { supportedMcpAuth } from './Productivity';
import { supportsAutoRoute } from './AssistantOptions';
import { t } from './I18n';

export interface ConfigurationIssue { setting: string; message: string; threadId?: string; providerId?: string; serverId?: string; }

// Inspect saved intent; never replace it with this build's runtime defaults.
export function configurationIssues(data: AppData, selections?: Map<string, ToolSelection>): ConfigurationIssue[] {
  const issues: ConfigurationIssue[] = [];
  const search = data.productivity?.options?.search;
  if (search && !isSupportedSearchProvider(search.provider)) {
    issues.push({ setting: 'search.provider', message: t('当前版本不支持保存的搜索服务，搜索已停用；原配置已保留。') });
  }
  for (const profile of data.providerProfiles || []) {
    if (!isSupportedProtocol(profile.protocol)) {
      issues.push({ setting: 'providerProfiles.protocol', providerId: profile.id,
        message: t('当前版本不支持部分模型协议，对应模型暂不可用；原配置已保留。') });
    }
  }
  const options = data.productivity?.options;
  if (options?.autoRoute && !supportsAutoRoute(options, data.providerProfiles || [])) {
    issues.push({ setting: 'options.autoRoute', message: t('自动路由使用了当前版本不支持的模型协议，自动路由已停用；仍使用所选模型，原配置已保留。') });
  }
  const policy = data.extensions?.browserPolicy;
  if (policy !== undefined && !['unset', 'enabled', 'disabled'].includes(policy)) {
    issues.push({ setting: 'extensions.browserPolicy', message: t('当前版本不支持保存的浏览器权限，浏览器已停用；原配置已保留。') });
  }
  if (data.config.reasoning !== undefined && !REASONING_EFFORTS.includes(data.config.reasoning)) {
    issues.push({ setting: 'config.reasoning', message: reasoningWarning() });
  }
  for (const capability of data.productivity?.options?.capabilities || []) {
    if (!REASONING_EFFORTS.includes(capability.reasoning)) {
      issues.push({ setting: 'capabilities.reasoning', providerId: capability.providerId, message: reasoningWarning() });
    }
  }
  for (const thread of data.threads) {
    const selection = selections?.get(thread.id) || thread;
    if (selection.agentMode !== undefined && !AGENT_MODES.includes(selection.agentMode as AgentMode)) {
      issues.push({ setting: 'threads.agentMode', threadId: thread.id,
        message: t('当前版本不支持部分会话的工具模式，这些会话的工具已停用；原配置已保留。') });
    }
    if ((selection.disabledTools || []).some((name) => !knownDisabledTool(name))) {
      issues.push({ setting: 'threads.disabledTools', threadId: thread.id,
        message: t('当前版本不认识部分工具限制，已保留这些限制。') });
    }
    if (thread.reasoningEffort !== undefined && !REASONING_EFFORTS.includes(thread.reasoningEffort)) {
      issues.push({ setting: 'threads.reasoningEffort', threadId: thread.id, message: reasoningWarning() });
    }
  }
  for (const server of data.productivity?.servers || []) {
    if (!supportedMcpAuth(server)) {
      issues.push({ setting: 'servers.authType', serverId: server.id, message: t('当前版本不支持部分 MCP 认证方式，对应服务已停用；原配置已保留。') });
    }
  }
  return issues;
}

function reasoningWarning(): string {
  return t('当前版本不支持部分推理强度，运行时使用模型默认值；原配置已保留。');
}
