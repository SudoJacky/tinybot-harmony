import { common } from '@kit.AbilityKit';
import { FrameCallback } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Radius, Space, protocolName } from '../common/Theme';
import { t } from '../model/I18n';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';

const CHAT_PROTOCOLS: string[] = ['chat-completions', 'responses', 'anthropic-messages', 'gemini'];

class OnboardingFocusFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(): void { this.action(); }
}

@Component
export struct OnboardingProviderForm {
  @StorageProp('tinybot.locale') private locale: string = 'zh-CN';
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink editor: ProviderEditorViewModel;
  @Link modelId: string;
  @Prop @Watch('invalidateFocus') locked: boolean = false;
  @Prop custom: boolean = false;
  @Prop @Watch('focusInvalidField') invalidField: string = '';
  @State private advanced: boolean = false;
  @State private manualModel: boolean = false;
  private focusRevision: number = 0;
  onEdit: () => void = () => {};
  onError: (message: string) => void = () => {};

  private t(message: string, values: (string | number)[] = []): string { return t(message, values, this.locale); }

  aboutToAppear(): void {
    this.advanced = this.custom;
    this.manualModel = !!this.modelId && !this.editor.modelList.includes(this.modelId);
  }

  aboutToDisappear(): void { this.invalidateFocus(); }

  private invalidateFocus(): void { this.focusRevision++; }

  private focusInvalidField(): void {
    const revision = ++this.focusRevision;
    const field = this.invalidField;
    if (this.locked || !['name', 'url', 'key', 'model-id'].includes(field) || (field === 'name' && !this.custom)) { return; }
    if (field === 'name' || field === 'url') { this.advanced = true; }
    if (field === 'model-id') { this.manualModel = true; }
    this.getUIContext().postFrameCallback(new OnboardingFocusFrame(() => {
      if (revision !== this.focusRevision || this.locked || (field === 'key' && this.editor.noApiKey)) { return; }
      this.getUIContext().getFocusController().requestFocus('onboarding-provider-' + field);
    }));
  }

  private async openKeyPage(): Promise<void> {
    if (this.locked || !this.editor.apiKeyUrl) { return; }
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .startAbility({ action: 'ohos.want.action.viewData', uri: this.editor.apiKeyUrl });
    } catch (error) { this.onError(this.t('无法打开系统浏览器。') + ' ' + (error as Error).message); }
  }

  @Builder
  fieldLabel(label: string) {
    Text(label).width('100%').fontFamily(this.appearance.fontFamily).fontSize(13).fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
  }

  @Builder
  advancedFields() {
    if (this.custom) {
      this.fieldLabel(this.t('服务名称'))
      TextInput({ text: this.editor.name, placeholder: this.t('服务名称') }).id('onboarding-provider-name')
        .width('100%').height(44).maxLength(80).borderRadius(Radius.md).accessibilityText(this.t('服务名称'))
        .onChange((value: string) => { this.editor.name = value; this.onEdit(); })
    }
    this.fieldLabel(this.t('服务地址'))
    TextInput({ text: this.editor.baseUrl, placeholder: 'https://api.example.com/v1' }).id('onboarding-provider-url')
      .width('100%').height(44).maxLength(1024).borderRadius(Radius.md).type(InputType.URL)
      .accessibilityText(this.t('服务地址'))
      .onChange((value: string) => { this.editor.baseUrl = value; this.onEdit(); })
    if (this.editor.baseUrl.startsWith('http://')) {
      Text(this.t('HTTP 连接未加密，仅适用于可信网络中的本地模型。')).width('100%')
        .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.warning'))
    }
    this.fieldLabel(this.t('协议'))
    Select(CHAT_PROTOCOLS.map((protocol: string): SelectOption => ({ value: protocolName(protocol) })))
      .id('onboarding-provider-protocol').width('100%').height(44)
      .selected(CHAT_PROTOCOLS.indexOf(this.editor.protocol)).value(protocolName(this.editor.protocol))
      .accessibilityText(this.t('协议'))
      .onSelect((index: number) => { this.editor.changeProtocol(CHAT_PROTOCOLS[index]); this.onEdit(); })
    Row({ space: 8 }) {
      Checkbox().id('onboarding-provider-no-key').select(this.editor.noApiKey).selectedColor(this.appearance.accent)
        .accessibilityText(this.t('无需 API Key')).onChange((checked: boolean) => {
          this.editor.noApiKey = checked;
          if (checked) { this.editor.apiKey = ''; }
          this.onEdit();
        })
      Text(this.t('无需 API Key')).fontFamily(this.appearance.fontFamily).fontSize(14)
        .fontColor($r('app.color.text_primary'))
    }.width('100%').height(44)
  }

  build() {
    Column({ space: Space.sm }) {
      if (!this.editor.noApiKey) {
        Row() {
          Text('API Key').layoutWeight(1).fontFamily(this.appearance.fontFamily).fontSize(13)
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.text_secondary'))
          if (this.editor.apiKeyUrl) {
            Button(this.t('获取 API Key')).id('onboarding-provider-get-key').attributeModifier(Btn.textSmall)
              .padding({ left: 8, right: 0 }).onClick(() => this.openKeyPage())
          }
        }.width('100%')
        TextInput({ text: this.editor.apiKey, placeholder: this.editor.canKeepKey ? this.t('留空保留原密钥') : this.t('填写 API Key') })
          .id('onboarding-provider-key').width('100%').height(44).maxLength(512).borderRadius(Radius.md)
          .type(InputType.Password).showPasswordIcon(true).copyOption(CopyOptions.None).accessibilityText('API Key')
          .onChange((value: string) => { this.editor.apiKey = value; this.onEdit(); })
      }
      this.fieldLabel(this.t('默认模型'))
      if (this.editor.modelList.length > 0 && !this.manualModel) {
        Select(this.editor.modelList.map((id: string): SelectOption => ({ value: id })))
          .id('onboarding-provider-model-picker').width('100%').height(44)
          .selected(this.editor.modelList.indexOf(this.modelId)).value(this.modelId || this.t('选择模型'))
          .accessibilityText(this.t('默认模型'))
          .onSelect((_index: number, value: string) => { this.modelId = value; this.onEdit(); })
      } else {
        TextInput({ text: this.modelId, placeholder: this.t('填写模型 ID') })
          .id('onboarding-provider-model-id').width('100%').height(44).maxLength(200).borderRadius(Radius.md)
          .accessibilityText(this.t('默认模型'))
          .onChange((value: string) => { this.modelId = value; this.onEdit(); })
      }
      if (this.editor.modelList.length > 0) {
        Button(this.manualModel ? this.t('选择已有模型') : this.t('输入模型 ID')).attributeModifier(Btn.textSmall)
          .id('onboarding-provider-model-mode').onClick(() => {
            this.manualModel = !this.manualModel;
            if (!this.manualModel && !this.editor.modelList.includes(this.modelId)) { this.modelId = this.editor.modelList[0]; }
            this.onEdit();
          })
      }
      Button(this.t('高级设置')).id('onboarding-provider-advanced').attributeModifier(Btn.tonalSmall)
        .width('100%').accessibilityDescription(this.advanced ? this.t('已展开') : this.t('已收起'))
        .onClick(() => { this.advanced = !this.advanced; this.onEdit(); })
      if (this.advanced) { this.advancedFields() }
    }.width('100%').alignItems(HorizontalAlign.Start).enabled(!this.locked)
  }
}
