import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { ToolFailure, ToolFailureDetails, parseToolResponse, toolHttpFailure } from '../model/ToolFailure';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CompatHttp, CompatResponse } from './CompatHttp';
import { CredentialStore } from './CredentialStore';
import { withFileMutation } from './FileMutationQueue';
import { knowledgeBaseAccess } from './KnowledgeBaseAccess';
import { NetworkTransfers } from './NetworkTransfers';

export const IMA_SETUP_URL: string = 'https://ima.qq.com/agent-interface';
const IMA_API_URL: string = 'https://ima.qq.com/openapi/';
const IMA_ASSET: string = 'tinybot-ima-connection';

export interface ImaSettings { clientId: string; enabled: boolean; }
interface ImaConnection extends ImaSettings { apiKey: string; }
export type ImaMethod = 'search_knowledge_base' | 'get_knowledge_list' | 'search_knowledge' | 'get_knowledge_base' |
  'get_addable_knowledge_base_list' | 'get_media_info' | 'get_doc_content' | 'check_repeated_names' | 'create_media' |
  'import_urls' | 'add_knowledge';
export interface ImaRequest {
  cursor?: string;
  query?: string;
  limit?: number;
  ids?: string[];
  knowledge_base_id?: string;
  folder_id?: string;
  media_id?: string;
  media_type?: number;
  title?: string;
  note_id?: string;
  target_content_format?: number;
  urls?: string[];
  params?: ImaNamedMedia[];
  file_name?: string;
  file_ext?: string;
  file_size?: number;
  content_type?: string;
  file_info?: ImaFileInfo;
  note_info?: ImaContentInfo;
  session_info?: ImaContentInfo;
}
export interface ImaNamedMedia { name: string; media_type: number; }
interface ImaContentInfo { content_id: string; }
export interface ImaFileInfo { cos_key: string; file_size: number; last_modify_time: number; file_name: string; }
export interface ImaSession {
  query: (method: ImaMethod, input: ImaRequest) => Promise<Object>;
  checkAccess: () => void;
}
interface ImaResponse { code: number; msg?: string; data?: Object; }

function validHeader(value: string): boolean { return /^[!-~]+$/.test(value); }

export class ImaClient {
  private vault: CredentialStore = new CredentialStore();
  private accessEnabled: boolean = false;
  private revision: number = 0;

  get enabled(): boolean { return knowledgeBaseAccess.enabled && this.accessEnabled; }

  private async stored(): Promise<ImaConnection | undefined> {
    const raw = await this.vault.readOptional(IMA_ASSET);
    if (raw === undefined) { return undefined; }
    const invalid = t('无法读取已保存的腾讯 ima 连接，请移除后重新配置。');
    let value: ImaConnection;
    try { value = JSON.parse(raw) as ImaConnection; }
    catch (_) { throw new Error(invalid); }
    if (!value || typeof value.enabled !== 'boolean' || typeof value.clientId !== 'string' ||
      typeof value.apiKey !== 'string' || !validHeader(value.clientId) || !validHeader(value.apiKey)) {
      throw new Error(invalid);
    }
    return value;
  }

  async load(): Promise<ImaSettings | undefined> {
    return withFileMutation(IMA_ASSET, async (): Promise<ImaSettings | undefined> => {
      const value = await this.stored();
      this.accessEnabled = value?.enabled === true;
      return value ? this.settings(value) : undefined;
    });
  }

  private settings(value: ImaConnection): ImaSettings {
    return { clientId: value.clientId, enabled: value.enabled };
  }

  private connection(settings: ImaSettings, apiKey: string, previous?: ImaConnection): ImaConnection {
    const clientId = settings.clientId.trim();
    const key = apiKey.trim() || (previous?.clientId === clientId ? previous.apiKey : '');
    if (!validHeader(clientId) || !validHeader(key)) {
      throw new Error(t('请填写有效的腾讯 ima Client ID 和 API Key。更换 Client ID 时需重新填写 API Key。'));
    }
    return { clientId: clientId, enabled: settings.enabled, apiKey: key };
  }

  async save(settings: ImaSettings, apiKey: string): Promise<ImaSettings> {
    return withFileMutation(IMA_ASSET, async () => {
      const previous = await this.stored();
      const value = this.connection(settings, apiKey, previous);
      const raw = JSON.stringify(value);
      if (new util.TextEncoder().encodeInto(raw).length > 1024) {
        throw new Error(t('腾讯 ima 凭据超出安全存储大小限制。'));
      }
      if (previous) { await this.vault.update(IMA_ASSET, raw); }
      else { await this.vault.write(IMA_ASSET, raw); }
      this.accessEnabled = value.enabled;
      this.revision++;
      return this.settings(value);
    });
  }

  async remove(): Promise<void> {
    return withFileMutation(IMA_ASSET, async () => {
      await this.vault.remove(IMA_ASSET);
      this.accessEnabled = false;
      this.revision++;
    });
  }

  async test(settings: ImaSettings, apiKey: string, cancellation: Cancellation): Promise<void> {
    cancellation.check();
    const value = this.connection(settings, apiKey, await this.stored());
    await this.request('search_knowledge_base', { query: '', cursor: '', limit: 1 }, value, cancellation);
  }

