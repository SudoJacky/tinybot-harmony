import { t } from '../model/I18n';
import { ContextTokenItem } from '../model/ContextBreakdown';
import { MessageUsageSummary, summarizeUsage } from '../model/MessageUsage';
import { RequestUsage } from '../model/Usage';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Radius, Space } from '../common/Theme';

@Component
export struct ContextDetails {
  @ObjectLink app: ChatViewModel;
  @State private expanded: string[] = [];
  @State private shown: number = 12;
  private kinds: string[] = ['system', 'definitions', 'user', 'assistant', 'results', 'summary', 'attachments', 'overhead'];

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
    const answers = this.app.active.messages.filter((message) => message.role === 'assistant');
    return answers.length ? answers[answers.length - 1].steps.map((step) => step.usage) : [];
  }
  private usage(): MessageUsageSummary {
    const records = this.records(); const summary = summarizeUsage(records);
    summary.requests = records.length;
    return summary;
  }
  private latest(): RequestUsage | undefined { const records = this.records(); return records[records.length - 1]; }
  private reported(value: number | undefined): string { return value === undefined ? t('未报告') : value.toString(); }
  private counted(value: number, reports: number): string {
    return reports === 0 ? t('未报告') : value.toString() + (reports < this.usage().requests ? t('（部分）') : '');
  }
  @Builder
  metric(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
      Text(value).fontSize(13).fontColor($r('app.color.text_primary')).textAlign(TextAlign.End)
    }.width('100%')
  }
  build() {
    Column({ space: Space.lg }) {
      Column({ space: 14 }) {
        Text(t('上下文构成（估算）')).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(t('分类按实际保留的内容估算，不是账单。分类合计可能与服务端校准的占用不同。'))
          .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
        ForEach(this.kinds, (kind: string) => {
          Column({ space: 6 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text(this.title(kind)).fontSize(14).layoutWeight(1).textAlign(TextAlign.Start).fontColor($r('app.color.text_primary'))
                Text('~' + this.tokens(kind)).fontSize(13).fontColor($r('app.color.text_secondary'))
                SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(11).fontColor([$r('app.color.text_tertiary')])
                  .rotate({ angle: this.expanded.includes(kind) ? 180 : 0 })
              }.width('100%').padding({ top: 7, bottom: 7 })
            }.id('context-category-' + kind).width('100%').backgroundColor(Color.Transparent)
              .onClick(() => { this.expanded = this.expanded.includes(kind) ? this.expanded.filter((item) => item !== kind) : this.expanded.concat([kind]); })
            Progress({ value: this.tokens(kind), total: Math.max(1, this.total()), type: ProgressType.Linear })
              .width('100%').color($r('app.color.accent')).backgroundColor($r('app.color.surface_variant')).style({ strokeWidth: 3 })
            if (this.expanded.includes(kind)) {
              ForEach(this.rows(kind).slice(0, this.shown), (item: ContextTokenItem) => {
                this.metric(this.label(item), '~' + item.tokens)
              }, (item: ContextTokenItem) => item.id)
              if (this.rows(kind).length > this.shown) {
                Button(t('显示更多明细')).attributeModifier(Btn.textSmall).onClick(() => { this.shown += 20; })
              }
            }
          }.width('100%')
        }, (kind: string) => kind)
        this.metric(t('分类估算合计'), '~' + this.total())
        Text(this.app.contextSource === 'usage+estimate' ? t('占用总量：服务端输入用量 + 后续内容估算') : t('占用总量：本地内容估算'))
          .fontSize(12).fontColor($r('app.color.text_tertiary'))
        if (this.app.generating) {
          Text(t('生成中展示最近一次请求的内容；输入框草稿另计，尚未发送。')).fontSize(12).fontColor($r('app.color.text_tertiary'))
        }
      }.id('context-breakdown').width('100%').alignItems(HorizontalAlign.Start)
        .padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
      Column({ space: 12 }) {
        Text(t('实际用量（服务端报告）')).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        this.metric(t('最近一次输入'), this.reported(this.latest()?.tokens?.input))
        this.metric(t('最近一次输出'), this.reported(this.latest()?.tokens?.output))
        this.metric(t('本轮模型请求'), this.usage().requests.toString())
        this.metric(t('本轮累计输入'), this.counted(this.usage().input, this.usage().reported))
        this.metric(t('本轮累计输出'), this.counted(this.usage().output, this.usage().reported))
        this.metric(t('缓存读取 Token'), this.counted(this.usage().cached, this.usage().cacheReports))
        this.metric(t('缓存写入 Token'), this.counted(this.usage().cacheWrite, this.usage().writeReports))
        this.metric(t('推理 Token'), this.counted(this.usage().reasoning, this.usage().reasoningReports))
        Text(t('仅统计本轮聊天记录中的模型请求，不含标题、记忆整理或团队员工。缓存属于输入，推理属于输出，不重复相加。'))
          .fontSize(12).lineHeight(18).fontColor($r('app.color.text_tertiary'))
        if (this.usage().reported < this.usage().requests) {
          Text(t('{0} 次请求尚未报告用量', [this.usage().requests - this.usage().reported])).fontSize(12).fontColor($r('app.color.text_tertiary'))
        }
      }.id('context-reported-usage').width('100%').alignItems(HorizontalAlign.Start)
        .padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
    }.width('100%')
  }
}
