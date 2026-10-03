import { t } from '../model/I18n';
import { reasoningEffortName } from '../model/ReasoningEffort';
import { IconButton } from '../common/Widgets';

@Component
export struct ReasoningEffortPicker {
  @Prop @Watch('syncValue') value: string = 'default';
  @Prop @Watch('syncValue') efforts: string[] = ['default'];
  @Prop modelName: string = '';
  @Prop disabled: boolean = false;
  onSelect: (value: string) => Promise<boolean> = async () => false;
  @State private previewIndex: number = 0;
  @State private saving: boolean = false;

  aboutToAppear(): void { this.syncValue(); }
  private syncValue(): void { this.previewIndex = Math.max(0, this.efforts.indexOf(this.value)); }
  private async select(index: number): Promise<void> {
    if (this.disabled || this.saving) return;
    this.previewIndex = index;
    if (this.efforts[index] === this.value) return;
    this.saving = true;
    try { await this.onSelect(this.efforts[index]); }
    finally { this.saving = false; this.syncValue(); }
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Blank().width(32)
        Column({ space: 2 }) {
          Text(reasoningEffortName(this.efforts[this.previewIndex]))
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
          Text(this.modelName).fontSize(12).fontColor($r('app.color.text_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1)
        IconButton({ icon: $r('sys.symbol.arrow_counterclockwise'), label: t('恢复默认推理强度'),
          compId: 'reset-reasoning-effort', diameter: 32, iconSize: 17,
          disabled: this.disabled || this.saving || this.value === 'default',
          onTap: () => { this.select(0); } })
      }.width('100%')
      Slider({ value: this.previewIndex, min: 0, max: this.efforts.length - 1, step: 1, style: SliderStyle.InSet })
        .id('reasoning-effort-slider').width('100%').height(44)
        .trackThickness(28).blockSize({ width: 26, height: 26 }).blockColor($r('app.color.surface'))
        .selectedColor($r('app.color.accent')).trackColor($r('app.color.surface_variant'))
        .showSteps(true).stepSize(4).stepColor($r('app.color.text_tertiary'))
        .enabled(!this.disabled && !this.saving)
        .accessibilityText(t('推理强度') + '：' + reasoningEffortName(this.efforts[this.previewIndex]))
        .onChange((value: number, mode: SliderChangeMode) => {
          this.previewIndex = Math.max(0, Math.min(this.efforts.length - 1, Math.round(value)));
          // Dragging only previews; persist the selected stop once the gesture commits.
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.select(this.previewIndex);
        })
    }.width(288).padding(12)
  }
}
