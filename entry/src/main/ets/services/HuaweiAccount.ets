import { authentication } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { t } from '../model/I18n';
import { CredentialStore } from './CredentialStore';

const ACCOUNT_ALIAS: string = 'tinybot.huawei.account.v1';

// Native Account Kit responses are obtained directly through the system API, not from a web page or JWT payload.
// Keep only OpenID in device-only AssetStore; authorization codes, ID tokens and UnionID are neither used nor saved.
@Observed
export class HuaweiAccount {
  ready: boolean = false;
  busy: boolean = false;
  signedIn: boolean = false;
  error: string = '';
  private openID: string = '';
  private context?: common.UIAbilityContext;
  private vault: CredentialStore = new CredentialStore();
  private initialization?: Promise<void>;
  private checking?: Promise<void>;
  private checkingRevision: number = -1;
  private revision: number = 0;

  initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    if (!this.initialization) { this.initialization = this.restore(); }
    return this.initialization;
  }

  private async restore(): Promise<void> {
    try {
      this.openID = await this.vault.readOptional(ACCOUNT_ALIAS) || '';
      if (this.openID) { await this.checkAccount(); }
    } catch (_) {
      this.signedIn = false; this.error = t('无法恢复华为账号登录状态，请重新登录。');
    } finally { this.ready = true; }
  }

  async signIn(): Promise<void> {
    if (this.busy || !this.ready || !this.context) { return; }
    this.busy = true; this.signedIn = false; this.error = ''; this.revision++;
    let phase: string = 'login';
    try {
      const provider = new authentication.HuaweiIDProvider();
      const request = provider.createLoginWithHuaweiIDRequest();
      request.forceLogin = true; request.state = util.generateRandomUUID();
      const response = await new authentication.AuthenticationController(this.context).executeRequest(request) as authentication.LoginWithHuaweiIDResponse;
      const openID = response.data?.openID;
      if (response.state !== request.state || !openID || openID.length > 256) {
        this.error = t('华为账号登录响应校验失败，请重新登录。'); return;
      }
      phase = 'state';
      const result = await provider.getHuaweiIDState({ idType: authentication.IdType.OPEN_ID, idValue: openID });
      if (result.state !== authentication.State.AUTHORIZED) {
        this.error = t('华为账号已退出或发生变化，请重新登录。'); return;
      }
      // Commit local identity only after both the request and the current device account have been checked.
      phase = 'storage';
      await this.vault.remove(ACCOUNT_ALIAS);
      await this.vault.write(ACCOUNT_ALIAS, openID);
      this.openID = openID; this.signedIn = true;
    } catch (error) {
      this.error = phase === 'storage' ? t('无法保存华为账号登录记录，请重试。') : phase === 'state' ?
        t('华为账号状态检查失败（{0}），请重试。', [(error as BusinessError).code || 0]) : accountError(error as BusinessError);
    } finally { this.busy = false; }
  }

  async signOut(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.revision++; this.openID = ''; this.signedIn = false; this.error = '';
    try { await this.vault.remove(ACCOUNT_ALIAS); }
    catch (_) { this.error = t('无法清除本机登录记录，请重试退出登录。'); }
    finally { this.busy = false; }
  }

  async refresh(): Promise<void> {
    if (!this.ready || this.busy || !this.openID) { return; }
    const revision = this.revision;
    try { await this.checkAccount(); }
    catch (_) {
      if (revision === this.revision) { this.signedIn = false; this.error = t('无法检查华为账号状态，请重试或重新登录。'); }
    }
  }

  async requireLogin(): Promise<void> {
    await this.initialization;
    const revision = this.revision;
    if (this.ready && !this.busy && this.openID) { await this.refresh(); }
    if (!this.ready || this.busy || !this.signedIn || revision !== this.revision) {
      throw new Error(this.error || t('请先登录华为账号，再使用 AI 生成功能。'));
    }
  }

  private checkAccount(): Promise<void> {
    if (!this.checking || this.checkingRevision !== this.revision) {
      const revision = this.revision;
      this.checkingRevision = revision;
      this.checking = this.verifyCurrentAccount().finally(() => {
        if (this.checkingRevision === revision) { this.checking = undefined; }
      });
    }
    return this.checking;
  }

  private async verifyCurrentAccount(): Promise<void> {
    const revision = this.revision; const openID = this.openID;
    const result = await new authentication.HuaweiIDProvider().getHuaweiIDState({ idType: authentication.IdType.OPEN_ID, idValue: openID });
    if (revision !== this.revision) { return; }
    if (result.state !== authentication.State.AUTHORIZED) {
      this.signedIn = false; this.openID = ''; this.error = t('华为账号已退出或发生变化，请重新登录。');
      await this.vault.remove(ACCOUNT_ALIAS); return;
    }
    this.signedIn = true; this.error = '';
  }
}

// Never include native error messages: they may contain account identifiers or credentials.
function accountError(error: BusinessError): string {
  const code = error.code;
  if (code === authentication.AuthenticationErrorCode.USER_CANCELED) { return t('已取消华为账号登录。'); }
  if (code === authentication.AuthenticationErrorCode.NETWORK_ERROR) { return t('华为账号登录网络异常，请检查网络后重试。'); }
  if (code === authentication.AuthenticationErrorCode.PACKAGE_FINGERPRINT_CHECK_ERROR ||
    code === authentication.AuthenticationErrorCode.PARAMETER_INVALID ||
    code === authentication.AuthenticationErrorCode.SCOPE_OR_PERMISSION_NOT_REQUESTED) {
    return t('华为账号配置校验失败（{0}），请检查 Client ID 和应用签名指纹。', [code]);
  }
  return t('华为账号登录失败（{0}），请重试。', [typeof code === 'number' ? code : 0]);
}

export const huaweiAccount: HuaweiAccount = new HuaweiAccount();
