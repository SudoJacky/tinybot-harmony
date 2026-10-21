import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { ContextTokenItem } from '../model/ContextBreakdown';
import { MessageUsageSummary, summarizeUsage } from '../model/MessageUsage';
import { RequestUsage } from '../model/Usage';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Motion, Radius, Space } from '../common/Theme';

@Component
export struct ContextDetails {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @State private expanded: string[] = [];
  @State private shown: number = 12;
  @State private showBreakdown: boolean = true;
  private kinds: string[] = ['system', 'definitions', 'user', 'assistant', 'results', 'summary', 'attachments', 'overhead'];
  private colors: string[] = ['#3989F9', '#A879E8', '#D865AB', '#E3A62E', '#28AE8A', '#36A9C7', '#7685CA', '#899696'];

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
  private ratio(): number { return this.app.contextWindow > 0 ? this.app.contextUsed / this.app.contextWindow : 0; }
  private remaining(): number { return Math.max(0, this.app.contextWindow - this.app.contextUsed); }
  private compact(value: number): string {
    if (value >= 1000000) { return (value / 1000000).toFixed(2).replace(/\.?0+$/, '') + 'M'; }
    if (value >= 1000) { return (value / 1000).toFixed(1).replace(/\.0$/, '') + 'k'; }
    return value.toString();
  }
  private percent(value: number): string {
    return value > 0 && value < 0.001 ? '<0.1%' : (value * 100).toFixed(1).replace(/\.0$/, '') + '%';
  }
  private color(kind: string): string { return this.colors[this.kinds.indexOf(kind)]; }
  // Calibration describes the whole request, not each category. Preserve its occupied
  // width and use local estimates only to divide that width between categories.
  private segmentWidth(kind: string): number {
    return this.total() > 0 ? this.tokens(kind) / this.total() * Math.min(1, Math.max(0, this.ratio())) * 100 : 0;
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
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(t('上下文窗口')).fontFamily(this.appearance.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).layoutWeight(1).textAlign(TextAlign.Start)
            Text(this.compact(this.app.contextUsed) + ' / ' + this.compact(this.app.contextWindow) + ' (' + this.percent(this.ratio()) + ')')
              .fontFamily(this.appearance.fontFamily).fontSize(12)
              .fontColor(this.ratio() >= 0.85 ? $r('app.color.danger') : $r('app.color.text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
              .rotate({ angle: this.showBreakdown ? 180 : 0 })
          }.width('100%').constraintSize({ minHeight: 32 })
        }.id('context-toggle').width('100%').padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('上下文窗口') + ' ' + (this.showBreakdown ? t('收起') : t('展开')))
          .onClick(() => { this.getUIContext().animateTo({ duration: Motion.fast, curve: Motion.standard }, () => { this.showBreakdown = !this.showBreakdown; }); })
        Row() {
          ForEach(this.kinds, (kind: string) => {
            Row().width(this.segmentWidth(kind) + '%').height('100%').backgroundColor(this.color(kind))
          }, (kind: string) => kind)
          if (this.total() === 0) {
            Row().width(Math.min(1, Math.max(0, this.ratio())) * 100 + '%').height('100%').backgroundColor(this.appearance.accent)
          }
        }.id('context-segment-bar').width('100%').height(6).borderRadius(3).clip(true)
          .backgroundColor($r('app.color.surface_variant')).accessibilityText(t('约 {0} / {1} tokens', [this.app.contextUsed, this.app.contextWindow]))
        if (this.app.contextStatus.length > 0) {
          Text(this.app.contextStatus).fontFamily(this.appearance.fontFamily).id('context-status').fontSize(12).lineHeight(18).width('100%')
            .fontColor($r('app.color.text_secondary'))
        }
        if (this.showBreakdown) {
          Divider().color($r('app.color.divider'))
          Text(t('约 {0} / {1} tokens', [this.app.contextUsed, this.app.contextWindow])).id('context-label')
            .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
          Text(t('上下文构成（估算）')).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Column({ space: 2 }) {
            ForEach(this.kinds, (kind: string) => {
              Column({ space: 8 }) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 8 }) {
                    Row().width(8).height(8).borderRadius(2).backgroundColor(this.color(kind))
                    Text(this.title(kind)).fontFamily(this.appearance.fontFamily).fontSize(13).layoutWeight(1).textAlign(TextAlign.Start).fontColor($r('app.color.text_primary'))
                    Text('~' + this.tokens(kind)).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary'))
                    SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_tertiary')])
                      .rotate({ angle: this.expanded.includes(kind) ? 180 : 0 }).opacity(this.rows(kind).length > 0 ? 1 : 0)
                  }.width('100%').constraintSize({ minHeight: 36 })
                }.fontFamily(this.appearance.fontFamily).id('context-category-' + kind).width('100%').padding(0).backgroundColor(Color.Transparent)
                  .enabled(this.rows(kind).length > 0)
                  .onClick(() => { this.expanded = this.expanded.includes(kind) ? this.expanded.filter((item) => item !== kind) : this.expanded.concat([kind]); })
                if (this.expanded.includes(kind)) {
                  Column({ space: 12 }) {
                    ForEach(this.rows(kind).slice(0, this.shown), (item: ContextTokenItem) => {
                      this.metric(this.label(item), '~' + item.tokens)
                    }, (item: ContextTokenItem) => item.id)
                    if (this.rows(kind).length > this.shown) {
                      Button(t('显示更多明细')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall).onClick(() => { this.shown += 20; })
                    }
                  }.width('100%').padding(12).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
                    .id('context-items-' + kind)
                }
              }.width('100%')
            }, (kind: string) => kind)
          }.width('100%')
          Divider().color($r('app.color.divider'))
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
