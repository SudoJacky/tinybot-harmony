import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { Motion, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { AnimatedIcon } from '../common/AnimatedIcon';
import { AnimatedIconName } from '../common/IconArtwork';

// Empty docked sidebar: the desktop right column's entry choices, one card per
// panel kind. Choosing one turns it into the first tab instead of expanding a
// second surface.
@Component
export struct DetailLauncher {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop compact: boolean = false;
  @Prop workbench: boolean = false;
  @Prop project: string = '';
  @Prop sideChatAvailable: boolean = false;
  @State private hovered: string = '';
  onFiles: () => void = () => {};
  onBrowser: () => void = () => {};
  onSideChat: () => void = () => {};
  @BuilderParam context: () => void = this.emptyContext;
  onClose: () => void = () => {};

  @Builder emptyContext() {}

  @Builder
  option(icon: AnimatedIconName, label: string, compId: string, action: () => void) {
    Row({ space: Space.md }) {
      AnimatedIcon({ iconName: icon, iconSize: 22, tint: this.appearance.accent, interacting: this.hovered === compId })
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(15).fontWeight(FontWeight.Medium)
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.text_primary'))
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
    }
    .id(compId).width('100%').height(this.workbench ? 44 : 64).padding({ left: Space.lg, right: Space.md })
    .borderRadius(Radius.md).backgroundColor($r('app.color.page_background'))
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) },
      normal: { .backgroundColor($r('app.color.page_background')) } })
    .clickEffect(Motion.press).onClick(action)
    .onHover((hovered: boolean) => {
      if (hovered) { this.hovered = compId; }
      else if (this.hovered === compId) { this.hovered = ''; }
    })
  }

  build() {
    Column() {
      Row() {
        Text(this.workbench ? t('会话详情') : t('文件与浏览器')).fontFamily(this.appearance.fontFamily).fontSize(16).fontWeight(FontWeight.Medium)
          .layoutWeight(1).fontColor($r('app.color.text_primary'))
        if (this.compact) {
          IconButton({ icon: $r('sys.symbol.xmark'), label: t('关闭'), compId: 'detail-launcher-close', onTap: this.onClose })
        }
      }.width('100%').height(56).padding({ left: Space.page, right: 6 })
        .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
      Scroll() {
        Column({ space: this.workbench ? 6 : 10 }) {
          if (this.workbench && this.project) {
            Text(this.project).fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ bottom: Space.xs })
          }
          this.option('folder', t('工作区文件'), 'detail-launcher-files', this.onFiles)
          this.option('browser', t('应用内浏览器'), 'detail-launcher-browser', this.onBrowser)
          if (this.sideChatAvailable) { this.option('compose', t('新建旁聊'), 'detail-launcher-side-chat', this.onSideChat) }
          if (this.workbench) { this.context() }
        }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      if (!this.compact && !this.workbench) {
        Text(t('打开文件或网页，可与对话并排查看。')).fontSize(13).fontColor($r('app.color.text_secondary'))
          .padding(Space.lg).width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.surface'))
  }
}
