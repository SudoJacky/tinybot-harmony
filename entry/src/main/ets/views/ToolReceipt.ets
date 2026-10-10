import { ToolExecution } from '../model/Agent';
import { t } from '../model/I18n';
import { toolTitle, toolStat, toolStatusLabel } from '../model/ToolPresentation';
import { DisclosureState } from '../viewmodel/DisclosureState';
import { ToolDetails } from './ToolDetails';

// Shared by Team and nested orchestration calls; the owner retains reading state across collapse.
@Component
export struct ToolReceipt {
  @Prop execution: ToolExecution;
  @ObjectLink disclosure: DisclosureState;
  onInspect: () => void = () => {};
  build() {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Text(toolTitle(this.execution.call.function.name)).fontSize(13).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.execution.status === 'running') {
          LoadingProgress().width(14).height(14).color($r('app.color.accent'))
        }
        Text(toolStat(this.execution.call.function.name, this.execution.call.function.arguments, this.execution.output, this.execution.status) ||
          toolStatusLabel(this.execution.status)).fontSize(12)
          .fontColor(this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(10).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.disclosure.open ? 180 : 0 })
      }.id('nested-tool-' + this.execution.call.id).width('100%').constraintSize({ minHeight: 44 })
      .accessibilityText((this.disclosure.open ? t('收起') : t('展开')) + ' ' + toolTitle(this.execution.call.function.name) + ' ' + toolStatusLabel(this.execution.status))
      .onClick(() => { this.onInspect(); this.disclosure.open = !this.disclosure.open; })
      if (this.disclosure.open) {
        ToolDetails({ disclosure: this.disclosure, identity: this.execution.call.id, name: this.execution.call.function.name,
          argumentsText: this.execution.call.function.arguments, output: this.execution.output, status: this.execution.status, onInspect: this.onInspect })
        ForEach((this.execution.children || []).map((child: ToolExecution) => child.call.id), (id: string) => {
          ToolReceipt({ execution: this.execution.children?.find((child: ToolExecution) => child.call.id === id) as ToolExecution,
            disclosure: this.disclosure.children.get(id), onInspect: this.onInspect })
        }, (id: string) => id)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
