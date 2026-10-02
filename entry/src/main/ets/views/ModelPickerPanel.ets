import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ModelChoice } from '../model/ProviderProfiles';
import { Btn, Font, Radius, Space } from '../common/Theme';
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
  @ObjectLink app: ChatViewModel;
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
    return this.app.active.modelRef?.providerId === choice.providerId && this.app.active.modelRef?.modelId === choice.modelId;
  }

  private isDefault(choice: ModelChoice): boolean {
    return this.app.config.configured && this.app.config.providerId === choice.providerId && this.app.config.model === choice.modelId;
  }

  @Builder
  groupHeader(name: string) {
    Text(name).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary')).width('100%')
      .padding({ left: 4, top: Space.lg, bottom: Space.sm }).backgroundColor($r('app.color.page_background'))
  }

  @Builder
  choiceRow(choice: ModelChoice) {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(choice.modelId).fontSize(Font.body).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontWeight(this.isCurrent(choice) ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.isCurrent(choice) ? $r('app.color.accent') : $r('app.color.text_primary'))
        if (this.isDefault(choice)) {
          Text(t("新对话默认")).fontSize(11).fontColor($r('app.color.text_tertiary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(this.isDefault(choice) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star')).fontSize(18)
          .fontColor([this.isDefault(choice) ? $r('app.color.accent') : $r('app.color.text_tertiary')])
      }.id('default-model-' + choice.providerId + '-' + choice.modelId).width(40).height(40)
      .backgroundColor(Color.Transparent).accessibilityText(t("设为新对话默认")).enabled(!this.app.busy)
      .onClick(async () => { if (await this.app.selectModel(choice.providerId, choice.modelId, true)) { this.onSelected(); } })
      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).width(20)
        .fontColor([this.isCurrent(choice) ? $r('app.color.accent') : Color.Transparent])
    }
    .id('choose-model-' + choice.providerId + '-' + choice.modelId)
    .width('100%').height(60).padding({ left: Space.lg, right: Space.md })
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor($r('app.color.surface')) } })
    .enabled(!this.app.busy)
    .onClick(async () => { if (await this.app.selectModel(choice.providerId, choice.modelId)) { this.onSelected(); } })
  }

  build() {
    Column({ space: Space.sm }) {
      Search({ value: this.query, placeholder: t("搜索服务或模型") }).id('model-search').height(40)
        .backgroundColor($r('app.color.surface_variant')).placeholderColor($r('app.color.text_tertiary'))
        .onChange((value: string) => { this.query = value; })
      if (this.app.modelChoices.length === 0) {
        Column({ space: Space.md }) {
          SymbolGlyph($r('sys.symbol.cloud')).fontSize(36).fontColor([$r('app.color.text_tertiary')])
          Text(t("尚无已启用的模型服务")).fontSize(15).fontColor($r('app.color.text_secondary'))
          Button(t("添加模型服务")).id('picker-add-provider').attributeModifier(Btn.primary).onClick(() => this.onSettings())
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.groups(), (group: ProviderGroup) => {
            ListItemGroup({ header: this.groupHeader(group.name) }) {
              ForEach(group.choices, (choice: ModelChoice) => {
                ListItem() { this.choiceRow(choice) }
              }, (choice: ModelChoice) => choice.providerId + '/' + choice.modelId)
            }.borderRadius(Radius.lg).clip(true)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: Space.lg })
          }, (group: ProviderGroup) => group.providerId + ':' + group.choices.length)
          ListItem() {
            Text(t("点击选择仅用于当前对话；点星标设为之后新对话的默认模型。")).fontSize(Font.caption).lineHeight(18)
              .fontColor($r('app.color.text_tertiary')).width('100%').padding({ left: 4, top: Space.md, bottom: Space.xl })
          }
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).sticky(StickyStyle.None).edgeEffect(EdgeEffect.Spring)
      }
      if (this.app.error.length > 0) { Banner({ text: this.app.error, compId: 'model-picker-error' }) }
    }.padding({ left: Space.page, right: Space.page, top: Space.sm }).width('100%').height('100%')
  }
}
