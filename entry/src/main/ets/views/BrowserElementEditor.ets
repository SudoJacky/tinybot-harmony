import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { colorHsv, hsvColor } from '../model/Appearance';
import { MAX_BROWSER_ANNOTATION_NOTE } from '../model/BrowserAnnotationContent';
import { BROWSER_STYLE_PROPERTIES, BrowserElementSelection } from '../model/BrowserScripts';
import { t } from '../model/I18n';

interface NumericStyle { min: number; max: number; step: number; unit: string; }

@Component
export struct BrowserElementEditor {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop selection: BrowserElementSelection | undefined = undefined;
  @Prop captureEnabled: boolean = false;
  @Prop capturing: boolean = false;
  @Prop showProperties: boolean = true;
  onStyle: (property: string, value: string) => Promise<boolean> = async () => false;
  onReset: () => Promise<boolean> = async () => false;
  onCancel: () => void = () => {};
  onToggleProperties: () => void = () => {};
  onCapture: (note: string, draw: boolean) => Promise<void> = async () => {};
  @State private note: string = '';
  @State private property: string = '';
  @State private value: string = '';
  @State private typed: boolean = false;
  @State private working: boolean = false;
  @State private hue: number = 0;
  @State private saturation: number = 0;
  @State private colorValue: number = 0;
  @State private paletteWidth: number = 1;
  private pendingValue?: string;
  private readonly paletteHeight: number = 92;
  private readonly hueGradient: LinearGradient = new LinearGradient([
    { color: '#FF0000', offset: 0 }, { color: '#FFFF00', offset: 1 / 6 }, { color: '#00FF00', offset: 2 / 6 },
    { color: '#00FFFF', offset: 3 / 6 }, { color: '#0000FF', offset: 4 / 6 }, { color: '#FF00FF', offset: 5 / 6 },
    { color: '#FF0000', offset: 1 }
  ]);

