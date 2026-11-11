import { LengthMetrics, curves } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Motion, Space } from '../common/Theme';
import { t } from '../model/I18n';

export interface ContextMeterBand {
  kind: string;
  label: string;
  tokens: number;
  color: string;
}

// Native adaptation of Bencho's Context meter, https://bencho.dev/blocks/context-meter.
@Component
export struct ContextMeter {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('updateFigure') bands: ContextMeterBand[] = [];
  @Prop @Watch('updateFigure') used: number = 0;
  @Prop capacity: number = 0;
  @Prop @Watch('updateFigure') selected: string = '';
  @Prop canCompact: boolean = false;
  onCompact: () => void = () => {};
  onSelect: (kind: string) => void = () => {};
  @State private order: string[] = [];
  @State private pointed: string = '';
  @State private rising: boolean = true;
  private lastFigure: number = 0;

  aboutToAppear(): void {
    // Fix the initial largest-first order so compacting shrinks bands in place.
    this.order = this.bands.slice().sort((a, b) => b.tokens - a.tokens).map((band) => band.kind);
    this.lastFigure = this.figure();
  }

  private band(kind: string): ContextMeterBand | undefined {
    return this.bands.find((item) => item.kind === kind);
  }

  private activeBand(): ContextMeterBand | undefined {
    const band = this.band(this.pointed || this.selected);
    return band && band.tokens > 0 ? band : undefined;
  }

  private figure(): number { return this.activeBand()?.tokens ?? this.used; }

  private updateFigure(): void {
    const figure = this.figure();
    if (figure === this.lastFigure) { return; }
    this.rising = figure > this.lastFigure;
    this.lastFigure = figure;
  }

  private point(kind: string, active: boolean): void {
    if (active) { this.pointed = kind; }
    else if (this.pointed === kind) { this.pointed = ''; }
    this.updateFigure();
  }

  private compact(value: number): string {
    if (value >= 1000000) { return (value / 1000000).toFixed(2).replace(/\.?0+$/, '') + 'M'; }
    if (value >= 1000) { return (value / 1000).toFixed(1).replace(/\.0$/, '') + 'K'; }
    return value.toString();
  }

  private occupied(): number {
    return this.capacity > 0 ? Math.min(1, Math.max(0, this.used / this.capacity)) : 0;
  }

  private estimateTotal(): number {
    return this.bands.reduce((sum, band) => sum + band.tokens, 0);
  }

  private segmentWeight(kind: string): number {
    const total = this.estimateTotal();
    // The calibrated count sets the fill. Local estimates only divide it among categories.
    return total > 0 ? (this.band(kind)?.tokens || 0) / total * this.occupied() : 0;
  }

  private visibleKinds(): string[] {
    return this.order.filter((kind) => (this.band(kind)?.tokens || 0) > 0);
  }

  private corners(first: boolean, last: boolean): BorderRadiuses {
    // Round the two outside ends and keep the seams between bands nearly square.
    return { topLeft: first ? 6 : 2, bottomLeft: first ? 6 : 2,
      topRight: last ? 6 : 2, bottomRight: last ? 6 : 2 };
  }

