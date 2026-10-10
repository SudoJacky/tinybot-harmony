import { ToolExecution } from '../model/Agent';
import { t } from '../model/I18n';
import { DisclosureStore } from '../viewmodel/DisclosureState';
import { ToolReceipt } from './ToolReceipt';

@Component
export struct OrchestrationReceipts {
  @Prop children: ToolExecution[] = [];
  disclosures: DisclosureStore = new DisclosureStore();
  onInspect: () => void = () => {};
  build() {
    Column({ space: 4 }) {
      Text(t('工具调用')).fontSize(12).fontColor($r('app.color.text_tertiary'))
      ForEach(this.children.map((child: ToolExecution) => child.call.id), (id: string) => {
        ToolReceipt({ execution: this.children.find((child: ToolExecution) => child.call.id === id) as ToolExecution,
          disclosure: this.disclosures.get(id), onInspect: this.onInspect })
      }, (id: string) => id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
