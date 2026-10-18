import { AppearanceStyle } from './AppearanceStyle';
import { t } from '../model/I18n';
import { Btn, Font, Motion, Radius, Space } from './Theme';
import { LiquidToggle } from './LiquidToggle';
import { AnimatorResult, ColorMetrics, uiMaterial } from '@kit.ArkUI';
import { SegmentFrame, SegmentedMotion } from './SegmentedMotion';
import { WindowViewport } from '../viewmodel/WindowViewport';

@Component
export struct IconButton {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop icon: Resource = $r('sys.symbol.plus');
  @Prop tint: ResourceColor = $r('app.color.text_primary');
  @Prop fill: ResourceColor = Color.Transparent;
  @Prop disabled: boolean = false;
  @Prop label: string = '';
  compId: string = '';
  diameter: number = 44;
  iconSize: number = 22;
  // Native material is supported when the button lives in a navigation title bar.
  material?: uiMaterial.Material;
  onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(this.icon).fontSize(this.iconSize).fontColor([this.tint])
    }.fontFamily(this.appearance.fontFamily)
    .id(this.compId).width(this.diameter).height(this.diameter).backgroundColor(this.fill)
    .animation({ duration: Motion.fast, curve: Motion.standard })
    .clickEffect(this.disabled || this.material ? null : Motion.pressSmall)
    .enabled(!this.disabled).accessibilityText(this.label).onClick(() => this.onTap())
    .borderRadius(this.diameter / 2)
    .systemMaterial(this.material)
  }
}

@Component
export struct SectionHeader {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  @Prop caption: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      if (this.caption.length > 0) {
        Text(this.caption).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(18).fontColor($r('app.color.text_tertiary'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 4, right: 4, top: Space.lg, bottom: Space.sm })
  }
}

@Component
export struct GroupCard {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(Radius.lg).clip(true)
  }
}

@Component
export struct RowDivider {
  build() {
    Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: Space.lg })
  }
}

// The trailing mark tells what a tap does: 'chevron' opens another page,
// 'select' marks the chosen option in a list, 'expand' folds content in place.
export type RowTrailing = 'chevron' | 'select' | 'expand';

// Tappable list row with a trailing value and mark.
@Component
export struct NavRow {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop value: string = '';
  @Prop disabled: boolean = false;
  @Prop accent: boolean = false;
  // Still tappable but de-emphasized, e.g. a disabled provider.
  @Prop muted: boolean = false;
  @Prop trailing: RowTrailing = 'chevron';
  // Selected for 'select', expanded for 'expand'.
  @Prop active: boolean = false;
  icon?: Resource;
  image?: Resource;
  tintImage: boolean = false;
  compId: string = '';
  onTap: () => void = () => {};

  build() {
    Row({ space: Space.md }) {
        if (this.image || this.icon) {
          Stack() {
            if (this.image) {
              if (this.tintImage) {
                Image(this.image).width(28).height(28).objectFit(ImageFit.Contain)
                  .fillColor(this.muted ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
              } else {
                Image(this.image).width(28).height(28).objectFit(ImageFit.Contain).opacity(this.muted ? 0.5 : 1)
              }
            } else if (this.icon) {
              SymbolGlyph(this.icon).fontSize(20)
                .fontColor([this.accent ? this.appearance.accent : this.muted ? $r('app.color.text_tertiary') : $r('app.color.text_secondary')])
            }
          }.width(28).height(28).accessibilityLevel('no-hide-descendants')
      }
      Column({ space: 3 }) {
        Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(Font.body).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.accent ? this.appearance.accent : this.muted ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .fontWeight(this.accent ? FontWeight.Medium : FontWeight.Normal)
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.muted ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.value.length > 0) {
        Text(this.value).fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(1).fontColor($r('app.color.text_tertiary'))
      }
      if (this.trailing === 'select') {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.appearance.accent]).opacity(this.active ? 1 : 0)
      } else if (this.trailing === 'expand') {
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
          .rotate({ angle: this.active ? 180 : 0 }).animation({ duration: Motion.fast, curve: Motion.standard })
      } else if (!this.accent) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
      }
    }
    .id(this.compId).width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .opacity(this.disabled ? 0.4 : 1).enabled(!this.disabled)
    .accessibilityText(this.trailing === 'select' && this.active ? this.title + t("，已选中") : '')
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(() => this.onTap())
  }
}

