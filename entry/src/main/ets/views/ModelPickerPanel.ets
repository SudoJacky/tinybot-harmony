import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { ChatViewModel, ThreadViewModel } from '../viewmodel/ChatViewModel';
import { ModelChoice } from '../model/ProviderProfiles';
import { Btn, Radius, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';

class ProviderGroup {
  providerId: string;
  name: string;
  choices: ModelChoice[] = [];

  constructor(providerId: string, name: string) {
    this.providerId = providerId;
    this.name = name;
  }
}

@Component
export struct ModelPickerPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @ObjectLink thread: ThreadViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  @State private query: string = '';

  private groups(): ProviderGroup[] {
    const needle = this.query.trim().toLocaleLowerCase();
    const result: ProviderGroup[] = [];
    for (const choice of this.app.modelChoices) {
      if (!(choice.providerName + ' ' + choice.modelId).toLocaleLowerCase().includes(needle)) { continue; }
      let group = result.find((item: ProviderGroup) => item.providerId === choice.providerId);
      if (!group) {
        group = new ProviderGroup(choice.providerId, choice.providerName);
        result.push(group);
      }
      group.choices.push(choice);
    }
    return result;
  }

  private isCurrent(choice: ModelChoice): boolean {
    return this.thread.modelRef?.providerId === choice.providerId && this.thread.modelRef?.modelId === choice.modelId;
  }

  private isDefault(choice: ModelChoice): boolean {
    return this.app.config.configured && this.app.config.providerId === choice.providerId && this.app.config.model === choice.modelId;
  }

  @Builder
  groupHeader(name: string) {
    Text(name).fontFamily(this.appearance.fontFamily).fontSize(12).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary')).width('100%')
      .padding({ left: 4, top: 8, bottom: 2 })
  }

  @Builder
  choiceRow(choice: ModelChoice) {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(choice.modelId).fontFamily(this.appearance.fontFamily).fontSize(14).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontWeight(this.isCurrent(choice) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.isCurrent(choice) ? this.appearance.accent : $r('app.color.text_primary'))
        if (this.isDefault(choice)) {
          Text(t("新对话默认")).fontFamily(this.appearance.fontFamily).fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).width(20)
        .fontColor([this.isCurrent(choice) ? this.appearance.accent : Color.Transparent])
    }
    .id('choose-model-' + choice.providerId + '-' + choice.modelId)
    .width('100%').height(46).padding({ left: 8, right: 4 })
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) },
      normal: { .backgroundColor(Color.Transparent) } })
    .focusOnTouch(false).enabled(!this.app.busy && !this.thread.archived && !this.app.saveError)
    .onClick(async () => { if (await this.app.selectModel(choice.providerId, choice.modelId)) { this.onSelected(); } })
  }

  build() {
    Column({ space: Space.sm }) {
      Search({ value: this.query, placeholder: t("搜索服务或模型") }).textFont({ family: this.appearance.fontFamily })
        .placeholderFont({ family: this.appearance.fontFamily }).id('model-search').height(36).enableKeyboardOnFocus(false)
        .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
        .onChange((value: string) => { this.query = value; })
      if (this.app.modelChoices.length === 0) {
        Column({ space: Space.md }) {
          SymbolGlyph($r('sys.symbol.cloud')).fontSize(36).fontColor([$r('app.color.text_tertiary')])
          Text(t("尚无已启用的模型服务")).fontFamily(this.appearance.fontFamily).fontSize(15).fontColor($r('app.color.text_secondary'))
          Button(t("添加模型服务")).fontFamily(this.appearance.fontFamily).id('picker-add-provider').attributeModifier(Btn.primary).onClick(() => this.onSettings())
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.groups(), (group: ProviderGroup) => {
            ListItemGroup({ header: this.groupHeader(group.name) }) {
              ForEach(group.choices, (choice: ModelChoice) => {
                ListItem() { this.choiceRow(choice) }
              }, (choice: ModelChoice) => choice.providerId + '/' + choice.modelId)
            }.borderRadius(Radius.sm).clip(true)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 8 })
          }, (group: ProviderGroup) => group.providerId + ':' + group.choices.length)
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).sticky(StickyStyle.None).edgeEffect(EdgeEffect.Spring)
      }
      if (this.app.error.length > 0) { Banner({ text: this.app.error, compId: 'model-picker-error' }) }
    }.padding(Space.sm).width('100%').height('100%')
  }
}