  async query(method: ImaMethod, input: ImaRequest, cancellation: Cancellation): Promise<Object> {
    return this.withAccess(cancellation, (session) => session.query(method, input));
  }

  async withAccess<T>(cancellation: Cancellation, operation: (session: ImaSession) => Promise<T>): Promise<T> {
    cancellation.check();
    const revision = this.revision;
    const accessRevision = knowledgeBaseAccess.revision;
    const checkAccess = (): void => {
      cancellation.check();
      if (!this.enabled || this.revision !== revision || knowledgeBaseAccess.revision !== accessRevision) {
        throw new ToolFailure('NOT_CONFIGURED', t('腾讯 ima 连接已关闭或已更改，请检查设置。'), 'check_settings');
      }
    };
    checkAccess();
    const value = await this.stored();
    if (!value?.enabled) {
      throw new ToolFailure('NOT_CONFIGURED', t('腾讯 ima 连接已关闭或已更改，请检查设置。'), 'check_settings');
    }
    const session: ImaSession = {
      query: (method, input) => this.request(method, input, value, cancellation, checkAccess),
      checkAccess: checkAccess
    };
    const result = await operation(session);
    checkAccess();
    return result;
  }

  private async request(method: ImaMethod, input: ImaRequest, value: ImaConnection, cancellation: Cancellation,
    checkAccess?: () => void): Promise<Object> {
    const endTransfer = checkAccess ? await NetworkTransfers.begin(cancellation) : undefined;
    const started = Date.now();
    try {
      cancellation.check();
      checkAccess?.();
      const response = await new Promise<CompatResponse>((resolve, reject) => {
        let abort = (): void => {};
        let unsubscribe = (): void => {};
        let settled = false;
        const finish = (response?: CompatResponse, error?: ToolFailure | RunCancelledError): void => {
          if (settled) { return; }
          settled = true; clearTimeout(timer); unsubscribe();
          if (error) { abort(); reject(error); } else { resolve(response!); }
        };
        const timer = setTimeout(() => finish(undefined, new ToolFailure('TIMEOUT',
          t('腾讯 ima 请求超时。'), 'check_connection')), 30000);
        unsubscribe = cancellation.onCancel(() => finish(undefined, new RunCancelledError()));
        if (settled) { return; }
        CompatHttp.request({
          url: IMA_API_URL + (method === 'get_doc_content' ? 'note/v1/' : 'wiki/v1/') + method, method: 'POST',
          headers: { 'Content-Type': 'application/json; charset=utf-8', 'ima-openapi-clientid': value.clientId, 'ima-openapi-apikey': value.apiKey },
          body: JSON.stringify(input), connectTimeout: 10000, readTimeout: 30000, maxBytes: 256 * 1024, dataType: 'string', redirect: 'refuse'
        }, (stop: () => void) => { abort = stop; })
          .then((response: CompatResponse) => finish(response))
          .catch((error: Error) => {
            const code = (error as BusinessError).code;
            finish(undefined, new ToolFailure('NETWORK_ERROR', t('无法连接腾讯 ima。'), 'check_connection',
              { service: 'ima', nativeCode: code }));
          });
      });
      cancellation.check();
      checkAccess?.();
      if (response.status !== 200) {
        throw toolHttpFailure(response.status, t('腾讯 ima 请求失败（HTTP {0}）。', [response.status]), 'ima');
      }
      const payload = parseToolResponse(response.text) as ImaResponse;
      if (!payload || !Number.isInteger(payload.code)) {
        throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service', { service: 'ima' });
      }
      if (payload.code !== 0) {
        const message = typeof payload.msg === 'string' ?
          payload.msg.split(value.apiKey).join('[redacted]').split(value.clientId).join('[redacted]').trim().slice(0, 300) : '';
        const details: ToolFailureDetails = { service: 'ima', remoteCode: payload.code };
        throw new ToolFailure(payload.code === 110030 ? 'PERMISSION_DENIED' : payload.code === 110021 ? 'RATE_LIMITED' : 'REMOTE_ERROR',
          message ? t('腾讯 ima 返回错误（{0}）：{1}', [payload.code, message]) : t('腾讯 ima 返回错误（{0}）。', [payload.code]),
          payload.code === 110030 ? 'check_permissions' : payload.code === 110021 ? 'wait_then_check' : 'inspect_service', details);
      }
      if (!payload.data || typeof payload.data !== 'object' || Array.isArray(payload.data)) {
        throw new ToolFailure('INVALID_RESPONSE', t('腾讯 ima 返回了无效响应。'), 'inspect_service', { service: 'ima' });
      }
      return payload.data;
    } catch (error) {
      Diagnostics.log(cancellation.cancelled ? 'debug' : 'warn', 'ima', 'request_failed',
        { operation: method, elapsedMs: Date.now() - started, cancelled: cancellation.cancelled }, error as Error);
      throw error as Error;
    } finally { await endTransfer?.(); }
  }
}

export const imaClient: ImaClient = new ImaClient();
