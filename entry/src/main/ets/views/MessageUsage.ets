import { t } from '../model/I18n';
import { MessageUsageSummary, summarizeUsage } from '../model/MessageUsage';
import { MessageViewModel } from '../viewmodel/SessionViewModels';
import { compactNumber, Motion, Radius } from '../common/Theme';

@Component
export struct MessageUsage {
  @ObjectLink message: MessageViewModel;

  private usage(): MessageUsageSummary { return summarizeUsage(this.message.steps.map(step => step.usage)); }
  private rate(): string {
    const usage = this.usage();
    const rate = usage.cacheHitRate;
    if (rate !== undefined) { return rate.toFixed(1) + '%'; }
    if (usage.cacheReports === usage.requests && usage.input === 0) { return t('不适用'); }
    return usage.cacheReports > 0 ? t('未完整报告') : t('未报告');
  }
  private summary(): string {
    const usage = this.usage();
    return t('模型用时 {0}s', [(usage.durationMs / 1000).toFixed(1)]) +
      (usage.reported > 0 ? t(' · 输入 {0} · 输出 {1}', [compactNumber(usage.input), compactNumber(usage.output)]) : '') +
      t(' · 缓存命中 {0}', [this.rate()]) +
      (usage.reported < usage.requests ? t(' · {0} 次用量未报告', [usage.requests - usage.reported]) : '');
  }
  private tokens(value: number, reports: number): string {
    if (reports === 0) { return t('未报告'); }
    return value.toString() + (reports < this.usage().requests ? t('（部分）') : '');
  }

  @Builder
  detail(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(value).fontSize(12).fontColor($r('app.color.text_primary')).textAlign(TextAlign.End)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  build() {
    if (this.usage().requests > 0) {
      Column({ space: 8 }) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          Row({ space: 6 }) {
            Text(this.summary()).fontSize(11).fontColor($r('app.color.text_tertiary')).layoutWeight(1)
              .textAlign(TextAlign.Start)
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.message.usageOpen ? 180 : 0 })
          }.width('100%').padding({ top: 8, bottom: 8 })
        }.id('usage-' + this.message.id).width('100%').backgroundColor(Color.Transparent)
          .borderRadius(Radius.sm).clickEffect(Motion.pressSmall)
          .accessibilityText(this.summary() + ' · ' + (this.message.usageOpen ? t('收起用量详情') : t('展开用量详情')))
          .onClick(() => { this.message.usageOpen = !this.message.usageOpen; })
        if (this.message.usageOpen) {
          Column({ space: 10 }) {
            Text(t('本条回复用量')).fontSize(13).fontColor($r('app.color.text_primary'))
            this.detail(t('模型请求'), t('{0} 次', [this.usage().requests]))
            this.detail(t('累计模型用时'), (this.usage().durationMs / 1000).toFixed(1) + 's')
            this.detail(t('总 Token'), this.tokens(this.usage().input + this.usage().output, this.usage().reported))
            this.detail(t('输入 Token'), this.tokens(this.usage().input, this.usage().reported))
            this.detail(t('输出 Token'), this.tokens(this.usage().output, this.usage().reported))
            this.detail(t('缓存命中率'), this.rate())
            this.detail(t('缓存读取 Token'), this.tokens(this.usage().cached, this.usage().cacheReports))
            this.detail(t('缓存写入 Token'), this.tokens(this.usage().cacheWrite, this.usage().writeReports))
            this.detail(t('推理 Token'), this.tokens(this.usage().reasoning, this.usage().reasoningReports))
          }.id('usage-details-' + this.message.id).width('100%').alignItems(HorizontalAlign.Start)
            .padding(12).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }
}
