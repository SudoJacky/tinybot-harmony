export interface MaterialMenuContentOptions {
  label: string;
  icon?: Resource;
  image?: boolean;
  danger?: boolean;
  selected?: boolean;
}

// Material inversion requires system resources on Text, SymbolGlyph and Image themselves.
@Builder
export function materialMenuContent(options: MaterialMenuContentOptions) {
  Row({ space: 12 }) {
    if (options.icon) {
      if (options.image) {
        Image(options.icon).width(20).height(20)
          .fillColor(options.danger ? $r('sys.color.warning') : $r('sys.color.icon_primary'))
          .accessibilityLevel('no')
      } else {
        SymbolGlyph(options.icon).fontSize(20)
          .fontColor([options.danger ? $r('sys.color.warning') : $r('sys.color.icon_primary')])
          .accessibilityLevel('no')
      }
    }
    Text(options.label).fontSize(16)
      .fontColor(options.danger ? $r('sys.color.warning') : $r('sys.color.font_primary')).layoutWeight(1)
    if (options.selected !== undefined) {
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('sys.color.icon_primary')])
        .visibility(options.selected ? Visibility.Visible : Visibility.Hidden).accessibilityLevel('no')
    }
  }.width('100%').constraintSize({ minHeight: 40 }).padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .accessibilityGroup(true).accessibilityText(options.label)
}

@Builder
export function materialMenuHeader(label: string) {
  Text(label).fontColor($r('sys.color.font_secondary')).fontSize(14)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
}
