import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space } from '../common/Theme';
import { t } from '../model/I18n';

interface SettingsCategory { key: string; title: string; icon: Resource; }
const CATEGORY_TRACK_RADIUS: number = 25;
const CATEGORIES: SettingsCategory[] = [
  { key: 'account', title: '账号', icon: $r('sys.symbol.person') },
  { key: 'models', title: '模型与服务', icon: $r('sys.symbol.cloud') },
  { key: 'assistant', title: '助手偏好', icon: $r('sys.symbol.square_and_pencil') },
  { key: 'tools', title: '工具与权限', icon: $r('sys.symbol.wrench_and_screwdriver') },
  { key: 'appearance', title: '界面与语言', icon: $r('sys.symbol.picture') },
  { key: 'data', title: '数据与用量', icon: $r('sys.symbol.rectangle_stack') },
  { key: 'help', title: '帮助与关于', icon: $r('sys.symbol.questionmark_circle') }
];

export function settingsCategoryTitle(key: string): string {
  return t(CATEGORIES.find((item: SettingsCategory) => item.key === key)?.title || '设置');
}

@Component
export struct SettingsCategoryBar {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('revealSelection') selected: string = 'models';
  onSelect: (key: string) => void = () => {};
  private scroller: Scroller = new Scroller();

  private revealSelection(): void {
    const index = CATEGORIES.findIndex((item: SettingsCategory) => item.key === this.selected);
    this.scroller.scrollToIndex(index, false, ScrollAlign.AUTO);
  }

  build() {
    Column() {
      Column() {
        List({ scroller: this.scroller }) {
          ForEach(CATEGORIES, (item: SettingsCategory, index: number) => {
            ListItem() {
              Button({ type: ButtonType.Normal }) {
                Row({ space: Space.sm }) {
                  SymbolGlyph(item.icon).fontSize(18)
                    .fontColor([this.selected === item.key ? $r('app.color.text_primary') : $r('app.color.text_secondary')])
                    .accessibilityLevel('no')
                  Text(t(item.title)).fontSize(14).fontFamily(this.appearance.fontFamily).maxLines(1)
                    .fontWeight(this.selected === item.key ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(this.selected === item.key ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
                }
              }.height(44).padding({ left: Space.md, right: Space.md }).borderRadius(22)
                .backgroundColor(this.selected === item.key ? $r('app.color.surface') : Color.Transparent)
                .accessibilityText(t(item.title)).accessibilitySelected(this.selected === item.key)
                .id('settings-open-' + item.key).onClick(() => this.onSelect(item.key))
            }.padding({ top: 3, bottom: 3, left: index === 0 ? 3 : 1, right: index === CATEGORIES.length - 1 ? 3 : 1 })
              .backgroundColor($r('app.color.surface_variant'))
              .borderRadius({
                topLeft: index === 0 ? CATEGORY_TRACK_RADIUS : 0,
                bottomLeft: index === 0 ? CATEGORY_TRACK_RADIUS : 0,
                topRight: index === CATEGORIES.length - 1 ? CATEGORY_TRACK_RADIUS : 0,
                bottomRight: index === CATEGORIES.length - 1 ? CATEGORY_TRACK_RADIUS : 0
              })
          }, (item: SettingsCategory) => item.key)
        }.listDirection(Axis.Horizontal).width('100%').height(50).scrollBar(BarState.Off)
          .borderRadius(CATEGORY_TRACK_RADIUS).clip(true)
          .id('settings-category-bar').onAreaChange(() => this.revealSelection())
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.xs, bottom: Space.sm })
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
    }.width('100%')
  }
}

@Component
export struct SettingsNavigation {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop selected: string = 'models';
  onSelect: (key: string) => void = () => {};
  onChat: () => void = () => {};
  build() {
    Column({ space: Space.md }) {
      Button(t('返回对话')).attributeModifier(Btn.text).id('settings-return-chat').onClick(this.onChat)
      Text(t('设置')).fontSize(24).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        .width('100%').padding({ left: 12, top: 12, bottom: 12 })
      ForEach(CATEGORIES, (item: SettingsCategory) => {
        Button() {
          Row({ space: 12 }) {
            SymbolGlyph(item.icon).fontSize(20).fontColor([this.selected === item.key ? this.appearance.accent : $r('app.color.text_secondary')])
            Text(t(item.title)).fontSize(15).layoutWeight(1).textAlign(TextAlign.Start)
              .fontColor(this.selected === item.key ? this.appearance.onAccentContainer : $r('app.color.text_primary'))
          }.width('100%')
        }.fontFamily(this.appearance.fontFamily).id('settings-category-' + item.key)
          .width('100%').height(48).padding({ left: 12, right: 12 }).borderRadius(12)
          .backgroundColor(this.selected === item.key ? this.appearance.accentContainer : Color.Transparent)
          .accessibilitySelected(this.selected === item.key).onClick(() => this.onSelect(item.key))
      }, (item: SettingsCategory) => item.key)
      Blank()
    }.width('100%').height('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.page_background'))
  }
}