  private title(property: string): string {
    switch (property) {
      case 'color': return t('文字颜色');
      case 'background-color': return t('背景颜色');
      case 'font-size': return t('字号');
      case 'font-weight': return t('字重');
      case 'padding': return t('内边距');
      case 'border-width': return t('边框宽度');
      case 'opacity': return t('不透明度');
      case 'font-family': return t('字体');
      default: return t('文本');
    }
  }
  private computed(property: string): string {
    return this.selection?.values[BROWSER_STYLE_PROPERTIES.indexOf(property)] || '';
  }
  private current(property: string): string {
    const change = this.selection?.changes.find((item) => item.property === property);
    return !this.color(property) && change ? change.after : this.computed(property);
  }
  private numeric(property: string): NumericStyle | undefined {
    if (property === 'opacity') { return { min: 0, max: 1, step: 0.01, unit: '' }; }
    if (property === 'font-weight') { return { min: 100, max: 900, step: 100, unit: '' }; }
    const current = parseFloat(this.computed(property)) || 0;
    if (property === 'border-width') { return { min: 0, max: Math.max(24, current), step: 1, unit: 'px' }; }
    if (property === 'padding' || property === 'font-size') {
      return { min: 0, max: Math.max(96, current), step: 1, unit: 'px' };
    }
    return undefined;
  }
  private hex(value: string): string {
    if (/^#[a-f0-9]{6}$/i.test(value)) { return value; }
    const match = /^rgba?\(\s*(\d+)[, ]+\s*(\d+)[, ]+\s*(\d+)/i.exec(value);
    if (!match) { return '#000000'; }
    return '#' + match.slice(1, 4).map((channel) => Number(channel).toString(16).padStart(2, '0')).join('');
  }
  private color(property: string): boolean { return property === 'color' || property === 'background-color'; }

  private async choose(property: string): Promise<void> {
    if (this.working || this.capturing || !await this.commit()) { return; }
    this.property = this.property === property ? '' : property;
    this.value = this.current(this.property);
    if (this.color(this.property)) {
      const hsv = colorHsv(this.hex(this.value), this.hue);
      this.hue = hsv.hue; this.saturation = hsv.saturation; this.colorValue = hsv.value;
    }
  }
  private async commit(): Promise<boolean> {
    if (!this.typed) { return true; }
    this.working = true;
    try {
      const value = this.property === 'text' ? this.value : this.value.trim();
      if (!await this.onStyle(this.property, value)) { return false; }
      this.typed = false;
      if (this.color(this.property)) {
        const hsv = colorHsv(this.hex(value), this.hue);
        this.hue = hsv.hue; this.saturation = hsv.saturation; this.colorValue = hsv.value;
      }
      return true;
    } finally { this.working = false; }
  }
  private async preview(value: string): Promise<void> {
    if (this.capturing) { return; }
    this.value = value; this.typed = false; this.pendingValue = value;
    if (this.working) { return; }
    this.working = true;
    try {
      while (this.pendingValue !== undefined) {
        const next = this.pendingValue; this.pendingValue = undefined;
        if (!await this.onStyle(this.property, next)) { this.pendingValue = undefined; break; }
      }
    } finally { this.working = false; }
  }
  private async capture(draw: boolean): Promise<void> {
    if (this.working || this.capturing || !await this.commit()) { return; }
    await this.onCapture(this.note, draw);
  }
  private async reset(): Promise<void> {
    if (this.working || this.capturing) { return; }
    this.working = true;
    try {
      if (await this.onReset()) { this.property = ''; this.typed = false; }
    } finally { this.working = false; }
  }
  private selectColor(event: GestureEvent): void {
    const point = event.fingerList.find((finger: FingerInfo) => !!finger);
    if (!point) { return; }
    this.saturation = Math.max(0, Math.min(1, point.localX / this.paletteWidth));
    this.colorValue = 1 - Math.max(0, Math.min(1, point.localY / this.paletteHeight));
    this.preview(hsvColor(this.hue, this.saturation, this.colorValue));
  }

  @Builder
  private colorPicker() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack() {
        Column().width('100%').height('100%').backgroundColor(hsvColor(this.hue, 1, 1))
          .linearGradient({ direction: GradientDirection.Right, colors: [['#FFFFFFFF', 0], ['#00FFFFFF', 1]] })
        Column().width('100%').height('100%')
          .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0], ['#FF000000', 1]] })
      }.width('100%').height('100%').borderRadius(Radius.sm).clip(true).hitTestBehavior(HitTestMode.None)
      Circle().width(16).height(16).fill(hsvColor(this.hue, this.saturation, this.colorValue))
        .stroke(Color.White).strokeWidth(2).shadow({ radius: 2, color: '#66000000' })
        .position({ x: this.paletteWidth * this.saturation - 8, y: this.paletteHeight * (1 - this.colorValue) - 8 })
        .hitTestBehavior(HitTestMode.None)
    }.width('100%').height(this.paletteHeight).accessibilityLevel('no-hide-descendants')
      .onAreaChange((_old: Area, area: Area) => { this.paletteWidth = Math.max(1, Number(area.width)); })
      .priorityGesture(GestureGroup(GestureMode.Exclusive,
        PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.All, distance: 0 })
          .onActionStart((event: GestureEvent) => this.selectColor(event))
          .onActionUpdate((event: GestureEvent) => this.selectColor(event)),
        TapGesture().onAction((event: GestureEvent) => this.selectColor(event))))
    Slider({ value: this.hue, min: 0, max: 360, step: 1 }).width('100%').height(30)
      .trackColor(this.hueGradient).trackThickness(10).selectedColor(Color.Transparent).blockSize({ width: 16, height: 16 })
      .blockColor(hsvColor(this.hue, 1, 1)).blockBorderColor(Color.White).blockBorderWidth(2)
      .accessibilityText(t('色相')).onChange((hue: number) => {
        this.hue = hue; this.preview(hsvColor(hue, this.saturation, this.colorValue));
      })
  }

  @Builder
  private numericSlider(config: NumericStyle) {
    Slider({ value: this.sliderValue(config), min: config.min, max: config.max, step: config.step })
      .id('browser-annotation-number-' + this.property).width('100%').height(36).showTips(true, this.value)
      .selectedColor(this.appearance.accent).accessibilityText(this.title(this.property))
      .onChange((value: number) => this.preview(String(Number(value.toFixed(2))) + config.unit))
  }

  private sliderValue(config: NumericStyle): number {
    const first = this.value.trim().split(/\s+/)[0];
    const compatible = config.unit ? first.endsWith(config.unit) : /^\d+(?:\.\d+)?$/.test(first);
    return (compatible ? parseFloat(first) : parseFloat(this.computed(this.property))) || 0;
  }

  @Builder
  private propertyRow(property: string) {
    Column() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: Space.xs }) {
          Text(this.title(property)).fontFamily(this.appearance.fontFamily).fontSize(Font.small).layoutWeight(1)
            .fontColor($r('app.color.text_primary'))
          Row({ space: Space.xs }) {
            if (this.color(property)) {
              Circle().width(15).height(15).fill(this.hex(this.current(property)))
                .stroke($r('app.color.divider')).strokeWidth(0.5)
            }
            Text(this.current(property)).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary')).constraintSize({ maxWidth: 136 })
          }.padding({ left: 8, right: 8, top: 5, bottom: 5 }).borderRadius(Radius.sm)
            .backgroundColor($r('app.color.surface_variant'))
        }.width('100%')
      }.id('browser-annotation-property-' + property).height(38).width('100%').padding({ left: 4, right: 4 })
        .backgroundColor(Color.Transparent).enabled(!this.capturing).onClick(() => this.choose(property))
      if (this.property === property) {
        Column({ space: 2 }) {
          Row({ space: Space.xs }) {
            TextInput({ text: this.value }).id('browser-annotation-value').fontFamily(this.appearance.fontFamily)
              .fontSize(Font.small).height(34).layoutWeight(1).maxLength(property === 'text' ? 160 : 120)
              .accessibilityText(this.title(property)).enterKeyType(EnterKeyType.Done)
              .onChange((value: string) => { this.value = value; this.typed = true; })
              .onSubmit(() => { if (!this.working) { this.commit(); } })
            IconButton({ icon: $r('sys.symbol.checkmark'), label: t('应用样式'), diameter: 34, iconSize: 15,
              disabled: !this.typed || this.working, onTap: () => this.commit() })
          }.width('100%')
          if (this.numeric(property)) { this.numericSlider(this.numeric(property)!) }
          if (this.color(property)) { this.colorPicker() }
        }.padding({ left: 4, right: 4, bottom: 4 }).width('100%')
      }
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
    }.width('100%')
  }

  build() {
    Column({ space: Space.xs }) {
      Row({ space: Space.xs }) {
        IconButton({ icon: $r('sys.symbol.gearshape'), label: t('元素属性'), compId: 'browser-annotation-properties',
          diameter: 36, iconSize: 16, disabled: this.capturing, onTap: this.onToggleProperties })
        TextArea({ text: this.note, placeholder: t('描述这些修改…') }).id('browser-annotation-note')
          .height(46).layoutWeight(1).fontFamily(this.appearance.fontFamily).fontSize(Font.small)
          .maxLength(MAX_BROWSER_ANNOTATION_NOTE)
          .onChange((value: string) => { this.note = value; })
      }.width('100%')
      Row({ space: Space.xs }) {
        Text('<' + (this.selection?.tag || '') + '>').fontFamily(this.appearance.fontFamily).fontSize(Font.caption)
          .fontColor(this.appearance.accent).fontWeight(FontWeight.Medium)
        Text(this.selection?.label || this.selection?.location || '').id('browser-selected-element')
          .fontFamily(this.appearance.fontFamily).fontSize(Font.caption).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_secondary'))
      }.width('100%').padding({ left: Space.xs, right: Space.xs })
      if (!this.selection?.mark) {
        Text(t('选中元素不在可见区域，请滚动到该元素。')).fontSize(Font.caption).fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (this.showProperties) {
        Scroll() {
          Column() {
            if (this.selection?.textEditable) { this.propertyRow('text') }
            ForEach(['color', 'background-color', 'border-width', 'opacity', 'font-family', 'font-size', 'font-weight', 'padding'], (property: string) => {
              this.propertyRow(property)
            }, (property: string) => property)
          }.width('100%')
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      } else { Blank() }
      Row({ space: Space.xs }) {
        Button(t('取消')).attributeModifier(Btn.textSmall).id('browser-clear-element')
          .enabled(!this.capturing && !this.working).onClick(this.onCancel)
        if (this.selection?.edited) {
          Button(t('重置样式')).attributeModifier(Btn.textSmall).id('browser-reset-style')
            .enabled(!this.capturing && !this.working).onClick(() => this.reset())
        }
        Blank()
        IconButton({ icon: $r('sys.symbol.square_and_pencil'), label: t('在截图上圈画批注'), compId: 'browser-annotation-draw',
          diameter: 34, iconSize: 15, disabled: !this.captureEnabled || this.capturing || this.working,
          onTap: () => this.capture(true) })
        Button(this.capturing ? t('添加中…') : t('添加批注')).id('browser-annotate-element').attributeModifier(Btn.primarySmall)
          .enabled(this.captureEnabled && !this.capturing && !this.working).onClick(() => this.capture(false))
      }.width('100%')
    }.id('browser-element-editor').width('100%').height('100%').padding(Space.sm)
      .backgroundColor($r('app.color.surface')).borderRadius(Radius.lg).border({ width: 0.5, color: $r('app.color.divider') })
      .shadow({ radius: 12, color: '#28000000', offsetY: 3 })
  }
}
