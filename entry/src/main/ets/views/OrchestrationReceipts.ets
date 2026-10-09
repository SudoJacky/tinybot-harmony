import { ToolExecution } from '../model/Agent';
import { t } from '../model/I18n';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { ToolDetails } from './ToolDetails';

@Component
struct ChildReceipt {
  @Prop child: ToolExecution;
  onInspect: () => void = () => {};
  @State private disclosure: DisclosureState = new DisclosureState();
  private status(): string {
    if (this.child.status === 'complete') { return t('完成'); }
    if (this.child.status === 'failed') { return t('失败'); }
    if (this.child.status === 'running') { return t('执行中'); }
    if (this.child.status === 'pending') { return t('等待中'); }
    return this.child.status === 'cancelled' ? t('已取消') : t('已中断');
  }
  build() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(this.child.call.function.name).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text(this.status()).fontSize(12).fontColor(this.child.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.disclosure.open ? 180 : 0 })
      }.id('nested-tool-' + this.child.call.id).width('100%').constraintSize({ minHeight: 44 })
      .onClick(() => { this.onInspect(); this.disclosure.open = !this.disclosure.open; })
      if (this.disclosure.open) {
        ToolDetails({ disclosure: this.disclosure, identity: this.child.call.id, name: this.child.call.function.name,
          argumentsText: this.child.call.function.arguments, output: this.child.output, status: this.child.status, onInspect: this.onInspect })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct OrchestrationReceipts {
  @Prop children: ToolExecution[] = [];
  onInspect: () => void = () => {};
  build() {
    Column({ space: 4 }) {
      Text(t('工具调用')).fontSize(12).fontColor($r('app.color.text_tertiary'))
      ForEach(this.children, (child: ToolExecution) => {
        ChildReceipt({ child: child, onInspect: this.onInspect })
      }, (child: ToolExecution) => child.call.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
