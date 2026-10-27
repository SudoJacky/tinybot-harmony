// Keep this static card independent of app services and AppStorage. Native
// resources follow the desktop's language/theme, including before first launch.
const storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('wide') wide: boolean = false;

  @Builder
  mascot(size: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      Circle().width(size * 0.82).height(size * 0.82)
        .fill('#141413').stroke($r('app.color.widget_mascot_outline')).strokeWidth(1)
        .position({ x: 0, y: size * 0.18 })
      Circle().width(size * 0.18).height(size * 0.18).fill('#FFFFFF')
        .position({ x: size * 0.19, y: size * 0.39 })
      Image($r('app.media.widget_smile')).width(size * 0.16).height(size * 0.12)
        .position({ x: size * 0.50, y: size * 0.69 })
      Circle().width(size * 0.15).height(size * 0.15).fill($r('app.color.tiny_coral'))
        .position({ x: size * 0.75, y: 0 })
    }.width(size).height(size).accessibilityLevel('no')
  }

  @Builder
  actions() {
    Row({ space: 8 }) {
      FormLink({ action: 'router', abilityName: 'EntryAbility', moduleName: 'entry',
        params: { tinybotAction: 'new-chat' } }) {
        Row({ space: 6 }) {
          if (this.wide) {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([$r('app.color.on_accent')])
          }
          Text($r('app.string.widget_new_chat')).fontSize(14).minFontSize(11).maxFontSize(14)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.on_accent'))
        }.width('100%').height(44).justifyContent(FlexAlign.Center).padding({ left: 8, right: 8 })
          .backgroundColor($r('app.color.accent')).borderRadius(22)
      }.id('widget-new-chat').layoutWeight(1).height(44)
        .accessibilityText($r('app.string.widget_new_chat')).accessibilityLevel('yes')
      FormLink({ action: 'router', abilityName: 'EntryAbility', moduleName: 'entry',
        params: { tinybotAction: 'voice-input' } }) {
        Row() {
          SymbolGlyph($r('sys.symbol.mic')).fontSize(23).fontColor([$r('app.color.on_accent_container')])
        }.width(44).height(44).justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.accent_container')).borderRadius(22)
      }.id('widget-voice-input').width(44).height(44)
        .accessibilityText($r('app.string.shortcut_voice_input')).accessibilityLevel('yes')
    }.width('100%').height(44)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Circle().width(this.wide ? '65%' : '100%').height(this.wide ? '180%' : '100%')
        .fill($r('app.color.widget_tint')).position({ x: this.wide ? '-30%' : '-55%', y: '-40%' })
        .accessibilityLevel('no')
      if (this.wide) {
        Row({ space: 12 }) {
          Column() { this.mascot(76) }
            .width('28%').height('100%').justifyContent(FlexAlign.Center)
          Column() {
            Text($r('app.string.widget_greeting')).fontSize(20).minFontSize(14).maxFontSize(20)
              .fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').height(24).margin({ bottom: 8 }).textAlign(TextAlign.Start)
            this.actions()
            FormLink({ action: 'router', abilityName: 'EntryAbility', moduleName: 'entry',
              params: { tinybotAction: 'continue-chat' } }) {
              Row({ space: 6 }) {
                Text($r('app.string.widget_continue')).fontSize(13).minFontSize(11).maxFontSize(13)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor($r('app.color.text_secondary')).flexShrink(1)
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12)
                  .fontColor([$r('app.color.text_secondary')])
              }.width('100%').height(44)
            }.id('widget-continue-chat').width('100%').height(44)
              .accessibilityText($r('app.string.widget_continue')).accessibilityLevel('yes')
          }.layoutWeight(1).height('100%').justifyContent(FlexAlign.Center)
            // Balance the visible content: the last link includes an invisible touch margin.
            .translate({ y: 6 })
        }.padding({ left: 16, right: 16, top: 12, bottom: 12 }).width('100%').height('100%')
      } else {
        Column({ space: 6 }) {
          Column() { this.mascot(48) }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          Text($r('app.string.widget_greeting_small')).fontSize(16).minFontSize(12).maxFontSize(16)
            .height(22).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          this.actions()
        }.padding(12).width('100%').height('100%')
      }
    }.id('tiny-quick-actions').width('100%').height('100%')
      .backgroundColor($r('app.color.widget_background')).borderRadius(24).clip(true)
  }
}
