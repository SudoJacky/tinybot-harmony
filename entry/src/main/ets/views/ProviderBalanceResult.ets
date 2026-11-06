import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { getLocale, t } from '../model/I18n';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ProviderDraft } from '../services/ProfileSettings';
import { BalanceAmount, ProviderBalance, queryProviderBalance, supportsProviderBalance } from '../services/ProviderBalance';
import { BalanceQueryState, failedBalanceState, providerBalanceCache, savedBalanceProfile } from '../services/ProviderBalanceCache';

@Component
export struct ProviderBalanceResult {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop draft: ProviderDraft;
  @Prop profiles: ProviderProfile[] = [];
  @Prop @Watch('queryOnEntry') disabled: boolean = false;
  @Prop @Watch('visibilityChanged') active: boolean = false;
  @Prop @Watch('reset') scope: string = '';
  @Prop canQuery: boolean = false;
  @Prop compact: boolean = false;
  @State private expanded: boolean = false;
  @State private result?: ProviderBalance = undefined;
  @State private error: string = '';
  @State private loading: boolean = false;
  private generation: number = 0;
  private alive: boolean = false;
  private queriedOnEntry: boolean = false;
  private unsubscribe?: () => void;

  aboutToAppear(): void { this.alive = true; this.bind(); this.queryOnEntry(); }
  aboutToDisappear(): void { this.alive = false; this.queriedOnEntry = false; this.reset(); }
  private visibilityChanged(): void {
    if (!this.active) { this.queriedOnEntry = false; this.reset(); return; }
    this.bind(); this.queryOnEntry();
  }
  private bind(): void {
    this.unsubscribe?.(); this.unsubscribe = undefined;
    if (!this.alive || !this.active) { return; }
    const profile = savedBalanceProfile(this.draft, this.profiles);
    if (profile) {
      const generation = this.generation;
      this.unsubscribe = providerBalanceCache.subscribe(profile, (state: BalanceQueryState) => {
        if (this.alive && this.active && generation === this.generation) {
          this.result = state.result; this.error = state.error; this.loading = state.loading;
        }
      });
    }
  }
  private queryOnEntry(): void {
    if (!this.alive || !this.active || this.disabled || this.queriedOnEntry) { return; }
    this.queriedOnEntry = true;
    if (this.supported() && this.canQuery) { this.refresh(false); }
  }
  private reset(): void {
    this.generation++; this.unsubscribe?.(); this.unsubscribe = undefined;
    this.result = undefined; this.error = ''; this.loading = false;
    // Scope edits clear the display but never send a request on each keystroke.
    this.bind();
  }
  private supported(): boolean { return supportsProviderBalance(this.draft.protocol, this.draft.baseUrl, this.draft.balance); }
  private async refresh(force: boolean = true): Promise<void> {
    if (!this.alive || !this.active || this.loading || this.disabled) { return; }
    const profile = savedBalanceProfile(this.draft, this.profiles);
    if (profile) { await providerBalanceCache.refresh(profile, force); return; }
    const generation = this.generation;
    this.loading = true; this.error = '';
    try {
      const result = await queryProviderBalance(this.draft, this.profiles);
      if (this.alive && generation === this.generation) { this.result = result; }
    } catch (error) {
      if (this.alive && generation === this.generation) {
        const state = failedBalanceState(this.result, error as Error);
        this.result = state.result; this.error = state.error;
      }
    } finally { if (this.alive && generation === this.generation) { this.loading = false; } }
  }
  private summary(): string {
    if (!this.result) { return this.loading ? t('正在查询余额…') : t('余额与额度'); }
    const amount = this.result.amounts.find((item) => item.kind === 'account') || this.result.amounts[0];
    if (!amount) { return t('服务未返回余额明细。'); }
    return amount.label + ' · ' + (amount.unlimited ? t('无限额') : amount.total === undefined ? t('未返回额度') : amount.currency + ' ' + amount.total);
  }

  build() {
    Column({ space: 8 }) {
      if (this.compact) {
        Row({ space: 8 }) {
          Button(this.summary()).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.text).layoutWeight(1)
            .id('balance-summary-' + this.draft.id).onClick(() => { this.expanded = !this.expanded; })
          Button(this.loading ? t('查询中') : t('刷新')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.text)
            .id('balance-refresh-' + this.draft.id).enabled(!this.loading && !this.disabled && this.active).onClick(() => this.refresh())
        }.width('100%')
      }
      if (this.result && this.error) {
        Text(t('上次结果 · 本次刷新失败')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
      }
      if (this.result && (!this.compact || this.expanded)) {
              if (this.result.amounts.length === 0) {
                Text(t('服务未返回余额明细。')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              ForEach(this.result.amounts, (amount: BalanceAmount) => {
                Column({ space: 4 }) {
                  Text(amount.label).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                  Text(amount.unlimited ? t('无限额') : amount.total === undefined ? t('未返回额度') : amount.currency + ' ' + amount.total).fontFamily(this.appearance.fontFamily).fontSize(20)
                    .fontColor($r('app.color.text_primary')).id('balance-' + this.draft.id + '-' + amount.kind + '-' + amount.label + '-' + amount.currency)
                  if (amount.granted !== undefined && amount.toppedUp !== undefined) {
                    Text(t('赠送余额 {0} · 充值余额 {1}', [amount.granted, amount.toppedUp]))
                      .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }
                  if (amount.used !== undefined) {
                    Text(t('已用：{0}', [amount.currency + ' ' + amount.used])).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }
                  if (amount.limit !== undefined) {
                    Text(t('总额度：{0}', [amount.currency + ' ' + amount.limit])).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }
                  if (amount.resetAt) {
                    Text(t('重置时间：{0}', [new Date(amount.resetAt).toLocaleString(getLocale())])).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                  }
                }.width('100%').alignItems(HorizontalAlign.Start)
              }, (amount: BalanceAmount) => amount.kind + '-' + amount.label + '-' + amount.currency)
              if (this.result.available !== undefined) {
                Text(this.result.available ? t('账户余额可用于 API 调用') : t('账户余额不足，暂不可调用 API'))
                  .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              if (this.result.notice) {
                Text(this.result.notice).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              Text(t('查询时间：{0}', [new Date(this.result.checkedAt).toLocaleString(getLocale())]))
                .fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
      if (this.result && this.compact && !this.expanded) {
        Text(t('查询时间：{0}', [new Date(this.result.checkedAt).toLocaleString(getLocale())]))
          .fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
      }
      if (this.error) { Banner({ text: this.error, compId: 'provider-balance-error-' + this.draft.id }) }
      if (!this.compact) {
        Button(this.loading ? t('正在查询余额…') : t('查询 / 刷新余额')).fontFamily(this.appearance.fontFamily)
          .id('query-provider-balance').attributeModifier(Btn.tonal).enabled(!this.loading && !this.disabled && this.active)
          .onClick(() => this.refresh())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
