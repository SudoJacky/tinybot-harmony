import { t } from '../model/I18n';
import { ToolExecutionViewModel } from '../viewmodel/SessionViewModels';
import { ToolDetails } from './ToolDetails';
import { DisclosureState } from '../viewmodel/DisclosureState';

// Owned by the message, so advancing to a new step cannot unmount an open tool sheet.
@Component
export struct ToolDetailSheet {
  @ObjectLink execution: ToolExecutionViewModel;
  @Prop title: string = '';
  onClose: () => void = () => {};
  @State private disclosure: DisclosureState = new DisclosureState();

  private statusLabel(): string {
    switch (this.execution.status) {
      case 'running': return t('执行中');
      case 'pending': return t('等待中');
      case 'complete': return t('完成');
      case 'failed': return t('失败');
      case 'cancelled': return t('已取消');
      default: return t('已中断');
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(this.statusLabel()).fontSize(12)
          .fontColor(this.execution.status === 'failed' ? $r('app.color.danger') : $r('app.color.text_secondary'))
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([$r('app.color.text_secondary')])
        }.id('close-tool-details').width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText(t('关闭')).onClick(() => this.onClose())
      }.width('100%')
      Scroll() {
        ToolDetails({ disclosure: this.disclosure, identity: this.execution.call.id,
          name: this.execution.call.function.name, argumentsText: this.execution.call.function.arguments,
          output: this.execution.output, status: this.execution.status })
      }.id('tool-detail-scroll').width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Auto)
    }.id('tool-detail-sheet').width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 24 })
  }
}
