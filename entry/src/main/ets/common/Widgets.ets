import { Btn, Font, Radius, Space } from './Theme';

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
