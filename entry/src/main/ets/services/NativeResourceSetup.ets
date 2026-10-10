import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../model/I18n';
import { McpServer } from '../model/Productivity';
import { McpRequest } from '../model/ResourceManagement';
import { CredentialStore } from './CredentialStore';
import { Cancellation } from './Cancellation';
import { McpOAuth } from './McpOAuth';
import { ToolApproval } from './ToolApproval';

interface SecretReceipt { status: string; values?: Record<string, string>; }

export async function prepareNativeMcp(server: McpServer, request: McpRequest, approval: ToolApproval,
  context: common.UIAbilityContext | undefined, cancellation: Cancellation, confirm: boolean = true): Promise<McpServer> {
  const result = JSON.parse(JSON.stringify(server)) as McpServer;
  let alias = '';
  try {
    cancellation.check();
    if (request.auth === 'bearer') {
      // Native-only field type: parseForm rejects password, so ask_user cannot collect credentials this way.
      const answer = JSON.parse(await approval.ask({ title: t('MCP 鉴权：{0}', [server.name]), fields: [
        { name: 'token', label: t('仅发送给 {0}；不会写入聊天或交给模型。', [server.url]), type: 'password', required: true }
      ] }, cancellation)) as SecretReceipt;
      if (answer.status !== 'submitted' || !answer.values?.['token']) { throw new Error(t('MCP 配置已取消。')); }
      alias = 'tinybot-mcp-' + util.generateRandomUUID();
      await new CredentialStore().write(alias, answer.values['token']);
      answer.values['token'] = '';
      result.credentialAlias = alias; result.authType = undefined;
    } else if (request.auth === 'oauth') {
      if (!context) { throw new Error(t('无法打开系统浏览器。')); }
      if (confirm) { await approval.request(t('连接 MCP：{0}', [server.name]), server.url + '\n' + t('将在浏览器中完成 OAuth 授权。'), cancellation); }
      alias = await McpOAuth.login(server, context, request.clientId || '', cancellation);
      result.credentialAlias = alias; result.authType = 'oauth';
    }
    cancellation.check(); return result;
  } catch (error) {
    if (alias) {
      try { await new CredentialStore().remove(alias); }
      catch (cleanup) { hilog.error(0, 'TinybotResources', 'Credential rollback failed: %{public}s', (cleanup as Error).message); }
    }
    throw error as Error;
  }
}
