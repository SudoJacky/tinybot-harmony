import { privacyManager } from '@kit.AppGalleryKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, commonEventManager, deviceInfo } from '@kit.BasicServicesKit';
import { DEBUG, BUILD_MODE_NAME } from 'BuildProfile';
import { t } from '../model/I18n';

// AppGallery owns production consent. Emulator debug consent is explicit and memory-only.
@Observed
export class HostedPrivacy {
  allowed: boolean = false;
  busy: boolean = false;
  error: string = '';
  private debugConsent: boolean = false;
  private context?: common.UIAbilityContext;
  private closing: boolean = false;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private onChange: (allowed: boolean) => void = () => {};

  get simulatorDebug(): boolean {
    return DEBUG && (BUILD_MODE_NAME as string) === 'debug' && deviceInfo.productModel === 'emulator';
  }

  acceptDebugConsent(): void {
    if (!this.simulatorDebug || !this.context || this.closing) { return; }
    this.debugConsent = true;
    this.refresh();
  }

  async initialize(context: common.UIAbilityContext, onChange: (allowed: boolean) => void): Promise<void> {
    this.context = context; this.onChange = onChange;
    this.closing = false; this.busy = false; this.error = ''; this.debugConsent = false;
    this.publish(false);
    if (this.simulatorDebug) { return; }
    try {
      const subscriber = await commonEventManager.createSubscriber({ events: ['usual.event.PRIVACY_STATE_CHANGED'] });
      if (this.context !== context) { return; }
      this.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error) => {
        if (this.context !== context) { return; }
        if (error) { this.fail(error); return; }
        // Do not trust the event payload (including other app clones); query our own current record.
        this.refresh();
      });
      this.refresh();
    } catch (error) { this.fail(error as BusinessError); }
  }

  refresh(): void {
    if (!this.context) { return; }
    if (this.simulatorDebug) {
      this.error = '';
      this.publish(this.debugConsent);
      return;
    }
    try {
      const link = this.policy();
      const records = privacyManager.getAppPrivacyResult();
      const consent = records.find((record) => record.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT &&
        record.id === link.id && record.versionCode === link.versionCode);
      this.error = '';
      this.publish(consent?.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED);
    } catch (error) { this.fail(error as BusinessError); }
  }

  requireConsent(): void {
    this.refresh();
    if (!this.allowed) {
      throw new Error(this.error || (this.simulatorDebug ? t('请先确认模拟器调试隐私说明。') : t('请先在系统弹窗中同意隐私政策。')));
    }
  }

  async requestConsent(): Promise<void> {
    if (!this.context || this.busy || this.closing) { return; }
    // Retrying a system request must never implicitly accept local debug consent.
    if (this.simulatorDebug) { return; }
    this.refresh();
    if (this.allowed) { return; }
    const context = this.context;
    this.busy = true; this.error = '';
    try {
      await privacyManager.requestAppPrivacyConsent(context);
      if (this.context === context && !this.closing) {
        this.refresh();
        if (!this.allowed && !this.error) { await this.exit(); }
      }
    } catch (error) { if (this.context === context) { this.fail(error as BusinessError); } }
    finally { if (this.context === context) { this.busy = false; } }
  }

  async exit(): Promise<void> {
    if (!this.context || this.closing) { return; }
    const context = this.context;
    this.closing = true;
    try { await context.terminateSelf(); }
    catch (error) {
      if (this.context !== context) { return; }
      this.closing = false;
      const failure = error as BusinessError;
      this.error = t('无法退出应用（{0}），请重试。', [typeof failure.code === 'number' ? failure.code : 0]);
    }
  }

  async openPolicy(context: common.UIAbilityContext): Promise<void> {
    if (this.simulatorDebug) {
      const url = context.currentHapModuleInfo.metadata?.find((item) =>
        item.name === 'appgallery_privacy_link_privacy_statement')?.value;
      if (!url || !/^https:\/\/[^/\s]+/i.test(url)) { throw new Error(t('隐私托管尚未就绪，请稍后重试。')); }
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: url });
      return;
    }
    const link = this.policy();
    await context.startAbility({ action: 'ohos.want.action.viewData', uri: link.url });
  }

  revokeConsent(): void {
    if (this.simulatorDebug) {
      this.debugConsent = false;
      this.refresh();
      this.exit();
      return;
    }
    try { privacyManager.disableService(); }
    catch (error) {
      const failure = error as BusinessError;
      throw new Error(t('撤回隐私授权失败（{0}），请重试。', [typeof failure.code === 'number' ? failure.code : 0]));
    }
    this.error = '';
    // Stop business immediately; do not wait for the system event to arrive.
    this.publish(false);
    this.exit();
  }

  private policy(): privacyManager.AppPrivacyLink {
    const info = privacyManager.getAppPrivacyMgmtInfo();
    const link = info.privacyInfo.find((item) => item.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK);
    if (info.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE || !link || !/^https:\/\/[^/\s]+/i.test(link.url)) {
      throw new Error(t('隐私托管尚未就绪，请稍后重试。'));
    }
    return link;
  }

  private fail(error: BusinessError): void {
    this.error = t('无法确认系统隐私授权（{0}），请重试。', [typeof error.code === 'number' ? error.code : 0]);
    this.publish(false);
  }

  private publish(allowed: boolean): void {
    if (allowed && this.closing) { return; }
    const changed = this.allowed !== allowed;
    this.allowed = allowed;
    // Activate native services before mounting the business UI.
    if (changed) { this.onChange(allowed); }
    AppStorage.setOrCreate('tinybot.privacy.allowed', allowed);
  }

  dispose(): void {
    this.debugConsent = false;
    this.context = undefined; this.onChange = () => {};
    if (this.subscriber) { commonEventManager.unsubscribe(this.subscriber); this.subscriber = undefined; }
    this.publish(false);
  }
}

export const hostedPrivacy: HostedPrivacy = new HostedPrivacy();
