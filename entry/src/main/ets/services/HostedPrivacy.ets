import { privacyManager } from '@kit.AppGalleryKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, commonEventManager, deviceInfo } from '@kit.BasicServicesKit';
import { DEBUG, BUILD_MODE_NAME } from 'BuildProfile';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';

const QUERY_RETRY_DELAYS: number[] = [500, 1000, 2000, 4000];
const STARTUP_PROMPT_DELAY_MS: number = 3000;

// AppGallery owns production consent. Emulator debug consent is explicit and memory-only.
@Observed
export class HostedPrivacy {
  allowed: boolean = false;
  busy: boolean = false;
  checking: boolean = false;
  error: string = '';
  private debugConsent: boolean = false;
  private context?: common.UIAbilityContext;
  private closing: boolean = false;
  private pageVisible: boolean = false;
  private pageShown: boolean = false;
  private gateFocused: boolean = false;
  private requestedAtStartup: boolean = false;
  private promptTimer: number = -1;
  private currentPolicy?: privacyManager.AppPrivacyLink;
  private result?: privacyManager.AppPrivacyResultType;
  private subscribed: boolean = false;
  private subscribing: boolean = false;
  private subscriptionGeneration: number = 0;
  private retryTimer: number = -1;
  private initializedAt: number = 0;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private onChange: (allowed: boolean) => void = () => {};

  get simulatorDebug(): boolean {
    return DEBUG && (BUILD_MODE_NAME as string) === 'debug' && deviceInfo.productModel === 'emulator';
  }

  acceptDebugConsent(): void {
    if (!this.simulatorDebug || !this.context || this.closing || !this.pageVisible) { return; }
    this.debugConsent = true;
    this.refresh();
  }

  async initialize(context: common.UIAbilityContext, onChange: (allowed: boolean) => void): Promise<void> {
    this.cancelQuery();
    this.cancelPrompt();
    this.resetSubscription();
    this.context = context; this.onChange = onChange;
    this.closing = false; this.busy = false; this.error = ''; this.debugConsent = false;
    this.pageVisible = false; this.pageShown = false; this.subscribed = false; this.initializedAt = Date.now();
    this.gateFocused = false; this.requestedAtStartup = false; this.currentPolicy = undefined;
    this.result = undefined;
    this.publish(false);
    if (this.simulatorDebug) { return; }
    await this.subscribe('subscription_ready');
  }

  private async subscribe(source: string): Promise<void> {
    if (!this.context || this.closing || this.simulatorDebug || this.subscribed || this.subscribing) { return; }
    const context = this.context, generation = this.subscriptionGeneration;
    this.subscribing = true;
    let subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
    try {
      subscriber = await commonEventManager.createSubscriber({ events: ['usual.event.PRIVACY_STATE_CHANGED'] });
      if (this.context !== context || this.subscriptionGeneration !== generation || this.closing) { this.unsubscribe(subscriber); return; }
      this.subscriber = subscriber;
      let failed = false;
      commonEventManager.subscribe(subscriber, (error) => {
        if (this.context !== context || this.subscriptionGeneration !== generation || this.subscriber !== subscriber || this.closing) { return; }
        if (error) {
          failed = true; this.subscriber = undefined; this.subscribed = false;
          this.unsubscribe(subscriber!); this.logFailure(error, 'subscribe', 'privacy_event'); return;
        }
        // Do not trust the event payload (including other app clones); query our own current record.
        this.refresh('privacy_event');
      });
      if (failed) { return; }
      this.subscribed = true;
      Diagnostics.log('info', 'privacy', 'subscription_ready', { operation: 'subscribe', phase: source, elapsedMs: Date.now() - this.initializedAt });
      // onPageShow may have arrived while the subscriber was being created.
      if (this.pageVisible && !this.allowed) { this.refresh(source); }
    } catch (error) {
      if (this.context !== context || this.subscriptionGeneration !== generation || this.closing) { return; }
      if (subscriber && this.subscriber === subscriber) { this.subscriber = undefined; this.unsubscribe(subscriber); }
      this.subscribed = false; this.logFailure(error as BusinessError, 'subscribe', source);
    } finally { if (this.subscriptionGeneration === generation) { this.subscribing = false; } }
  }

  private unsubscribe(subscriber: commonEventManager.CommonEventSubscriber): void {
    const report = (error: BusinessError): void => {
      Diagnostics.log('error', 'privacy', 'subscription_cleanup_failed', { operation: 'unsubscribe', code: typeof error.code === 'number' ? error.code : 0 });
    };
    try { commonEventManager.unsubscribe(subscriber, (error) => { if (error) { report(error); } }); }
    catch (error) { report(error as BusinessError); }
  }

