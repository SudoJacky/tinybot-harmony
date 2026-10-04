import { t } from '../model/I18n';
import { defaultContextWindow } from '../model/ConversationContext';
import { reasoningEfforts, reasoningEffortName } from '../model/ReasoningEffort';
import { AssistantOptions, ModelCapability, defaultAssistantOptions } from '../model/AssistantOptions';
import { ModelReference } from '../model/ProviderProfiles';
import { ProductivityData } from '../model/Productivity';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Font, Space } from '../common/Theme';
import { Banner, BottomBar, EmptyState, GroupCard, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct ModelSettingsPanel {
  @ObjectLink app: ChatViewModel;
  @State private options: AssistantOptions = defaultAssistantOptions();
  @State private capabilityIndex: number = 0;
  @State private images: boolean = true;
  @State private usage: boolean = true;
  @State private reasoning: string = 'default';
  @State private contextWindow: string = '';
  @State private error: string = '';
  aboutToAppear(): void { this.options = JSON.parse(JSON.stringify(this.app.productivity.options || defaultAssistantOptions())) as AssistantOptions; this.loadCapability(); }
  private choices(kind: string = ''): string[] { return [kind === 'image' ? t("未启用") : t("跟随当前模型")].concat(this.app.modelChoices.map((item) => item.providerName + ' · ' + item.modelId)); }
  private reference(index: number): ModelReference | undefined { const item = this.app.modelChoices[index - 1]; return item ? { providerId: item.providerId, modelId: item.modelId } : undefined; }
  private efforts(): string[] {
    const reference = this.reference(this.capabilityIndex + 1);
    const protocol = this.app.providerProfiles.find((item) => item.id === reference?.providerId)?.protocol || '';
    return reasoningEfforts(protocol, reference?.modelId || '');
  }
  private supportsReasoning(): boolean { return this.efforts().length > 1; }
  private chosen(reference?: ModelReference): number { return reference ? this.app.modelChoices.findIndex((item) => item.providerId === reference.providerId && item.modelId === reference.modelId) + 1 : 0; }
  private loadCapability(): void {
    const reference = this.reference(this.capabilityIndex + 1);
    const item = this.options.capabilities.find((item) => item.providerId === reference?.providerId && item.modelId === reference?.modelId);
    this.images = item?.images !== false; this.usage = item?.requestUsage !== false;
    this.reasoning = this.efforts().includes(item?.reasoning || 'default') ? item?.reasoning || 'default' : 'default';
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
      this.options.capabilities = this.options.capabilities.filter((item) => item.providerId !== reference.providerId || item.modelId !== reference.modelId).concat([capability]);
    }
    extras.options = this.options;
    if (!await this.app.saveProductivity(extras)) { this.error = this.app.error; }
    else { this.getUIContext().getPromptAction().showToast({ message: t("模型设置已保存") }); }
  }
  private setRoute(kind: string, index: number): void {
    const chosen = this.reference(index);
    if (kind === 'fast') { this.options.fast = chosen; } else if (kind === 'deep') { this.options.deep = chosen; }
    else if (kind === 'vision') { this.options.vision = chosen; } else if (kind === 'memory') { this.options.memory = chosen; }
    else { this.options.image = chosen; }
  }

  @Builder
  choiceMenu(options: string[], selected: number, onSelect: (index: number) => void) {
    Menu() {
      ForEach(options, (label: string, index: number) => {
        MenuItem({ content: label }).selected(index === selected).selectIcon(true).onClick(() => onSelect(index))
      }, (label: string, index: number) => index + label)
    }
  }

  // Tappable row showing the current choice; the full list opens as a menu.
  @Builder
  choiceRow(title: string, subtitle: string, options: string[], selected: number, enabled: boolean, onSelect: (index: number) => void) {
    Row({ space: Space.md }) {
      Column({ space: 3 }) {
        Text(title).fontSize(Font.body).fontColor($r('app.color.text_primary'))
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(Font.caption).lineHeight(17).fontColor($r('app.color.text_secondary'))
        }
      }.alignItems(HorizontalAlign.Start).flexShrink(0).constraintSize({ maxWidth: '55%' })
      Text(options[selected] || options[0] || '').fontSize(13).maxLines(2).textAlign(TextAlign.End).layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(selected > 0 ? $r('app.color.accent') : $r('app.color.text_tertiary'))
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: Space.lg, right: Space.lg, top: 10, bottom: 10 })
    .opacity(enabled ? 1 : 0.4).enabled(enabled)
    .stateStyles({ pressed: { .backgroundColor($r('app.color.surface_variant')) }, normal: { .backgroundColor(Color.Transparent) } })
    .bindMenu(this.choiceMenu(options, selected, onSelect))
  }

  @Builder
  settingsTab() {
    Column() {
      Scroll() {
        Column() {
          SectionHeader({ title: t("按任务选择模型"), caption: t("图片交给视觉模型；长问题和分析类任务交给深度模型，其余使用快速模型。") })
          GroupCard() {
            Column() {
              SwitchRow({ title: t("自动选择模型"), compId: 'auto-route', isOn: this.options.autoRoute,
                onChange: (value) => { this.options.autoRoute = value; } })
              RowDivider()
              this.choiceRow(t("快速任务"), '', this.choices(), this.chosen(this.options.fast), this.options.autoRoute,
                (index: number) => this.setRoute('fast', index))
              RowDivider()
              this.choiceRow(t("深度任务"), '', this.choices(), this.chosen(this.options.deep), this.options.autoRoute,
                (index: number) => this.setRoute('deep', index))
              RowDivider()
              this.choiceRow(t("图片理解"), '', this.choices(), this.chosen(this.options.vision), this.options.autoRoute,
                (index: number) => this.setRoute('vision', index))
            }
          }
          SectionHeader({ title: t("专用模型") })
          GroupCard() {
            Column() {
              this.choiceRow(t("记忆整理"), t("用于手动提炼与自动提取记忆"), this.choices(), this.chosen(this.options.memory), true,
                (index: number) => this.setRoute('memory', index))
              RowDivider()
              this.choiceRow(t("图片生成"), t("OpenAI 兼容的图片接口"), this.choices('image'), this.chosen(this.options.image), true,
                (index: number) => this.setRoute('image', index))
            }
          }
          SectionHeader({ title: t("模型能力"), caption: t("切换到另一个模型前，请先保存当前修改。") })
          if (this.app.modelChoices.length) {
            GroupCard() {
              Column() {
                this.choiceRow(t("模型"), '', this.choices().slice(1), this.capabilityIndex, true,
                  (index: number) => { this.capabilityIndex = index; this.loadCapability(); })
                RowDivider()
                SwitchRow({ title: t("支持图片输入"), compId: 'capability-images', isOn: this.images, onChange: (value) => { this.images = value; } })
                RowDivider()
                SwitchRow({ title: t("请求流式用量"), subtitle: t("适用于支持 stream_options 的 Chat Completions 服务。"), compId: 'capability-usage',
                  isOn: this.usage, onChange: (value) => { this.usage = value; } })
                RowDivider()
                this.choiceRow(t("推理强度"), this.supportsReasoning() ? '' : t('当前模型使用服务默认设置'), this.efforts().map((value) => reasoningEffortName(value)),
                  Math.max(0, this.efforts().indexOf(this.reasoning)), this.supportsReasoning(),
                  (index: number) => { this.reasoning = this.efforts()[index]; })
                RowDivider()
                Row({ space: Space.md }) {
                  Text(t("上下文窗口")).fontSize(Font.body).fontColor($r('app.color.text_primary'))
                  TextInput({ text: this.contextWindow, placeholder: this.contextPlaceholder() }).id('capability-context').type(InputType.Number)
                    .layoutWeight(1).height(40).fontSize(15).textAlign(TextAlign.End).backgroundColor(Color.Transparent)
                    .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_tertiary'))
                    .onChange((value) => { this.contextWindow = value; })
                  Text('Token').fontSize(13).fontColor($r('app.color.text_tertiary'))
                }.width('100%').height(56).padding({ left: Space.lg, right: Space.lg })
              }
            }
          } else {
            GroupCard() {
              EmptyState({ icon: $r('sys.symbol.cloud'), title: t("还没有可用的模型"), caption: t("先在“设置 › 模型服务”中添加并启用服务。") })
            }
          }
          if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
        }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.lg })
      }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      BottomBar() {
        Button(this.app.busy ? t("请等待当前任务完成") : t("保存")).id('save-assistant-options').attributeModifier(Btn.primary).width('100%')
          .enabled(!this.app.busy && !this.app.saveError).onClick(() => this.save())
      }
    }.width('100%').height('100%')
  }

  build() { this.settingsTab() }
}
