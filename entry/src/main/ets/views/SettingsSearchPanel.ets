import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Font, Space } from '../common/Theme';
import { GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { t } from '../model/I18n';
import { SettingsSearchItem, findSettings, settingsSectionTitle } from '../model/SettingsSearch';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
struct SettingsSearchResults {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop items: SettingsSearchItem[] = [];
  @Prop locale: string = 'zh-CN';
  @Prop editable: boolean = true;
  onSelect: (item: SettingsSearchItem) => void = () => {};

  private unavailable(item: SettingsSearchItem): boolean {
    return item.requiresEditable === true && !this.editable;
  }

  build() {
    if (this.items.length === 0) {
      Text(t('没有匹配项')).id('settings-search-empty').fontFamily(this.appearance.fontFamily).fontSize(Font.body)
        .fontColor($r('app.color.text_secondary')).width('100%').textAlign(TextAlign.Center).padding({ top: Space.xl })
    } else {
      GroupCard() {
        Column() {
          ForEach(this.items, (item: SettingsSearchItem, index: number) => {
            if (index > 0) { RowDivider() }
            NavRow({ title: item.route === 'provider' ? item.title : t(item.title), compId: 'settings-result-' + item.id,
              subtitle: item.group ? t(item.group) : settingsSectionTitle(item.section), disabled: this.unavailable(item),
              onTap: () => {
                if (!this.unavailable(item)) {
                  this.getUIContext().getFocusController().clearFocus();
                  this.onSelect(item);
                }
              } })
          }, (item: SettingsSearchItem) => this.locale + ':' + item.id + ':' + item.title)
        }
      }
    }
  }
}

@Component
export struct SettingsSearchPanel {
  @StorageProp('tinybot.developer.enabled') private developerEnabled: boolean = false;
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @ObjectLink app: ChatViewModel;
  @Prop @Watch('queryChanged') query: string = '';
  onSelect: (item: SettingsSearchItem) => void = () => {};
  private scroller: Scroller = new Scroller();

  private queryChanged(): void { this.scroller.scrollTo({ xOffset: 0, yOffset: 0 }); }

  build() {
    Column() {
      Scroll(this.scroller) {
        Column() {
          if (this.query.trim()) {
            SettingsSearchResults({ items: findSettings(this.query, this.app.providerProfiles, this.developerEnabled),
              locale: this.locale, editable: (!this.app.sharedBusy || this.app.saving) && !this.app.saveError, onSelect: this.onSelect })
          }
        }.attributeModifier(PageStyles.form).padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.xl })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