  private resetSubscription(): void {
    this.subscriptionGeneration++; this.subscribing = false; this.subscribed = false;
    const subscriber = this.subscriber; this.subscriber = undefined;
    if (subscriber) { this.unsubscribe(subscriber); }
  }

  onPageShow(): void {
    this.pageVisible = true; this.pageShown = true;
    this.refresh('page_show');
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.cancelQuery();
    this.cancelPrompt();
  }

  onGateFocus(focused: boolean): void {
    this.gateFocused = focused;
    if (focused) { this.scheduleStartupPrompt(); }
    else { this.cancelPrompt(); }
  }

  refresh(source: string = 'business'): void {
    // After the first page show, background business and withdrawal events still recheck consent.
    if (!this.context || this.closing || !this.pageShown || this.checking || this.busy) { return; }
    if (this.simulatorDebug) {
      this.error = '';
      this.publish(this.debugConsent);
      return;
    }
    if (!this.subscribed && this.pageVisible) { this.subscribe(source); }
    this.check(source);
  }

  private check(source: string, retry: boolean = true): void {
    this.checking = true; this.error = '';
    this.query(source, 1, retry);
  }

  private query(source: string, attempt: number, retry: boolean): void {
    if (!this.context || this.closing || !this.pageShown) { this.cancelQuery(); return; }
    let operation = 'getAppPrivacyMgmtInfo';
    let consent: privacyManager.AppPrivacyResult | undefined;
    try {
      const link = this.policy();
      this.currentPolicy = link;
      operation = 'getAppPrivacyResult';
      const records = privacyManager.getAppPrivacyResult();
      consent = this.findConsent(records, link) ?? records.find((record) =>
        record.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT && record.id === link.id &&
        record.result === privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE);
    } catch (error) {
      const failure = error as BusinessError;
      if (retry && failure.code === 1006700003 && this.pageVisible && attempt <= QUERY_RETRY_DELAYS.length) {
        const delay = QUERY_RETRY_DELAYS[attempt - 1];
        Diagnostics.log('warn', 'privacy', 'query_retry', {
          operation: operation, phase: source, round: attempt, code: failure.code,
          delayMs: delay, elapsedMs: Date.now() - this.initializedAt
        });
        this.retryTimer = setTimeout(() => {
          this.retryTimer = -1;
          this.query(source, attempt + 1, retry);
        }, delay);
        // Let the UI start while AppGallery finishes making the upgrade state available.
        if (!this.requiresAction()) { this.publish(true); }
        return;
      }
      const code = this.logFailure(failure, operation, source, attempt);
      this.checking = false;
      if (this.requiresAction()) {
        this.error = t('无法确认系统隐私授权（{0}），请重试。', [code]);
      } else {
        this.publish(true);
      }
      this.scheduleStartupPrompt();
      return;
    }
    this.checking = false;
    Diagnostics.log(attempt > 1 ? 'warn' : 'info', 'privacy', 'query_completed', {
      operation: operation, phase: source, round: attempt, elapsedMs: Date.now() - this.initializedAt,
      eventCode: consent?.result,
      enabled: consent?.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED
    });
    this.applyResult(consent?.result);
    this.scheduleStartupPrompt();
  }

  private cancelQuery(): void {
    clearTimeout(this.retryTimer); this.retryTimer = -1;
    this.checking = false;
  }

  private cancelPrompt(): void {
    clearTimeout(this.promptTimer); this.promptTimer = -1;
  }

  private canRequest(): boolean {
    return !!this.context && this.pageVisible && !this.closing &&
      this.result === privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE &&
      !this.busy && !this.checking;
  }

  private scheduleStartupPrompt(): void {
    if (!this.gateFocused || this.requestedAtStartup || this.promptTimer !== -1 || !this.canRequest()) { return; }
    // AppGallery can host its modal inside our window, where the window itself may retain focus.
    this.promptTimer = setTimeout(() => {
      this.promptTimer = -1;
      if (this.gateFocused) { this.requestConsent('startup_prompt'); }
    }, STARTUP_PROMPT_DELAY_MS);
  }

  private findConsent(records: privacyManager.AppPrivacyResult[],
    link: privacyManager.AppPrivacyLink): privacyManager.AppPrivacyResult | undefined {
    return records.find((record) => record.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT &&
      record.id === link.id && record.versionCode === link.versionCode);
  }

