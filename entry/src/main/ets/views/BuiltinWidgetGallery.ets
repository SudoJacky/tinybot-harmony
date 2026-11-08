import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, gradientColor } from '../common/Theme';
import { BuiltinWidget, builtinWidgets } from '../model/BuiltinWidgets';
import { t } from '../model/I18n';

@Component
export struct BuiltinWidgetGallery {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop adding: string = '';
  @Prop available: boolean = true;
  @Prop balanceAvailable: boolean = false;
  onAdd: (id: string) => void = () => {};
  @Builder private preview(widget: BuiltinWidget) {
    Column({ space: 7 }) {
      Row({ space: 5 }) {
        Circle().width(5).height(5).fill(widget.color)
        Text(widget.label).fontSize(10).fontColor(widget.color).maxLines(1)
      }.width('100%')
      if (widget.id === 'ascii') {
        Text('    .:-=+***+=-:.\n .:+*  .:@@:.  *+:.\n :=#  :@  @:  #=:\n  .:+*=-::-=*+:.').fontFamily('monospace').fontSize(12).lineHeight(17)
          .fontColor(widget.color).textAlign(TextAlign.Center).margin({ top: 10 })
      } else if (widget.id === 'balance') {
        Text('—').fontSize(30).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          .height(50).margin({ top: 5 })
        Text(t('余额与额度')).fontSize(10).fontColor($r('app.color.text_secondary'))
      } else if (widget.id === 'clock') {
        Text(new Date().toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })).fontSize(32).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary')).margin({ top: 6 })
        Row({ space: 5 }) {
          ForEach([0, 1, 2, 3, 4, 5, 6], (day: number) => {
            Circle().width(day === 3 ? 9 : 5).height(day === 3 ? 9 : 5).fill(day === 3 ? widget.color : gradientColor(widget.color, 0.25))
          })
        }.margin({ top: 4 })
      } else if (widget.id === 'focus') {
        Stack() {
          Circle().width(72).height(72).fill(Color.Transparent).stroke(gradientColor(widget.color, 0.25)).strokeWidth(3)
          Text('25:00').fontSize(23).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        }.margin({ top: 3 })
      } else if (widget.id === 'todo') {
        Column({ space: 12 }) {
          ForEach([0, 1, 2], (row: number) => {
            Row({ space: 8 }) {
              Circle().width(12).height(12).fill(row === 0 ? widget.color : Color.Transparent).stroke(widget.color).strokeWidth(1)
              Row().width(row === 1 ? '70%' : '50%').height(4).borderRadius(3).backgroundColor(gradientColor(widget.color, row === 0 ? 0.15 : 0.4))
            }.width('100%')
          })
        }.padding({ top: 12, bottom: 4 }).width('100%')
      } else {
        Text(t('每一个\n值得期待的日子')).fontSize(18).fontWeight(FontWeight.Medium).fontColor(widget.color)
          .lineHeight(26).width('100%').margin({ top: 10 })
      }
    }.alignItems(HorizontalAlign.Center).width('100%').height(132).padding(14).borderRadius(18)
      .backgroundColor(gradientColor(widget.color, 0.09)).accessibilityText(widget.title)
  }
  @Builder private item(widget: BuiltinWidget) {
    Column({ space: 10 }) {
      this.preview(widget)
      Column({ space: 4 }) {
        Text(widget.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).maxLines(1)
        Text(widget.description).fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(2).height(32)
      }.width('100%').alignItems(HorizontalAlign.Start)
      Button(this.adding === widget.id ? t('正在添加…') : t('添加卡片')).attributeModifier(Btn.tonal).width('100%')
        .id('builtin-widget-add-' + widget.id).accessibilityText(t('添加「{0}」', [widget.title]))
        .enabled(this.available && !this.adding && (widget.id !== 'balance' || this.balanceAvailable))
        .onClick(() => this.onAdd(widget.id))
    }.width('100%').padding(12).borderRadius(24).backgroundColor($r('app.color.surface'))
      .border({ width: 0.5, color: $r('app.color.divider') })
  }
  build() {
    Column({ space: 14 }) {
      Column({ space: 6 }) {
        Text(t('内置卡片')).fontSize(22).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(t('精心做好，添加就能用。')).fontSize(13).fontColor($r('app.color.text_secondary'))
      }.width('100%').alignItems(HorizontalAlign.Start)
      GridRow({ columns: { xs: 2, sm: 3 }, gutter: { x: 12, y: 12 },
        breakpoints: { value: ['640vp'], reference: BreakpointsReference.ComponentSize } }) {
        ForEach(builtinWidgets(), (widget: BuiltinWidget) => {
          GridCol() { this.item(widget) }
        }, (widget: BuiltinWidget) => widget.id)
      }.width('100%')
      if (!this.balanceAvailable) {
        Text(t('余额卡片需要先在模型服务设置中配置余额查询。')).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