@Component
export struct SwitchRow {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  @Prop disabled: boolean = false;
  icon?: Resource;
  compId: string = '';
  onChange: (value: boolean) => void = () => {};

  build() {
    Row({ space: Space.md }) {
      if (this.icon) {
        Stack() {
          SymbolGlyph(this.icon).fontSize(20).fontColor([$r('app.color.text_secondary')])
        }.width(28).height(28).accessibilityLevel('no-hide-descendants')
      }
      Column({ space: 3 }) {
        Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(17).fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      LiquidToggle({ isOn: this.isOn, disabled: this.disabled, label: this.title, compId: this.compId,
        onChange: (value: boolean) => this.onChange(value) })
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.md, top: 10, bottom: 10 })
    .opacity(this.disabled ? 0.4 : 1)
  }
}

// Inline status message with an optional action, e.g. save failures.
@Component
export struct Banner {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop text: string = '';
  @Prop danger: boolean = true;
  @Prop actionLabel: string = '';
  @Prop actionEnabled: boolean = true;
  compId: string = '';
  actionId: string = '';
  // Glyph for neutral banners; danger banners always use the alert mark.
  icon: Resource = $r('sys.symbol.archivebox');
  onAction: () => void = () => {};

  build() {
    Row({ space: Space.sm }) {
      SymbolGlyph(this.danger ? $r('sys.symbol.exclamationmark_circle') : this.icon).fontSize(18)
        .fontColor([this.danger ? $r('app.color.danger') : $r('app.color.text_secondary')])
      Text(this.text).fontFamily(this.appearance.fontFamily).id(this.compId).fontSize(13).lineHeight(19).layoutWeight(1)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).fontFamily(this.appearance.fontFamily).id(this.actionId).attributeModifier(Btn.textSmall)
          .enabled(this.actionEnabled).onClick(() => this.onAction())
      }
    }
    .width('100%').padding({ left: Space.md, right: Space.xs, top: 6, bottom: 6 }).constraintSize({ minHeight: 44 })
    .borderRadius(Radius.md)
    .backgroundColor(this.danger ? $r('app.color.danger_container') : $r('app.color.surface_variant'))
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 }))
      .animation({ duration: Motion.medium, curve: Motion.enter }))
  }
}

// Sticky footer for primary actions on form pages.
@Component
export struct BottomBar {
  @BuilderParam content: () => void;
  @Prop sheet: boolean = false;
  @State private viewport: WindowViewport = new WindowViewport();
  aboutToAppear(): void { if (this.sheet) { this.viewport.observe(this.getUIContext()); } }
  aboutToDisappear(): void { this.viewport.dispose(); }

