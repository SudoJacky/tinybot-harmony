import { t } from '../model/I18n';
import { Btn, Font, Motion, Radius, Space } from './Theme';

@Component
export struct IconButton {
  @Prop icon: Resource = $r('sys.symbol.plus');
  @Prop tint: ResourceColor = $r('app.color.text_primary');
  @Prop fill: ResourceColor = Color.Transparent;
  @Prop disabled: boolean = false;
  label: string = '';
  compId: string = '';
  diameter: number = 44;
  iconSize: number = 22;
  onTap: () => void = () => {};

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(this.icon).fontSize(this.iconSize).fontColor([this.tint])
    }
    .id(this.compId).width(this.diameter).height(this.diameter).backgroundColor(this.fill)
    .animation({ duration: Motion.fast, curve: Motion.standard })
    .clickEffect(this.disabled ? null : Motion.pressSmall)
    .enabled(!this.disabled).accessibilityText(this.label).onClick(() => this.onTap())
  }
}

@Component
export struct SectionHeader {
  @Prop title: string = '';
  @Prop caption: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
      if (this.caption.length > 0) {
        Text(this.caption).fontSize(Font.caption).lineHeight(18).fontColor($r('app.color.text_tertiary'))
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

// Tappable list row with trailing value and chevron.
@Component
export struct NavRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop value: string = '';
  @Prop disabled: boolean = false;
  @Prop accent: boolean = false;
  icon?: Resource;
  compId: string = '';
  onTap: () => void = () => {};

  build() {
    Row({ space: Space.md }) {
      if (this.icon) {
        SymbolGlyph(this.icon).fontSize(20)
          .fontColor([this.accent ? $r('app.color.accent') : $r('app.color.text_secondary')])
      }
      Column({ space: 3 }) {
        Text(this.title).fontSize(Font.body).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.accent ? $r('app.color.accent') : $r('app.color.text_primary'))
          .fontWeight(this.accent ? FontWeight.Medium : FontWeight.Normal)
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontSize(Font.caption).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (this.value.length > 0) {
        Text(this.value).fontSize(13).maxLines(1).fontColor($r('app.color.text_tertiary'))
      }
      if (!this.accent) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('app.color.text_tertiary')])
      }
    }
    .id(this.compId).width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .opacity(this.disabled ? 0.4 : 1).enabled(!this.disabled)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .onClick(() => this.onTap())
  }
}

@Component
export struct SwitchRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  @Prop disabled: boolean = false;
  compId: string = '';
  onChange: (value: boolean) => void = () => {};

  build() {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(this.title).fontSize(Font.body).fontColor($r('app.color.text_primary'))
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontSize(Font.caption).lineHeight(17).fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn }).id(this.compId).selectedColor($r('app.color.accent'))
        .enabled(!this.disabled).onChange((value: boolean) => this.onChange(value))
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.md, top: 10, bottom: 10 })
  }
}

// Inline status message with an optional action, e.g. save failures.
@Component
export struct Banner {
  @Prop text: string = '';
  @Prop danger: boolean = true;
  @Prop actionLabel: string = '';
  @Prop actionEnabled: boolean = true;
  compId: string = '';
  actionId: string = '';
  onAction: () => void = () => {};

  build() {
    Row({ space: Space.sm }) {
      SymbolGlyph(this.danger ? $r('sys.symbol.exclamationmark_circle') : $r('sys.symbol.archivebox')).fontSize(18)
        .fontColor([this.danger ? $r('app.color.danger') : $r('app.color.text_secondary')])
      Text(this.text).id(this.compId).fontSize(13).lineHeight(19).layoutWeight(1)
        .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel).id(this.actionId).attributeModifier(Btn.textSmall)
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

  build() {
    Column() {
      this.content()
    }
    .width('100%').padding({ left: Space.page, right: Space.page, top: 10, bottom: 12 })
    .backgroundColor($r('app.color.page_background'))
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }
}

// Centered placeholder for empty lists.
@Component
export struct EmptyState {
  @Prop icon: Resource = $r('sys.symbol.doc_text');
  @Prop title: string = '';
  @Prop caption: string = '';

