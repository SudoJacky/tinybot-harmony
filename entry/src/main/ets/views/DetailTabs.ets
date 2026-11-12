import { materialMenuContent } from '../common/MaterialMenu';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { Motion, Radius, Space } from '../common/Theme';
import { IconButton } from '../common/Widgets';
import { AnimatedIcon } from '../common/AnimatedIcon';
import { AnimatedIconName } from '../common/IconArtwork';

export class DetailTabItem {
  id: string;
  label: string;
  icon: AnimatedIconName;

  constructor(id: string, label: string, icon: AnimatedIconName) {
    this.id = id;
    this.label = label;
    this.icon = icon;
  }
}

// Desktop-parity strip above the docked detail pane: one chip per open panel,
// a menu that adds the two panel kinds, and the collapse control at the end.
@Component
export struct DetailTabs {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop tabs: DetailTabItem[] = [];
  @Prop active: string = '';
  @Prop showCollapse: boolean = true;
  @State private hoveredTab: string = '';
  onSelect: (id: string) => void = () => {};
  onClose: (id: string) => void = () => {};
  onAddFiles: () => void = () => {};
  onAddBrowser: () => void = () => {};
  onCollapse: () => void = () => {};

  @Builder
  addMenu() {
    Menu() {
      MenuItem(() => materialMenuContent.bind(this)({ label: t('工作区文件'), icon: $r('sys.symbol.folder') }))
        .id('detail-add-files').onClick(() => this.onAddFiles())
      MenuItem(() => materialMenuContent.bind(this)({ label: t('应用内浏览器'), icon: $r('sys.symbol.connection') }))
        .id('detail-add-browser').onClick(() => this.onAddBrowser())
    }
  }

  @Builder
  chip(tab: DetailTabItem) {
    Row({ space: 6 }) {
      AnimatedIcon({ iconName: tab.icon, iconSize: 15, selected: this.active === tab.id,
        interacting: this.hoveredTab === tab.id,
        tint: this.active === tab.id ? this.appearance.accent : $r('app.color.text_secondary') })
      Text(tab.label).fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 150 })
        .fontColor(this.active === tab.id ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      if (this.active === tab.id) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([$r('app.color.text_secondary')])
        }.id('detail-tab-close-' + tab.id).width(20).height(20).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('关闭') + ' · ' + tab.label)
          .onClick(() => this.onClose(tab.id))
      }
    }
    .id('detail-tab-' + tab.id).height(32).padding({ left: 10, right: this.active === tab.id ? 4 : 10 })
    .borderRadius(Radius.sm).backgroundColor(this.active === tab.id ? $r('app.color.surface') : Color.Transparent)
    .border({ width: this.active === tab.id ? 0.5 : 0, color: $r('app.color.divider') })
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) },
      normal: { .backgroundColor(this.active === tab.id ? $r('app.color.surface') : Color.Transparent) } })
    .onHover((hovered: boolean) => {
      if (hovered) { this.hoveredTab = tab.id; }
      else if (this.hoveredTab === tab.id) { this.hoveredTab = ''; }
    })
    .onClick(() => this.onSelect(tab.id))
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.tabs, (tab: DetailTabItem) => { this.chip(tab) }, (tab: DetailTabItem) => tab.id + ':' + tab.label)
          }.padding({ left: Space.sm })
        }.layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).align(Alignment.Start)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([$r('app.color.text_secondary')])
        }.id('detail-add-tab').width(32).height(32).padding(0).backgroundColor(Color.Transparent)
          .clickEffect(Motion.pressSmall).accessibilityText(t('添加侧栏面板'))
          .bindMenu(this.addMenu, { systemMaterial: this.appearance.menu, mask: false })
        if (this.showCollapse) { IconButton({ icon: $r('sys.symbol.close_sidebar'), label: t('关闭侧栏'), compId: 'detail-collapse',
          diameter: 32, iconSize: 17, onTap: this.onCollapse }) }
      }.width('100%').height(48).padding({ right: 4 })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
    }.width('100%').backgroundColor($r('app.color.page_background'))
  }
}
