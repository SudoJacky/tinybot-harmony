import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { ContextTokenItem } from '../model/ContextBreakdown';
import { MessageUsageSummary, summarizeUsage } from '../model/MessageUsage';
import { RequestUsage } from '../model/Usage';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Motion, Radius, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { ContextMeter, ContextMeterBand } from './ContextMeter';

@Component
export struct ContextDetails {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onCompact: () => void = () => {};
  @State private selected: string = '';
  @State private shown: number = 12;
  @State private showBreakdown: boolean = false;
  private kinds: string[] = ['system', 'definitions', 'user', 'assistant', 'results', 'summary', 'attachments', 'overhead'];
  // Keep the cool rose-to-green palette while giving each actual request category its own swatch.
  private colors: string[] = ['#EC4F8C', '#9A5CF6', '#1DB4CC', '#168D9E', '#665FE0', '#2CCB7E', '#3D7EF5', '#899696'];

  private title(kind: string): string {
    switch (kind) {
      case 'system': return t('系统指令');
      case 'definitions': return t('工具定义');
      case 'user': return t('用户输入');
      case 'assistant': return t('助手内容');
      case 'results': return t('工具结果');
      case 'summary': return t('历史摘要');
      case 'attachments': return t('附件与引用');
      default: return t('消息格式开销');
    }
  }
  private rows(kind: string): ContextTokenItem[] { return this.app.contextDetails.filter((item) => item.kind === kind); }
  private tokens(kind: string): number { return this.rows(kind).reduce((sum, item) => sum + item.tokens, 0); }
  private total(): number { return this.app.contextDetails.reduce((sum, item) => sum + item.tokens, 0); }
  private remaining(): number { return Math.max(0, this.app.contextWindow - this.app.contextUsed); }
  private percent(value: number): string {
    return value > 0 && value < 0.001 ? '<0.1%' : (value * 100).toFixed(1).replace(/\.0$/, '') + '%';
  }

  private bands(): ContextMeterBand[] {
    const totals = new Map<string, number>();
    for (const item of this.app.contextDetails) { totals.set(item.kind, (totals.get(item.kind) || 0) + item.tokens); }
    return this.kinds.map((kind, index): ContextMeterBand => ({
      kind: kind, label: this.title(kind), tokens: totals.get(kind) || 0, color: this.colors[index]
    }));
  }

