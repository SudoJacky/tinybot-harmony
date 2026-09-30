import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';

@Component
export struct ProviderEditorPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink editor: ProviderEditorViewModel;
  onSaved: () => void = () => {};
  private protocols: string[] = ['chat-completions', 'responses', 'anthropic-messages'];
  private protocolNames: string[] = ['Chat Completions', 'OpenAI Responses', 'Anthropic Messages'];

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('服务名称').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        TextInput({ text: this.editor.name, placeholder: '例如：我的 DeepSeek、公司代理' }).id('provider-name')
          .maxLength(80).height(52).onChange((value: string) => { this.editor.name = value; })
        Text('协议').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        Select(this.protocolNames.map((name: string): SelectOption => { return { value: name }; })).id('provider-protocol')
          .selected(this.protocols.indexOf(this.editor.protocol)).value(this.protocolNames[this.protocols.indexOf(this.editor.protocol)])
          .width('100%').height(48).onSelect((index: number) => { this.editor.protocol = this.protocols[index]; })
        Text('Base URL').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        TextInput({ text: this.editor.baseUrl, placeholder: 'https://api.example.com/v1' }).id('provider-url')
          .maxLength(1024).height(52).onChange((value: string) => { this.editor.baseUrl = value; })
        if (this.editor.baseUrl.startsWith('http://')) {
          Text('HTTP 连接未加密，适用于可信网络中的本地模型。').fontSize(12).fontColor($r('app.color.text_secondary'))
        }
        Text('API Key').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        TextInput({ text: this.editor.apiKey, placeholder: this.editor.hasSavedKey ? '已保存，留空保留原密钥' : '填写 API Key' })
          .id('provider-key').type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None)
          .height(52).maxLength(512).enabled(!this.editor.noApiKey).onChange((value: string) => { this.editor.apiKey = value; })
        Row({ space: 16 }) {
          Text('无需 API Key').layoutWeight(1).fontSize(14).fontColor($r('app.color.text_primary'))
          Toggle({ type: ToggleType.Switch, isOn: this.editor.noApiKey }).id('provider-no-key').onChange((value: boolean) => { this.editor.noApiKey = value; })
        }.width('100%')
        Text('可用模型 ID').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        TextArea({ text: this.editor.models, placeholder: '每行一个模型 ID，或用逗号分隔' }).id('provider-models')
          .height(120).fontSize(14).maxLength(10000).onChange((value: string) => { this.editor.models = value; })
        Text('上下文窗口（Token）').fontSize(14).width('100%').fontColor($r('app.color.text_primary'))
        TextInput({ text: this.editor.contextWindow }).id('context-window').type(InputType.Number).height(52).maxLength(7)
          .onChange((value: string) => { this.editor.contextWindow = value; })
        Text('使用此服务的模型共享该窗口预算，预留 4096 用于输出。请按服务的实际限制填写。')
          .fontSize(12).lineHeight(19).fontColor($r('app.color.text_secondary')).width('100%')
        Row({ space: 16 }) {
          Text('启用此服务').layoutWeight(1).fontSize(14).fontColor($r('app.color.text_primary'))
          Toggle({ type: ToggleType.Switch, isOn: this.editor.enabled }).id('provider-enabled').onChange((value: boolean) => { this.editor.enabled = value; })
        }.width('100%')
        if (this.editor.error.length > 0) { Text(this.editor.error).id('provider-error').fontSize(13).fontColor($r('app.color.danger')).width('100%') }
        Button(this.app.busy ? '正在保存…' : '保存服务').id('save-provider').width('100%').height(48).enabled(!this.app.busy)
          .onClick(async () => { if (await this.app.saveProvider()) { this.onSaved(); } })
      }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
    }.height('100%').width('100%').scrollBar(BarState.Auto)
  }
}