  build() {
    Column() {
      this.content()
    }
    .width('100%').padding({ left: Space.page, right: Space.page, top: 10,
      bottom: 12 + (this.sheet && this.viewport.keyboardHeight === 0 ? this.viewport.bottom : 0) })
    .backgroundColor($r('app.color.page_background'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }
}

// Centered placeholder for empty lists.
@Component
export struct EmptyState {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop icon: Resource = $r('sys.symbol.doc_text');
  @Prop title: string = '';
  @Prop caption: string = '';

  build() {
    Column({ space: Space.md }) {
      SymbolGlyph(this.icon).fontSize(40).fontColor([$r('app.color.text_tertiary')])
      Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor($r('app.color.text_secondary'))
      if (this.caption.length > 0) {
        Text(this.caption).fontFamily(this.appearance.fontFamily).fontSize(13).lineHeight(19).textAlign(TextAlign.Center).fontColor($r('app.color.text_tertiary'))
      }
    }.width('100%').padding({ left: Space.xl, right: Space.xl, top: 56, bottom: 56 })
  }
}

// iOS/HarmonyOS-style segmented control. Options are short labels; onSelect receives the index.
// Shared rubber motion; each surface keeps its existing dimensions and styling.
@Component
export struct Segmented {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('resetGeometry') options: string[] = [];
  @Prop @Watch('syncSelection') selected: number = 0;
  @State private segmentWidth: number = 0;
  @State private thumbLeft: number = 0;
  @State private thumbRight: number = 0;
  controlHeight: number = 36;
  labelSize: number = 14;
  trackRadius: number = Radius.sm;
  thumbRadius: number = Radius.sm - 2;
  gap: number = 0;
  thumbShadow: boolean = true;
  optionIds: string[] = [];
  compIdPrefix: string = 'segment';
  onSelect: (index: number) => void = () => {};
  private trackWidth: number = 0;
  private animator?: AnimatorResult;
  private generation: number = 0;

  aboutToDisappear(): void { this.stopAnimation(); }

  private stopAnimation(): void {
    this.generation++;
    this.animator?.cancel();
    this.animator = undefined;
  }

  private target(): SegmentFrame {
    const index = Math.max(0, Math.min(this.options.length - 1, this.selected));
    const left = index * (this.segmentWidth + this.gap);
    return { left: left, right: left + this.segmentWidth };
  }

  private resetGeometry(): void {
    const width = this.options.length > 0 ?
      Math.max(0, (this.trackWidth - this.gap * (this.options.length - 1)) / this.options.length) : 0;
    // Callers often rebuild their label array when selection changes. That must
    // not cancel an in-flight animation when the measured slots are unchanged.
    if (Math.abs(width - this.segmentWidth) < 0.01) return;
    this.stopAnimation();
    this.segmentWidth = width;
    const target = this.target();
    this.thumbLeft = target.left;
    this.thumbRight = target.right;
  }

  private syncSelection(): void {
    this.stopAnimation();
    if (this.segmentWidth <= 0) return;
    const from: SegmentFrame = { left: this.thumbLeft, right: this.thumbRight };
    const target = this.target();
    if (Math.abs(from.left - target.left) + Math.abs(from.right - target.right) < 0.01) return;
    const generation = this.generation;
    const animator = this.getUIContext().createAnimator({
      duration: SegmentedMotion.duration, easing: 'linear', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: 0, end: 1
    });
    animator.onFrame = (progress: number): void => {
      if (generation !== this.generation) return;
      const frame = SegmentedMotion.sample(from, target, progress);
      this.thumbLeft = frame.left;
      this.thumbRight = frame.right;
    };
    animator.onFinish = (): void => {
      if (generation !== this.generation) return;
      this.thumbLeft = target.left;
      this.thumbRight = target.right;
      this.animator = undefined;
    };
    this.animator = animator;
    animator.play();
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.segmentWidth > 0) {
        Column().width(this.thumbRight - this.thumbLeft).height('100%').borderRadius(this.thumbRadius)
          .backgroundColor($r('app.color.surface'))
          .shadow({ radius: this.thumbShadow ? 4 : 0, color: this.thumbShadow ? '#14000000' : '#00000000', offsetY: 1 })
          .translate({ x: this.thumbLeft }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
      Row({ space: this.gap }) {
        ForEach(this.options, (label: string, index: number) => {
          Text(label).fontFamily(this.appearance.fontFamily).id(this.optionIds[index] || this.compIdPrefix + '-' + index)
            .fontSize(this.labelSize).layoutWeight(1).height('100%').textAlign(TextAlign.Center)
            .fontWeight(index === this.selected ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(index === this.selected ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .animation({ duration: Motion.fast, curve: Motion.standard })
            .accessibilityText(label + (index === this.selected ? t("，已选中") : ''))
            .onClick(() => this.onSelect(index))
        }, (label: string) => label)
      }.width('100%').height('100%')
      .onAreaChange((_old: Area, next: Area) => {
        const width = next.width as number;
        if (Math.abs(width - this.trackWidth) > 0.01) {
          this.trackWidth = width;
          this.resetGeometry();
        }
      })
    }.width('100%').height(this.controlHeight).padding(3).borderRadius(this.trackRadius)
    .backgroundColor($r('app.color.surface_variant'))
  }
}

// One retained status line: breathe/sheen while working, then softly settle into its final label.
@Component
export struct ThinkingLine {
  @StorageProp('tinybot.appearance.style') @Watch('syncMotion') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncMotion') private foreground: boolean = true;
  @Prop @Watch('syncState') label: string = t("正在思考…");
  @Prop @Watch('syncState') working: boolean = true;
  @Prop compact: boolean = false;
  @Prop icon: Resource = $r('sys.symbol.lightbulb');
  @Prop danger: boolean = false;
  @State private breath: number = 0.58;
  @State private sweep: number = -100;
  @State private currentLabel: string = '';
  @State private currentGlyphs: string[] = [];
  @State private previousLabel: string = '';
  @State private labelMix: number = 1;
  private mounted: boolean = false;
  private visible: boolean = false;
  private loop?: AnimatorResult;
  private settling?: AnimatorResult;
  private ink: ColorMetrics = ColorMetrics.rgba(0, 0, 0, 1);

  aboutToAppear(): void { this.mounted = true; this.currentLabel = this.label; this.currentGlyphs = Array.from(this.label); }
  aboutToDisappear(): void {
    this.mounted = false; this.visible = false; this.stopLoop(); this.stopSettle();
  }
  private stopLoop(): void { const loop = this.loop; this.loop = undefined; loop?.cancel(); }
  private stopSettle(): void { const settling = this.settling; this.settling = undefined; settling?.cancel(); }
  private syncMotion(): void {
    if (this.mounted) { this.ink = ColorMetrics.resourceColor($r('app.color.text_primary')); }
    if (!this.mounted || !this.visible || !this.foreground || this.appearance.effectStrength === 0) {
      this.stopLoop(); this.stopSettle(); this.labelMix = 1; this.previousLabel = ''; return;
    }
    if (!this.working) { this.stopLoop(); return; }
    if (this.loop) { return; }
    const loop = this.getUIContext().createAnimator({ duration: 1800, easing: 'linear', delay: 0,
      fill: 'none', direction: 'normal', iterations: -1, begin: 0, end: 1 });
    loop.onFrame = (phase: number) => {
      if (this.loop !== loop) { return; }
      this.breath = 0.58 + 0.42 * (1 - Math.cos(phase * Math.PI * 2)) / 2;
      this.sweep = -100 + phase * 400;
    };
    this.loop = loop; loop.play();
  }
  private syncState(): void {
    if (!this.mounted) { return; }
    this.syncMotion();
    if (this.currentLabel === this.label) { return; }
    this.stopSettle();
    const animate = this.visible && this.foreground && this.appearance.effectStrength > 0;
    this.previousLabel = animate ? this.currentLabel : '';
    this.currentLabel = this.label;
    this.currentGlyphs = Array.from(this.label);
    if (!animate) { this.labelMix = 1; return; }
    this.labelMix = 0;
    const settling = this.getUIContext().createAnimator({ duration: 280, easing: 'ease-out', delay: 0,
      fill: 'forwards', direction: 'normal', iterations: 1, begin: 0, end: 1 });
    settling.onFrame = (phase: number) => { if (this.settling === settling) { this.labelMix = phase; } };
    settling.onFinish = () => {
      if (this.settling !== settling) { return; }
      this.labelMix = 1; this.previousLabel = ''; this.settling = undefined;
    };
    this.settling = settling; settling.play();
  }
  private visibilityChanged(visible: boolean): void {
    this.visible = visible;
    if (!visible) { this.stopSettle(); this.labelMix = 1; this.previousLabel = ''; }
    this.syncMotion();
  }

  // Paint the sheen in glyph ink, so no compositing rectangle can escape a text mask.
  private sheenColor(index: number): ResourceColor {
    if (this.danger) { return $r('app.color.danger'); }
    if (!this.working) { return $r('app.color.text_tertiary'); }
    if (!this.foreground || this.appearance.effectStrength === 0) { return $r('app.color.text_secondary'); }
    const position = (index + 0.5) * 100 / Math.max(1, this.currentGlyphs.length);
    const shine = Math.max(0, 1 - Math.abs(position - this.sweep) / 55);
    return ColorMetrics.rgba(this.ink.red, this.ink.green, this.ink.blue, this.ink.alpha / 255 * (0.55 + 0.45 * shine)).color;
  }

  build() {
    Row({ space: this.compact ? 6 : Space.sm }) {
      if (this.compact) {
        SymbolGlyph(this.icon).fontSize(14)
          .fontColor([this.danger ? $r('app.color.danger') : $r('app.color.text_secondary')])
          .opacity(this.danger ? 1 : this.working ? this.breath : 0.62 + (this.breath - 0.62) * (1 - this.labelMix))
      } else {
        Image($r('app.media.tinybot')).width(18).height(18)
          .opacity(this.working ? this.breath : 0.62)
      }
      Stack({ alignContent: Alignment.Start }) {
        Text() {
          ForEach(this.currentGlyphs, (glyph: string, index: number) => {
            Span(glyph).fontColor(this.sheenColor(index))
          }, (glyph: string, index: number) => `${index}:${glyph}`)
        }.fontFamily(this.appearance.fontFamily).fontSize(this.compact ? 13 : 15).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .opacity(this.labelMix).blur(2 * (1 - this.labelMix)).translate({ y: 2 * (1 - this.labelMix) })
        if (this.previousLabel) {
          Text(this.previousLabel).fontFamily(this.appearance.fontFamily).fontSize(this.compact ? 13 : 15).maxLines(1).width('100%')
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_tertiary'))
            .opacity(1 - this.labelMix).blur(2 * this.labelMix).translate({ y: -2 * this.labelMix })
            .position({ x: 0, y: 0 }).accessibilityLevel('no')
        }
      }
      .flexShrink(1)
    }
    .constraintSize({ maxWidth: '100%' }).flexShrink(1)
    .accessibilityText(this.label)
    .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }))
    .onVisibleAreaChange([0], (visible: boolean) => this.visibilityChanged(visible))
  }
}

// Rounded-square symbol used as the leading visual of cards and rows.
@Component
export struct IconBadge {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop icon: Resource = $r('sys.symbol.doc_text');
  @Prop tint?: ResourceColor;
  @Prop fill?: ResourceColor;
  diameter: number = 36;