  private selectKind(kind: string): void {
    this.selected = this.selected === kind ? '' : kind;
    this.shown = 12;
  }
  private label(item: ContextTokenItem): string {
    if (item.name === 'draft') { return t('输入框草稿'); }
    if (item.name === 'references') { return t('待发送的会话引用'); }
    const users = this.app.active.messages.filter((message) => message.role === 'user');
    const turn = users.findIndex((message) => message.id === item.messageId);
    let label = turn < 0 ? '' : t('第 {0} 轮', [turn + 1]);
    if (item.step !== undefined) { label += ' · ' + t('第 {0} 步', [item.step + 1]); }
    let name = item.name || '';
    if (name === 'reasoning') { name = t('推理内容'); }
    if (name === 'tool_calls') { name = t('工具调用参数'); }
    if (name === 'history_references') { name = t('会话引用'); }
    const sections: Record<string, string> = { 'identity': t('身份与基础指令'), 'runtime': t('运行规则'),
      'interactive_ui': t('交互界面指令'), 'user_preferences': t('用户偏好'), 'skills': 'Skills', 'memory': t('长期记忆'),
      'tools': t('工具使用说明'), 'tool_guidelines': t('工具使用规则'), 'team': t('团队指令'), 'branch': t('分支说明') };
    if (item.kind === 'system') { name = sections[name] || name; }
    return (label ? label + (name ? ' · ' + name : '') : name) || this.title(item.kind);
  }
  private records(): (RequestUsage | undefined)[] {
    return this.app.active.messages.filter((message) => message.role === 'assistant')
      .flatMap((message) => message.steps.map((step) => step.usage));
  }
  private usage(): MessageUsageSummary {
    const records = this.records(); const summary = summarizeUsage(records);
    summary.requests = records.length;
    return summary;
  }
  private counted(value: number, reports: number): string {
    return reports === 0 ? t('未报告') : value.toString() + (reports < this.usage().requests ? t('（部分）') : '');
  }
  @Builder
  metric(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(value).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_primary')).textAlign(TextAlign.End)
    }.width('100%')
  }
  build() {
    Column({ space: Space.lg }) {
      Column({ space: 12 }) {
        ContextMeter({ bands: this.bands(), used: this.app.contextUsed, capacity: this.app.contextWindow, selected: this.selected,
          canCompact: this.app.configured && !this.app.busy && !this.app.active.archived && this.app.saveError.length === 0,
          onCompact: this.onCompact, onSelect: (kind: string) => this.selectKind(kind) })
        if (this.selected && this.rows(this.selected).length > 0) {
          Column({ space: 12 }) {
            this.metric(this.title(this.selected), '~' + this.tokens(this.selected))
            ForEach(this.rows(this.selected).slice(0, this.shown), (item: ContextTokenItem) => {
              this.metric(this.label(item), '~' + item.tokens)
            }, (item: ContextTokenItem) => item.id)
            if (this.rows(this.selected).length > this.shown) {
              Button(t('显示更多明细')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall)
                .onClick(() => { this.shown += 20; })
            }
          }.id('context-items-' + this.selected).width('100%').padding(Space.md).borderRadius(Radius.sm)
            .backgroundColor($r('app.color.surface_variant'))
        }
        if (this.app.contextStatus.length > 0) {
          Text(this.app.contextStatus).fontFamily(this.appearance.fontFamily).id('context-status').fontSize(12).lineHeight(18).width('100%')
            .fontColor($r('app.color.text_secondary'))
        }
        if (this.app.error.length > 0) { Banner({ text: this.app.error, compId: 'context-error' }) }
        Divider().color($r('app.color.divider'))
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(t('上下文构成（估算）')).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).layoutWeight(1).textAlign(TextAlign.Start)
            Text(this.percent(this.app.contextWindow > 0 ? this.app.contextUsed / this.app.contextWindow : 0))
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.showBreakdown ? 180 : 0 })
          }.width('100%').constraintSize({ minHeight: 32 })
        }.id('context-toggle').width('100%').padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('上下文构成（估算）') + ' ' + (this.showBreakdown ? t('收起') : t('展开')))
          .onClick(() => { this.getUIContext().animateTo({ duration: Motion.fast, curve: Motion.standard }, () => { this.showBreakdown = !this.showBreakdown; }); })
        if (this.showBreakdown) {
          Text(t('约 {0} / {1} tokens', [this.app.contextUsed, this.app.contextWindow])).id('context-label')
            .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
          Row({ space: 8 }) {
            Row().width(8).height(8).borderRadius(2).backgroundColor($r('app.color.surface_variant'))
              .border({ width: 1, color: $r('app.color.divider') })
            Text(t('剩余空间')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
            Text(this.remaining().toString() + ' (' + this.percent(this.app.contextWindow > 0 ? this.remaining() / this.app.contextWindow : 0) + ')')
              .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
          }.id('context-free-space').width('100%')
          this.metric(t('分类估算合计'), '~' + this.total())
          Text(t('分类按实际保留的内容估算，不是账单。分类合计可能与服务端校准的占用不同。')).fontFamily(this.appearance.fontFamily)
            .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
          Text(t('色条按分类估算比例分配，总占用以校准值为准。')).fontFamily(this.appearance.fontFamily)
            .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
          Text(this.app.contextSource === 'usage+estimate' ? t('占用总量：服务端输入用量 + 后续内容估算') : t('占用总量：本地内容估算')).fontFamily(this.appearance.fontFamily)
            .fontSize(12).fontColor($r('app.color.text_tertiary'))
          if (this.app.generating) {
            Text(t('生成中展示最近一次请求的内容；输入框草稿另计，尚未发送。')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary'))
          }
        }
      }.id('context-breakdown').width('100%').alignItems(HorizontalAlign.Start)
        .padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
      Column({ space: 12 }) {
        Text(t('会话累计用量（服务端报告）')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        this.metric(t('会话模型请求'), this.usage().requests.toString())
        this.metric(t('会话累计输入'), this.counted(this.usage().input, this.usage().reported))
        this.metric(t('会话累计输出'), this.counted(this.usage().output, this.usage().reported))
        this.metric(t('缓存读取 Token'), this.counted(this.usage().cached, this.usage().cacheReports))
        this.metric(t('缓存写入 Token'), this.counted(this.usage().cacheWrite, this.usage().writeReports))
        this.metric(t('推理 Token'), this.counted(this.usage().reasoning, this.usage().reasoningReports))
        Text(t('累计当前会话聊天记录中的模型请求，不含标题、记忆整理或团队员工。缓存属于输入，推理属于输出，不重复相加。')).fontFamily(this.appearance.fontFamily)
          .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
        if (this.usage().reported < this.usage().requests) {
          Text(t('{0} 次请求尚未报告用量', [this.usage().requests - this.usage().reported])).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary'))
        }
      }.id('context-reported-usage').width('100%').alignItems(HorizontalAlign.Start)
        .padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    }.width('100%')
  }
}