  build() {
    Column({ space: Space.md }) {
      SymbolGlyph(this.icon).fontSize(40).fontColor([$r('app.color.text_tertiary')])
      Text(this.title).fontSize(15).fontColor($r('app.color.text_secondary'))
      if (this.caption.length > 0) {
        Text(this.caption).fontSize(13).lineHeight(19).textAlign(TextAlign.Center).fontColor($r('app.color.text_tertiary'))
      }
    }.width('100%').padding({ left: Space.xl, right: Space.xl, top: 56, bottom: 56 })
  }
}

// iOS/HarmonyOS-style segmented control. Options are short labels; onSelect receives the index.
// The selection thumb slides between segments on a spring, like the desktop liquid toggle.
@Component
export struct Segmented {
  @Prop options: string[] = [];
  @Prop selected: number = 0;
  @State private segmentWidth: number = 0;
  compIdPrefix: string = 'segment';
  onSelect: (index: number) => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.segmentWidth > 0) {
        Column().width(this.segmentWidth).height('100%').borderRadius(Radius.sm - 2)
          .backgroundColor($r('app.color.surface')).shadow({ radius: 4, color: '#14000000', offsetY: 1 })
          .translate({ x: this.selected * this.segmentWidth })
          .animation({ curve: Motion.thumb })
      }
      Row() {
        ForEach(this.options, (label: string, index: number) => {
          Text(label).id(this.compIdPrefix + '-' + index).fontSize(14).layoutWeight(1).height('100%').textAlign(TextAlign.Center)
            .fontWeight(index === this.selected ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(index === this.selected ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .animation({ duration: Motion.fast, curve: Motion.standard })
            .accessibilityText(label + (index === this.selected ? t("，已选中") : ''))
            .onClick(() => this.onSelect(index))
        }, (label: string) => label)
      }.width('100%').height('100%')
      .onAreaChange((_old: Area, next: Area) => {
        this.segmentWidth = (next.width as number) / Math.max(1, this.options.length);
      })
    }.width('100%').height(36).padding(3).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
  }
}

// Waiting-for-model line: the mascot breathes while a light band sweeps across the label.
@Component
export struct ThinkingLine {
  @Prop label: string = t("正在思考…");
  // Inline in a process group: just the shimmering label at caption size.
  @Prop compact: boolean = false;
  @State private breath: number = 0.55;
  @State private sweep: number = -100;

  build() {
    Row({ space: Space.sm }) {
      if (!this.compact) {
        Image($r('app.media.tinybot')).width(18).height(18).opacity(this.breath)
      }
      // The band only paints over the label's own pixels (SRC_ATOP inside an offscreen layer).
      Stack({ alignContent: Alignment.Start }) {
        Text(this.label).fontSize(this.compact ? 13 : 15).maxLines(1).fontColor($r('app.color.text_tertiary'))
        Column().width('50%').height('100%')
          .linearGradient({ angle: 90, colors: [[Color.Transparent, 0], [$r('app.color.text_primary'), 0.5], [Color.Transparent, 1]] })
          .translate({ x: this.sweep + '%' })
          .blendMode(BlendMode.SRC_ATOP)
      }.blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    }
    .accessibilityText(this.label)
    .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fast, curve: Motion.standard }))
    .onAppear(() => {
      const ui = this.getUIContext();
      ui.animateTo({ duration: 800, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate }, () => { this.breath = 1; });
      ui.animateTo({ duration: 1800, curve: Curve.Linear, iterations: -1 }, () => { this.sweep = 200; });
    })
  }
}

// Soft highlight that keeps sweeping across its parent while some work is running.
@Component
export struct SweepBand {
  @State private travel: number = -100;

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Column().width('45%').height('100%')
        .linearGradient({ angle: 90, colors: [[Color.Transparent, 0], [$r('app.color.accent_tint'), 0.5], [Color.Transparent, 1]] })
        .translate({ x: this.travel + '%' })
    }
    .width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.Transparent)
    .transition(TransitionEffect.OPACITY.animation({ duration: Motion.medium, curve: Motion.standard }))
    .onAppear(() => {
      this.getUIContext().animateTo({ duration: 1800, curve: Curve.EaseInOut, iterations: -1 }, () => { this.travel = 325; });
    })
  }
}

// Rounded-square symbol used as the leading visual of cards and rows.
@Component
export struct IconBadge {
  @Prop icon: Resource = $r('sys.symbol.doc_text');
  @Prop tint: ResourceColor = $r('app.color.accent');
  @Prop fill: ResourceColor = $r('app.color.accent_container');
  diameter: number = 36;

  build() {
    Column() {
      SymbolGlyph(this.icon).fontSize(Math.round(this.diameter * 0.55)).fontColor([this.tint])
    }.width(this.diameter).height(this.diameter).borderRadius(Math.round(this.diameter * 0.3))
    .justifyContent(FlexAlign.Center).backgroundColor(this.fill)
  }
}

// Small status pill, e.g. "仅本对话" / "OAuth" / "失败".
@Component
export struct Tag {
  @Prop text: string = '';
  @Prop strong: boolean = false;
  @Prop danger: boolean = false;

  build() {
    Text(this.text).fontSize(11).height(20).padding({ left: 8, right: 8 }).borderRadius(10).maxLines(1)
      .fontColor(this.danger ? $r('app.color.danger') : this.strong ? $r('app.color.on_accent_container') : $r('app.color.text_secondary'))
      .backgroundColor(this.danger ? $r('app.color.danger_container') : this.strong ? $r('app.color.accent_container') : $r('app.color.surface_variant'))
  }
}

// Headline number with a caption, laid out in rows of equal-width tiles.
@Component
export struct StatTile {
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.value).fontSize(20).fontWeight(FontWeight.Bold).maxLines(1).fontColor($r('app.color.text_primary'))
      Text(this.label).fontSize(Font.caption).maxLines(1).fontColor($r('app.color.text_secondary'))
    }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .borderRadius(Radius.md).backgroundColor($r('app.color.surface'))
  }
}
