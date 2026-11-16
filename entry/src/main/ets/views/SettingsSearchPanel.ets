import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Font, Space } from '../common/Theme';
import { GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { t } from '../model/I18n';
import { SettingsSearchItem, findSettings, settingsSectionTitle } from '../model/SettingsSearch';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
export struct SettingsSearchPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.developer.enabled') private developerEnabled: boolean = false;
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @ObjectLink app: ChatViewModel;
  @State private query: string = '';
  onSelect: (item: SettingsSearchItem) => void = () => {};
  private scroller: Scroller = new Scroller();

  private unavailable(item: SettingsSearchItem): boolean {
    return item.requiresEditable === true && ((this.app.sharedBusy && !this.app.saving) || !!this.app.saveError);
  }

  @Builder
  results(items: SettingsSearchItem[], locale: string) {
    if (items.length === 0) {
      Text(t('没有匹配项')).id('settings-search-empty').fontFamily(this.appearance.fontFamily).fontSize(Font.body)
        .fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Center).padding({ top: Space.xl })
    } else {
      GroupCard() {
        Column() {
          ForEach(items, (item: SettingsSearchItem, index: number) => {
            if (index > 0) { RowDivider() }
            NavRow({ title: item.route === 'provider' ? item.title : t(item.title), compId: 'settings-result-' + item.id,
              subtitle: item.group ? t(item.group) : settingsSectionTitle(item.section), disabled: this.unavailable(item),
              onTap: () => {
                if (!this.unavailable(item)) {
                  this.getUIContext().getFocusController().clearFocus();
                  this.onSelect(item);
                }
              } })
          }, (item: SettingsSearchItem) => locale + ':' + item.id + ':' + item.title)
        }
      }
    }
  }

  build() {
    Column() {
      Column() {
        Search({ value: this.query, placeholder: t('搜索设置') }).id('settings-search-input').width('100%').height(44)
          .textFont({ family: this.appearance.fontFamily }).placeholderFont({ family: this.appearance.fontFamily })
          .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
          .fontColor($r('app.color.text_primary')).maxLength(120).defaultFocus(true)
          .onChange((value: string) => { this.query = value; this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); })
          .onSubmit(() => { this.getUIContext().getFocusController().clearFocus(); })
      }.attributeModifier(PageStyles.form).padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      Scroll(this.scroller) {
        Column() {
          if (this.query.trim()) { this.results(findSettings(this.query, this.app.providerProfiles, this.developerEnabled), this.locale) }
        }.attributeModifier(PageStyles.form).padding({ left: Space.page, right: Space.page, bottom: Space.xl })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
