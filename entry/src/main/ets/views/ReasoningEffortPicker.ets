import { t } from '../model/I18n';
import { reasoningEffortName } from '../model/ReasoningEffort';
import { IconButton } from '../common/Widgets';

@Component
export struct ReasoningEffortPicker {
  @Prop @Watch('syncValue') value: string = 'default';
  @Prop @Watch('syncEfforts') efforts: string[] = ['default'];
  @Prop @Watch('resetPreview') selectionKey: string = '';
  @Prop modelName: string = '';
  @Prop disabled: boolean = false;
  onSelect: (value: string) => Promise<boolean> = async () => false;
  onPreview: (value: string | undefined) => void = () => {};
  @State private previewIndex: number = 0;
  @State private saving: boolean = false;
  private dragging: boolean = false;
  private effortSignature: string = '';

  aboutToAppear(): void { this.effortSignature = this.efforts.join('|'); this.resetPreview(); }
  aboutToDisappear(): void { this.dragging = false; this.onPreview(undefined); }
  private resetPreview(): void {
    this.dragging = false;
    this.previewIndex = Math.max(0, this.efforts.indexOf(this.value));
    this.onPreview(undefined);
  }
  private syncValue(): void {
    if (!this.dragging && !this.saving) this.resetPreview();
  }
  private syncEfforts(): void {
    const signature = this.efforts.join('|');
    // Parent renders allocate an equivalent array, including when saving starts.
    if (signature === this.effortSignature) return;
    this.effortSignature = signature;
    this.resetPreview();
  }
  private preview(index: number): void {
    this.previewIndex = Math.max(0, Math.min(this.efforts.length - 1, Math.round(index)));
    this.onPreview(this.efforts[this.previewIndex]);
  }
  private async select(index: number): Promise<void> {
    if (this.disabled || this.saving) return;
    this.preview(index);
    this.dragging = false;
    const value = this.efforts[this.previewIndex];
    if (value === this.value) { this.onPreview(undefined); return; }
    const key = this.selectionKey;
    this.saving = true;
    let saved = false;
    try { saved = await this.onSelect(value); }
    finally {
      this.saving = false;
      // Keep the committed stop: @Prop delivery can lag behind the save promise.
      if (!saved && key === this.selectionKey) this.resetPreview();
    }
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
          if (this.disabled || this.saving) return;
          this.dragging = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
          this.preview(value);
          // Dragging only previews; persist the selected stop once the gesture commits.
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.select(this.previewIndex);
        })
    }.width(288).padding(12)
  }
}
