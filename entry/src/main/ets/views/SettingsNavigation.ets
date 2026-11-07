import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Space } from '../common/Theme';
import { t } from '../model/I18n';
import { PageStyles } from '../common/PageStyles';
import { GroupCard, NavRow, RowDivider } from '../common/Widgets';

interface SettingsCategory { key: string; title: string; icon: Resource; }
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

// Phones drill into one category at a time; wide windows retain the persistent sidebar.
@Component
export struct SettingsOverview {
  onSelect: (key: string) => void = () => {};
  build() {
    Scroll() {
      Column() {
        GroupCard() {
          Column() {
            ForEach(CATEGORIES, (item: SettingsCategory, index: number) => {
              if (index > 0) { RowDivider() }
              NavRow({ title: t(item.title), icon: item.icon, compId: 'settings-open-' + item.key,
                onTap: () => this.onSelect(item.key) })
            }, (item: SettingsCategory) => item.key)
          }
        }
      }.width('100%').padding(Space.page)
    }.width('100%').height('100%').attributeModifier(PageStyles.form).align(Alignment.Top).scrollBar(BarState.Auto)
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