  build() {
    Column() {
      SymbolGlyph(this.icon).fontSize(Math.round(this.diameter * 0.55)).fontColor([this.tint || this.appearance.accent])
    }.width(this.diameter).height(this.diameter).borderRadius(Math.round(this.diameter * 0.3))
    .justifyContent(FlexAlign.Center).backgroundColor(this.fill || this.appearance.accentContainer)
  }
}

// Small status pill, e.g. "仅本对话" / "OAuth" / "失败".
@Component
export struct Tag {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop text: string = '';
  @Prop strong: boolean = false;
  @Prop danger: boolean = false;

  build() {
    Text(this.text).fontFamily(this.appearance.fontFamily).fontSize(11).height(20).padding({ left: 8, right: 8 }).borderRadius(10).maxLines(1)
      .fontColor(this.danger ? $r('app.color.danger') : this.strong ? this.appearance.onAccentContainer : $r('app.color.text_secondary'))
      .backgroundColor(this.danger ? $r('app.color.danger_container') : this.strong ? this.appearance.accentContainer : $r('app.color.surface_variant'))
  }
}

// Headline number with a caption, laid out in rows of equal-width tiles.
@Component
export struct StatTile {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.value).fontFamily(this.appearance.fontFamily).fontSize(20).fontWeight(FontWeight.Bold).maxLines(1).fontColor($r('app.color.text_primary'))
      Text(this.label).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).maxLines(1).fontColor($r('app.color.text_secondary'))
    }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
  }
}
