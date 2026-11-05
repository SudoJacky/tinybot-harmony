import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn } from '../common/Theme';
import { Banner, GroupCard, SectionHeader } from '../common/Widgets';
import { getLocale, t } from '../model/I18n';
import { ProviderProfile } from '../model/ProviderProfiles';
import { BalanceAmount, ProviderBalance, queryProviderBalance, supportsProviderBalance } from '../services/ProviderBalance';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';

@Component
export struct ProviderBalanceCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink editor: ProviderEditorViewModel;
  @Prop profiles: ProviderProfile[] = [];
  @Prop @Watch('queryOnEntry') disabled: boolean = false;
  @Prop @Watch('visibilityChanged') active: boolean = true;
  @Prop @Watch('reset') scope: string = '';
  @State private result?: ProviderBalance = undefined;
  @State private error: string = '';
  @State private loading: boolean = false;
  private generation: number = 0;
  private alive: boolean = false;
  private queriedOnEntry: boolean = false;

  aboutToAppear(): void { this.alive = true; this.queryOnEntry(); }
  aboutToDisappear(): void { this.alive = false; this.queriedOnEntry = false; this.reset(); }
  private visibilityChanged(): void {
    if (!this.active) { this.queriedOnEntry = false; this.reset(); return; }
    this.queryOnEntry();
  }
  private queryOnEntry(): void {
    if (!this.alive || !this.active || this.disabled || this.queriedOnEntry) { return; }
    this.queriedOnEntry = true;
    // Editing credentials must not send a request on every keystroke.
    if (this.supported() && !this.editor.noApiKey && (this.editor.apiKey.trim() || this.editor.canKeepKey)) {
      this.refresh();
    }
  }
  private reset(): void { this.generation++; this.result = undefined; this.error = ''; this.loading = false; }
  private supported(): boolean { return supportsProviderBalance(this.editor.protocol, this.editor.baseUrl); }
  private async refresh(): Promise<void> {
    if (!this.alive || !this.active || this.loading || this.disabled) { return; }
    const generation = ++this.generation;
    this.loading = true; this.result = undefined; this.error = '';
    try {
      const result = await queryProviderBalance(this.editor.snapshot(), this.profiles);
      if (this.alive && generation === this.generation) { this.result = result; }
    } catch (error) {
      if (this.alive && generation === this.generation) { this.error = (error as Error).message; }
    } finally { if (this.alive && generation === this.generation) { this.loading = false; } }
  }

  build() {
    Column() {
      SectionHeader({ title: t('账户余额') })
      GroupCard() {
        Column({ space: 10 }) {
          if (this.supported()) {
            Text(t('查询此 API Key 所属账户的余额，不代表单个模型或本次对话的费用。'))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            if (this.result) {
              if (this.result.amounts.length === 0) {
                Text(t('服务未返回余额明细。')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
              }
              ForEach(this.result.amounts, (amount: BalanceAmount) => {
                Column({ space: 4 }) {
                  Text(amount.currency + ' ' + amount.total).fontFamily(this.appearance.fontFamily).fontSize(20)
                    .fontColor($r('app.color.text_primary')).id('balance-' + amount.currency)
                  Text(t('赠送余额 {0} · 充值余额 {1}', [amount.granted, amount.toppedUp]))
                    .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                }.width('100%').alignItems(HorizontalAlign.Start)
              }, (amount: BalanceAmount) => amount.currency)
              Text(this.result.available ? t('账户余额可用于 API 调用') : t('账户余额不足，暂不可调用 API'))
                .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
              Text(t('查询时间：{0}', [new Date(this.result.checkedAt).toLocaleTimeString(getLocale())]))
                .fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
            }
            if (this.error) { Banner({ text: this.error, compId: 'provider-balance-error' }) }
            Button(this.loading ? t('正在查询余额…') : t('查询 / 刷新余额')).fontFamily(this.appearance.fontFamily)
              .id('query-provider-balance').attributeModifier(Btn.tonal).enabled(!this.loading && !this.disabled)
              .onClick(() => this.refresh())
          } else {
            Text(t('当前服务尚未接入余额查询，请到服务商控制台查看。'))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
          }
        }.padding(12).width('100%').alignItems(HorizontalAlign.Start)
      }
    }.width('100%')
  }
}