  @Builder
  chip(kind: string) {
    Button({ type: ButtonType.Capsule }) {
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(2).backgroundColor(this.band(kind)?.color || this.appearance.accent)
        Text(this.band(kind)?.label).fontFamily(this.appearance.fontFamily).fontSize(13)
          .fontColor($r('app.color.text_primary'))
      }
    }.id('context-category-' + kind).constraintSize({ minHeight: 36 }).padding({ left: 12, right: 12 })
      .backgroundColor(this.activeBand()?.kind === kind ? $r('app.color.surface_variant') : $r('app.color.page_background'))
      .focusOnTouch(false).clickEffect(Motion.press)
      .accessibilitySelected(this.selected === kind)
      .accessibilityText((this.band(kind)?.label || '') + ' · ~' + (this.band(kind)?.tokens || 0) + ' tokens')
      .onHover((hover: boolean) => this.point(kind, hover))
      .onFocus(() => this.point(kind, true)).onBlur(() => this.point(kind, false))
      .onClick(() => this.onSelect(kind))
  }

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Text(t('上下文窗口')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button(t('压缩')).fontFamily(this.appearance.fontFamily).id('compact-history').attributeModifier(Btn.tonalSmall)
          .enabled(this.canCompact).onClick(this.onCompact)
      }.width('100%')
      Row({ space: 6 }) {
        Row() {
          // Count places from the right so inserting a leading digit leaves the other keys alone.
          ForEach(this.compact(this.figure()).split(''), (digit: string, index: number) => {
            Text(digit).fontFamily(this.appearance.fontFamily).fontSize(30).fontWeight(FontWeight.Medium)
              .fontColor(!this.activeBand() && this.occupied() >= 0.85 ? $r('app.color.danger') : $r('app.color.text_primary'))
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.translate({ y: this.rising ? 5 : -5 }).combine(TransitionEffect.OPACITY)
                  .animation({ duration: 330, delay: index * 35, curve: curves.cubicBezierCurve(0.34, 1.25, 0.64, 1) }),
                TransitionEffect.OPACITY.animation({ duration: 130 })))
          }, (digit: string, index: number) => (this.compact(this.figure()).length - 1 - index) + ':' + digit)
        }.height(40).clip(true)
        Text(this.activeBand()?.label || '/ ' + this.compact(this.capacity) + ' tokens')
          .fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary'))
      }.alignItems(VerticalAlign.Bottom).accessibilityGroup(true)
        .accessibilityText(this.activeBand() ? this.activeBand()?.label + ' · ~' + this.figure() + ' tokens' :
          t('约 {0} / {1} tokens', [this.used, this.capacity]))
      Row({ space: 3 }) {
        if (this.occupied() > 0 && this.estimateTotal() === 0) {
          Row().layoutWeight(this.occupied()).height('100%').borderRadius(this.corners(true, this.occupied() === 1))
            .backgroundColor(this.appearance.accent)
        }
        ForEach(this.visibleKinds(), (kind: string, index: number) => {
          if (this.segmentWeight(kind) > 0) {
            // Animate the real layout weight so the corners keep their shape as the band changes width.
            Row().layoutWeight(this.segmentWeight(kind)).height('100%')
              .borderRadius(this.corners(index === 0, index === this.visibleKinds().length - 1 && this.occupied() === 1))
              .backgroundColor(this.band(kind)?.color || this.appearance.accent)
              .animation({ duration: 520, curve: curves.cubicBezierCurve(0.65, 0, 0.2, 1) })
              .opacity(this.activeBand() && this.activeBand()?.kind !== kind ? 0.22 : 1)
              .animation({ duration: Motion.fast, curve: Motion.standard })
              .onHover((hover: boolean) => this.point(kind, hover)).onClick(() => this.onSelect(kind))
          }
        }, (kind: string) => kind)
        if (this.occupied() < 1) {
          Row().layoutWeight(1 - this.occupied()).height('100%').borderRadius(this.corners(this.occupied() === 0, true))
            .backgroundColor($r('app.color.surface_variant'))
            .animation({ duration: 520, curve: curves.cubicBezierCurve(0.65, 0, 0.2, 1) })
            .opacity(this.activeBand() ? 0.22 : 1).animation({ duration: Motion.fast, curve: Motion.standard })
        }
      }.id('context-segment-bar').width('100%').height(40).accessibilityLevel('no-hide-descendants')
      if (this.visibleKinds().length > 0) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
          ForEach(this.visibleKinds(), (kind: string) => { this.chip(kind) }, (kind: string) => kind)
        }.width('100%')
      }
    }.id('context-meter').width('100%').alignItems(HorizontalAlign.Start)
  }
}
