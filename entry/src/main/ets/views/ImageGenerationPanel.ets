import { AppearanceStyle } from '../common/AppearanceStyle';
import { PageStyles } from '../common/PageStyles';
import { Btn, Font, Space, Styles, protocolName } from '../common/Theme';
import { Banner, BottomBar, GroupCard, NavRow, RowDivider } from '../common/Widgets';
import { t } from '../model/I18n';
import { IMAGE_PROTOCOLS, isImageProtocol } from '../model/ProviderEndpoint';
import { ImageGenerationConfig, ImageGenerationDraft, ProviderProfile, imageGenerationDraft, imageModelsForProtocol,
  imageProviders } from '../model/ProviderProfiles';
import { ChatViewModel } from '../viewmodel/ChatViewModel';

@Component
export struct ImageGenerationPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @State private providerId: string = '';
  @State private protocol: string = 'openai-images';
  @State private modelId: string = '';
  @State private baseUrl: string = '';
  @State private saving: boolean = false;
  @State private error: string = '';
  private initialized: boolean = false;
  onAddProvider: (protocol: string, onReturn: (provider: ProviderProfile) => void) => void = () => {};
  onSaved: () => void = () => {};

  aboutToAppear(): void {
    if (this.initialized) { return; }
    const saved = this.app.productivity.options?.imageGeneration;
    if (saved) {
      this.applySelection(imageGenerationDraft(this.providers().find((item) => item.id === saved.providerId), saved));
    }
    this.initialized = true;
  }

  private providers(): ProviderProfile[] {
    return imageProviders(this.app.providerProfiles);
  }
  private selectedProvider(): ProviderProfile | undefined { return this.providers().find((item) => item.id === this.providerId); }
  private locked(): boolean { return this.saving || this.app.sharedBusy || !!this.app.saveError; }
  private choices(): string[] { return [t('关闭图片生成')].concat(this.providers().map((item) => item.name)); }
  private selectedIndex(): number {
    if (!this.providerId) { return 0; }
    const index = this.providers().findIndex((item) => item.id === this.providerId);
    return index < 0 ? -1 : index + 1;
  }
  private knownModels(provider?: ProviderProfile): string[] {
    return imageModelsForProtocol(provider, this.protocol);
  }
  private applySelection(draft: ImageGenerationDraft): void {
    this.providerId = draft.providerId;
    this.protocol = draft.protocol;
    this.modelId = draft.modelId;
    this.baseUrl = draft.baseUrl;
    this.error = '';
  }
  private chooseProvider(provider?: ProviderProfile): void {
    if (provider?.id && provider.id === this.providerId) { return; }
    this.applySelection(imageGenerationDraft(provider));
  }
  private addProvider(): void {
    if (this.locked()) { return; }
    this.onAddProvider(isImageProtocol(this.protocol) ? this.protocol : 'openai-images',
      (provider: ProviderProfile) => this.chooseProvider(provider));
  }
  private async save(): Promise<void> {
    if (this.locked()) { return; }
    const value: ImageGenerationConfig | undefined = this.providerId ? { providerId: this.providerId,
      protocol: this.protocol, modelId: this.modelId, baseUrl: this.baseUrl } : undefined;
    this.saving = true;
    this.error = '';
    try {
      if (await this.app.saveImageGeneration(value)) { this.onSaved(); }
      else { this.error = this.app.error || t('设置未保存，请稍后重试。'); }
    } finally { this.saving = false; }
  }

  @Builder
  label(title: string) {
    Text(title).width('100%').fontFamily(this.appearance.fontFamily).fontSize(Font.body).fontColor($r('app.color.text_primary'))
  }
  build() {
    Column() {
      Scroll() {
        Column({ space: Space.md }) {
          GroupCard() {
            Column() {
              Column({ space: Space.sm }) {
                this.label(t('服务提供方'))
                Select(this.choices().map((value: string): SelectOption => ({ value: value })))
                  .id('image-provider').width('100%').enabled(!this.locked()).selected(this.selectedIndex())
                  .value(this.choices()[this.selectedIndex()] || t('所选模型不可用'))
                  .onSelect((index: number) => this.chooseProvider(this.providers()[index - 1]))
              }.padding(Space.md).width('100%')
              RowDivider()
              NavRow({ title: t('添加模型服务'), compId: 'image-add-provider', icon: $r('sys.symbol.plus'), accent: true,
                disabled: this.locked(), onTap: () => this.addProvider() })
            }
          }
          if (this.selectedProvider()) {
            GroupCard() {
              Column({ space: Space.sm }) {
                this.label(t('协议'))
                Select(IMAGE_PROTOCOLS.map((item: string): SelectOption => ({ value: protocolName(item) })))
                  .id('image-protocol').width('100%').enabled(!this.locked()).selected(IMAGE_PROTOCOLS.indexOf(this.protocol))
                  .value(protocolName(this.protocol)).onSelect((index: number) => { this.protocol = IMAGE_PROTOCOLS[index]; })
                this.label(t('模型 ID'))
                TextInput({ text: this.modelId, placeholder: t('填写图片模型 ID。') }).fontFamily(this.appearance.fontFamily)
                  .id('image-model-id').attributeModifier(Styles.input).maxLength(200).enabled(!this.locked())
                  .onChange((value: string) => { this.modelId = value; })
                if (this.knownModels(this.selectedProvider()).length > 1) {
                  Select(this.knownModels(this.selectedProvider()).map((value: string): SelectOption => ({ value: value })))
                    .id('image-existing-models').width('100%').enabled(!this.locked()).value(t('选择模型'))
                    .selected(this.knownModels(this.selectedProvider()).indexOf(this.modelId))
                    .onSelect((_index: number, value: string) => { this.modelId = value; })
                }
                this.label(t('图片服务地址'))
                TextInput({ text: this.baseUrl, placeholder: t('留空使用此服务的基础地址') }).fontFamily(this.appearance.fontFamily)
                  .id('image-base-url').attributeModifier(Styles.input).type(InputType.URL).maxLength(1024).enabled(!this.locked())
                  .onChange((value: string) => { this.baseUrl = value; })
              }.padding(Space.md).width('100%')
            }
          }
        }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.md })
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      BottomBar() {
        Column({ space: Space.sm }) {
          if (this.error || this.app.saveError) { Banner({ text: this.error || this.app.saveError, compId: 'image-save-error' }) }
          Button(this.saving ? t('正在保存…') : t('保存')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).width('100%')
            .enabled(!this.locked() && (!this.providerId || (!!this.selectedProvider() && isImageProtocol(this.protocol) && !!this.modelId.trim())))
            .id('save-image-settings').onClick(() => this.save())
        }.width('100%')
      }
    }.width('100%').height('100%').attributeModifier(PageStyles.form).backgroundColor($r('app.color.page_background'))
  }
}
