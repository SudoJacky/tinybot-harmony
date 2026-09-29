import { ChatViewModel, SettingsViewModel } from '../viewmodel/ChatViewModel';
import { ProviderInfo } from '../model/Provider';

@Component
export struct SettingsPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onSaved: () => void = () => {};

  private modelOptions(): string[] {
    return this.app.providerOptions.find((provider: ProviderInfo) => provider.id === this.settings.providerId)?.models || [];
  }

  private providerHint(): string {
    return this.app.providerOptions.find((provider: ProviderInfo) => provider.id === this.settings.providerId)?.description || '';
  }

  private endpointPlaceholder(): string {
    return this.app.providerOptions.find((provider: ProviderInfo) => provider.id === this.settings.providerId)?.endpointPlaceholder ||
      'https://api.example.com/v1';
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('让 Tinybot 连接你的模型').fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).width('100%')
        Text('选择服务商，或使用自定义 Chat Completions 兼容服务。填写地址、模型名称与密钥。')
          .fontSize(14).lineHeight(22).fontColor($r('app.color.text_secondary')).width('100%')
        Text('模型服务').fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 14 })
        Select(this.app.providerOptions.map((provider: ProviderInfo): SelectOption => { return { value: provider.name }; }))
          .id('model-provider').width('100%').height(48).enabled(!this.app.busy)
          .selected(this.app.providerOptions.findIndex((provider: ProviderInfo) => provider.id === this.settings.providerId))
          .value(this.app.providerOptions.find((provider: ProviderInfo) => provider.id === this.settings.providerId)?.name || this.settings.providerId)
          .onSelect((index: number) => { this.app.selectProvider(this.app.providerOptions[index].id); })
        if (this.providerHint().length > 0) {
          Text(this.providerHint()).id('provider-hint').fontSize(12).lineHeight(20)
            .fontColor($r('app.color.text_secondary')).width('100%')
        }
        Text('服务地址').fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 14 })
        TextInput({ text: this.settings.baseUrl, placeholder: this.endpointPlaceholder() })
          .id('model-endpoint').type(InputType.Normal).height(52).maxLength(1024)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
          .onChange((value: string) => { this.settings.baseUrl = value; })
        Text('模型名称').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
        if (this.modelOptions().length > 0) {
          Select(this.modelOptions().map((model: string): SelectOption => { return { value: model }; }))
            .id('model-preset').width('100%').height(44).enabled(!this.app.busy)
            .selected(this.modelOptions().indexOf(this.settings.model))
            .value(this.modelOptions().indexOf(this.settings.model) >= 0 ? this.settings.model : '选择预设模型')
            .onSelect((index: number) => { this.settings.model = this.modelOptions()[index]; })
        }
        TextInput({ text: this.settings.model, placeholder: '填写准确的模型 ID' })
          .id('model-name').height(52).maxLength(200)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
          .onChange((value: string) => { this.settings.model = value; })
        Text('API Key').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
        TextInput({ text: this.settings.apiKey, placeholder: this.settings.hasSavedKey ? '已安全保存，留空保留原密钥' : '粘贴你的 API Key' })
          .id('model-key').type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None)
          .height(52).maxLength(512).enabled(!this.settings.noApiKey)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
          .onChange((value: string) => { this.settings.apiKey = value; })
        Row({ space: 16 }) {
          Text('此服务无需 API Key').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.settings.noApiKey }).id('no-api-key')
            .selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.settings.noApiKey = value; })
        }.width('100%')
        Text('密钥保存在系统安全存储中，不写入会话文件，不随设备同步。')
          .fontSize(12).lineHeight(19).fontColor($r('app.color.text_secondary')).width('100%')
        Text('助手指令').fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 8 })
        TextArea({ text: this.settings.systemPrompt, placeholder: '希望 Tinybot 如何回答？' })
          .id('system-prompt').height(132).fontSize(14).maxLength(4000)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
          .onChange((value: string) => { this.settings.systemPrompt = value; })
        if (this.settings.error.length > 0) {
          Text(this.settings.error).id('settings-error').fontSize(13).lineHeight(20).fontColor($r('app.color.danger')).width('100%')
        }
        Button(this.app.busy ? '正在保存…' : '保存并开始对话').id('save-model')
          .width('100%').height(50).fontSize(16).margin({ top: 10 })
          .backgroundColor($r('app.color.accent')).fontColor($r('app.color.on_accent'))
          .enabled(this.app.ready && !this.app.busy && this.app.saveError.length === 0)
          .onClick(async () => { if (await this.app.saveSettings()) { this.onSaved(); } })
        Text('支持当前会话工作区内的文件工具，模型需要支持流式工具调用。')
          .fontSize(12).lineHeight(20).fontColor($r('app.color.text_secondary')).width('100%')
      }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
    }.height('100%').width('100%').scrollBar(BarState.Auto)
  }
}
