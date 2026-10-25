import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { Motion, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';

// Empty docked sidebar: the desktop right column's entry choices, one card per
// panel kind. Choosing one turns it into the first tab instead of expanding a
// second surface.
@Component
export struct DetailLauncher {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  onFiles: () => void = () => {};
  onBrowser: () => void = () => {};
  onClose: () => void = () => {};

  @Builder
  option(icon: Resource, label: string, compId: string, action: () => void) {
    Row({ space: Space.md }) {
      SymbolGlyph(icon).fontSize(22).fontColor([this.appearance.accent])
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.text_primary'))
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
    }
    .id(compId).width('100%').height(64).padding({ left: Space.lg, right: Space.md })
    .borderRadius(Radius.md).backgroundColor($r('app.color.page_background'))
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) },
      normal: { .backgroundColor($r('app.color.page_background')) } })
    .clickEffect(Motion.press).onClick(action)
  }

  build() {
    Column() {
      Row() {
        Text(t('侧栏')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
          .layoutWeight(1).fontColor($r('app.color.text_primary'))
        IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭侧栏'), compId: 'detail-launcher-close',
          diameter: 36, iconSize: 18, onTap: this.onClose })
      }.width('100%').height(56).padding({ left: Space.page, right: 6 })
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
      Column({ space: 10 }) {
        this.option($r('sys.symbol.folder'), t('工作区文件'), 'detail-launcher-files', this.onFiles)
        this.option($r('sys.symbol.connection'), t('应用内浏览器'), 'detail-launcher-browser', this.onBrowser)
      }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
      Blank()
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
}
