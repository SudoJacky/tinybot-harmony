import { PageStyles } from '../common/PageStyles';
import { materialMenuContent } from '../common/MaterialMenu';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { defaultContextWindow } from '../model/ContextSettings';
import { reasoningEfforts, reasoningEffortName } from '../model/ReasoningEffort';
import { AssistantOptions, ModelCapability, defaultAssistantOptions } from '../model/AssistantOptions';
import { mergeSavedConfiguration } from '../model/SavedConfiguration';
import { ModelChoice, ModelReference, availableImageModels } from '../model/ProviderProfiles';
import { ProductivityData } from '../model/Productivity';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Space } from '../common/Theme';
import { Banner, BottomBar, EmptyState, GroupCard, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

type DedicatedModel = 'memory' | 'title' | 'teamWorker';

@Component
export struct ModelSettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @State private options: AssistantOptions = defaultAssistantOptions();
  @State private capabilityIndex: number = 0;
  @State private images: boolean = true;
  @State private usage: boolean = true;
  @State private reasoning: string = 'default';
  @State private contextWindow: string = '';
  @State private error: string = '';
  aboutToAppear(): void { this.options = JSON.parse(JSON.stringify(this.app.productivity.options || defaultAssistantOptions())) as AssistantOptions; this.loadCapability(); }
  private choices(): string[] { return [t("跟随当前模型")].concat(this.app.modelChoices.map((item) => item.providerName + ' · ' + item.modelId)); }
  private imageModels(): ModelChoice[] { return availableImageModels(this.app.providerProfiles); }
  private imageChoices(): string[] { return [t('关闭图片生成')].concat(this.imageModels().map((item) => item.providerName + ' · ' + item.modelId)); }
  private chosenImage(): number {
    const reference = this.options.imageGeneration;
    if (!reference) { return 0; }
    const index = this.imageModels().findIndex((item) => item.providerId === reference.providerId && item.modelId === reference.modelId);
    return index < 0 ? -1 : index + 1;
  }
  private setImageModel(index: number): void {
    const options = JSON.parse(JSON.stringify(this.options)) as AssistantOptions;
    const choice = this.imageModels()[index - 1];
    options.imageGeneration = choice ? { providerId: choice.providerId, modelId: choice.modelId } : undefined;
    this.options = options;
  }
  private reference(index: number): ModelReference | undefined { const item = this.app.modelChoices[index - 1]; return item ? { providerId: item.providerId, modelId: item.modelId } : undefined; }
  private efforts(): string[] {
    const reference = this.reference(this.capabilityIndex + 1);
    const protocol = this.app.providerProfiles.find((item) => item.id === reference?.providerId)?.protocol || '';
    return reasoningEfforts(protocol, reference?.modelId || '');
  }
  private supportsReasoning(): boolean { return this.efforts().length > 1; }
  private chosen(reference?: ModelReference): number {
    if (!reference) { return 0; }
    const index = this.app.modelChoices.findIndex((item) => item.providerId === reference.providerId && item.modelId === reference.modelId);
    return index < 0 ? -1 : index + 1;
  }
  private loadCapability(): void {
    const reference = this.reference(this.capabilityIndex + 1);
    const item = this.options.capabilities.find((item) => item.providerId === reference?.providerId && item.modelId === reference?.modelId);
    this.images = item?.images !== false; this.usage = item?.requestUsage !== false;
    this.reasoning = item?.reasoning || 'default';
    this.contextWindow = item?.contextWindow === undefined ? '' : String(item.contextWindow);
  }
  private contextPlaceholder(): string {
    const reference = this.reference(this.capabilityIndex + 1);
    const window = this.app.providerProfiles.find((item) => item.id === reference?.providerId)?.contextWindow;
    return t('自动（{0}）', [window === undefined ? defaultContextWindow(reference?.modelId || '') : window]);
  }
  private async save(): Promise<void> {
    this.error = ''; const extras = JSON.parse(JSON.stringify(this.app.productivity)) as ProductivityData;
    const reference = this.reference(this.capabilityIndex + 1);
    if (reference) {
      const capability: ModelCapability = { providerId: reference.providerId, modelId: reference.modelId, images: this.images,
        reasoning: this.reasoning, requestUsage: this.usage, contextWindow: this.contextWindow.trim() ? Number(this.contextWindow) : undefined };
      const previous = this.options.capabilities.find((item) => item.providerId === reference.providerId && item.modelId === reference.modelId);
      const saved = mergeSavedConfiguration(previous, capability);
      this.options.capabilities = this.options.capabilities.filter((item) => item.providerId !== reference.providerId || item.modelId !== reference.modelId).concat([saved]);
    }
    extras.options = this.options;
    if (!await this.app.saveProductivity(extras)) { this.error = this.app.error; }
    else { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("模型设置已保存") }); }
  }
  private setDedicatedModel(kind: DedicatedModel, index: number): void {
    const options = JSON.parse(JSON.stringify(this.options)) as AssistantOptions;
    const reference = this.reference(index);
    if (kind === 'memory') { options.memory = reference; }
    else if (kind === 'title') { options.title = reference; }
    else { options.teamWorker = reference; }
    this.options = options;
  }

  @Builder
  settingsTab() {
    Column() {
      Scroll() {
        Column() {
          SectionHeader({ title: t("专用模型") })
          GroupCard() {
            Column() {
              ModelChoiceRow({ title: t("记忆整理"), options: this.choices(), selected: this.chosen(this.options.memory),
                onSelect: (index: number) => this.setDedicatedModel('memory', index) })
              RowDivider()
              ModelChoiceRow({ title: t('会话起名'), options: this.choices(), selected: this.chosen(this.options.title),
                onSelect: (index: number) => this.setDedicatedModel('title', index) })
              RowDivider()
              ModelChoiceRow({ title: t('团队执行'), subtitle: t('用于执行团队任务的子 Agent。'),
                options: this.choices(), selected: this.chosen(this.options.teamWorker),
                onSelect: (index: number) => this.setDedicatedModel('teamWorker', index) })
              RowDivider()
              ModelChoiceRow({ title: t('生成图片'), subtitle: this.imageModels().length ? '' : t('请先添加图片生成服务。'),
                options: this.imageChoices(), selected: this.chosenImage(),
                onSelect: (index: number) => this.setImageModel(index) })
            }
          }
          SectionHeader({ title: t("模型能力") })
          if (this.app.modelChoices.length) {
            GroupCard() {
              Column() {
                ModelChoiceRow({ title: t("模型"), options: this.choices().slice(1), selected: this.capabilityIndex,
                  onSelect: (index: number) => { this.capabilityIndex = index; this.loadCapability(); } })
                RowDivider()
                SwitchRow({ title: t("支持图片输入"), compId: 'capability-images', isOn: this.images, onChange: (value) => { this.images = value; } })
                RowDivider()
                SwitchRow({ title: t("请求流式用量"), subtitle: t("适用于支持 stream_options 的 Chat Completions 服务。"), compId: 'capability-usage',
                  isOn: this.usage, onChange: (value) => { this.usage = value; } })
                RowDivider()
                ModelChoiceRow({ title: t("推理强度"), subtitle: this.supportsReasoning() ? '' : t('当前模型使用服务默认设置'),
                  options: this.efforts().map((value) => reasoningEffortName(value)),
                  selected: Math.max(0, this.efforts().indexOf(this.reasoning)), selectable: this.supportsReasoning(),
                  onSelect: (index: number) => { this.reasoning = this.efforts()[index]; } })
                RowDivider()
                Row({ space: Space.md }) {
                  Text(t("上下文窗口")).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                  TextInput({ text: this.contextWindow, placeholder: this.contextPlaceholder() }).fontFamily(this.appearance.fontFamily).id('capability-context').type(InputType.Number)
                    .layoutWeight(1).height(40).fontSize(15).textAlign(TextAlign.End).backgroundColor(Color.Transparent)
                    .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'))
                    .onChange((value) => { this.contextWindow = value; })
                  Text('Token').fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_tertiary'))
                }.width('100%').height(56).padding({ left: Space.lg, right: Space.lg })
              }
            }
          } else {
            GroupCard() {
              EmptyState({ icon: $r('sys.symbol.cloud'), title: t("还没有可用的模型"), caption: t("先在“设置 › 模型与服务”中添加并启用服务。") })
            }
          }
          if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
        }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.lg })
      }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      BottomBar() {
        Button(this.app.busy ? t("请等待当前任务完成") : t("保存")).fontFamily(this.appearance.fontFamily).id('save-assistant-options').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && !this.app.saveError).onClick(() => this.save())
      }
    }.width('100%').height('100%').attributeModifier(PageStyles.form)
  }

  build() { this.settingsTab() }
}

@Component
struct ModelChoiceRow {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop options: string[] = [];
  @Prop selected: number = 0;
  @Prop selectable: boolean = true;
  onSelect: (index: number) => void = () => {};

  @Builder
  choiceMenu() {
    Menu() {
      ForEach(this.options, (label: string, index: number) => {
        MenuItem(() => materialMenuContent.bind(this)({ label: label, selected: index === this.selected }))
          .selected(index === this.selected).onClick(() => this.onSelect(index))
      }, (label: string, index: number) => index + label)
    }
  }

  build() {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(this.title).fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontFamily(this.appearance.fontFamily).fontSize(Font.caption).lineHeight(17).fontColor($r('app.color.text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).flexShrink(0).constraintSize({ maxWidth: '55%' })
      Text(this.selected < 0 ? t('所选模型不可用') : this.options[this.selected] || this.options[0] || '')
        .fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(2).textAlign(TextAlign.End).layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.selected < 0 ? $r('app.color.danger') : this.selected > 0 ? this.appearance.accent : $r('app.color.text_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .opacity(this.selectable ? 1 : 0.4).enabled(this.selectable)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .bindMenu(this.choiceMenu(), { systemMaterial: this.appearance.menu, mask: false })
  }
}