  private requiresAction(): boolean {
    return this.result === privacyManager.AppPrivacyResultType.DISAGREED ||
      this.result === privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE;
  }

  private applyResult(result: privacyManager.AppPrivacyResultType | undefined): void {
    if (result === privacyManager.AppPrivacyResultType.DISAGREED ||
      result === privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE ||
      result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED) {
      this.result = result;
    }
    this.error = '';
    this.publish(!this.requiresAction());
    if (this.result === privacyManager.AppPrivacyResultType.DISAGREED) { this.exit(); }
  }

  requireConsent(): void {
    // Recheck on access, including after a launch with an inconclusive result.
    if (this.allowed) { this.refresh(); }
    if (!this.allowed) {
      throw new Error(this.error || (this.simulatorDebug ? t('请先确认模拟器调试隐私说明。') : t('请先在系统弹窗中同意隐私政策。')));
    }
  }

  async requestConsent(source: string = 'request_consent'): Promise<void> {
    if (this.result === privacyManager.AppPrivacyResultType.DISAGREED) { await this.exit(); return; }
    if (!this.context || !this.canRequest()) { return; }
    const context = this.context, generation = this.subscriptionGeneration;
    this.cancelPrompt();
    this.busy = true;
    try {
      this.check(source, false);
      if (!this.pageVisible || this.closing ||
        this.result !== privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE ||
        (source === 'startup_prompt' && !this.gateFocused)) { return; }
      this.requestedAtStartup = true;
      this.error = '';
      Diagnostics.log('info', 'privacy', 'request_started', { phase: source });
      let response: privacyManager.ConsentResult;
      try { response = await privacyManager.requestAppPrivacyConsent(context); }
      catch (error) {
        if (this.subscriptionGeneration !== generation || this.closing) { return; }
        const code = this.logFailure(error as BusinessError, 'requestAppPrivacyConsent', source);
        this.error = t('无法确认系统隐私授权（{0}），请重试。', [code]);
        return;
      }
      if (this.subscriptionGeneration !== generation || this.closing) { return; }
      const policy = this.currentPolicy;
      const consent = policy ? this.findConsent(response.results, policy) : undefined;
      if (!consent) {
        // The dialog may have used a newer agreement. Ask the system for its current state.
        this.check('consent_result', false);
        return;
      }
      this.applyResult(consent.result);
    } finally {
      if (this.subscriptionGeneration === generation) { this.busy = false; }
    }
  }

  async exit(): Promise<void> {
    if (!this.context || this.closing) { return; }
    const context = this.context;
    this.closing = true;
    this.cancelQuery();
    this.cancelPrompt();
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
      const code = this.logFailure(error as BusinessError, 'disableService', 'revoke');
      throw new Error(t('撤回隐私授权失败（{0}），请重试。', [code]));
    }
    this.error = '';
    // Stop business immediately; do not wait for the system event to arrive.
    this.result = privacyManager.AppPrivacyResultType.DISAGREED;
    this.publish(false);
    this.exit();
  }

  private policy(): privacyManager.AppPrivacyLink {
    const info = privacyManager.getAppPrivacyMgmtInfo();
    const link = info.privacyInfo.find((item) => item.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK);
    if (info.type !== privacyManager.AppPrivacyMgmtType.FULL_MODE || !link || !link.id ||
      !Number.isInteger(link.versionCode) || !/^https:\/\/[^/\s]+/i.test(link.url)) {
      throw new Error(t('隐私托管尚未就绪，请稍后重试。'));
    }
    return link;
  }

  private logFailure(error: BusinessError, operation: string, source: string, attempt: number = 0): number {
    const code = typeof error.code === 'number' ? error.code : 0;
    Diagnostics.log('error', 'privacy', 'check_failed', {
      operation: operation, phase: source, round: attempt,
      code, elapsedMs: Date.now() - this.initializedAt
    });
    return code;
  }

  private publish(allowed: boolean): void {
    if (allowed && this.closing) { return; }
    if (allowed) { this.cancelPrompt(); this.requestedAtStartup = false; }
    const changed = this.allowed !== allowed;
    this.allowed = allowed;
    // Activate native services before mounting the business UI.
    if (changed) { this.onChange(allowed); }
    AppStorage.setOrCreate('tinybot.privacy.allowed', allowed);
  }

  dispose(): void {
    this.onPageHide();
    this.pageShown = false;
    this.resetSubscription();
    this.debugConsent = false;
    this.context = undefined; this.onChange = () => {};
    this.publish(false);
  }
}

export const hostedPrivacy: HostedPrivacy = new HostedPrivacy();
