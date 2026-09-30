import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';
import { Btn, Font, Radius, Space, Styles } from '../common/Theme';
import { Banner, BottomBar, GroupCard, RowDivider, SectionHeader, SwitchRow } from '../common/Widgets';

@Component
export struct ProviderEditorPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink editor: ProviderEditorViewModel;
  onSaved: () => void = () => {};
  private protocols: string[] = ['chat-completions', 'responses', 'anthropic-messages'];
  private protocolNames: string[] = ['Chat Completions', 'OpenAI Responses', 'Anthropic Messages'];

  @Builder
  label(text: string) {
    Text(text).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').margin({ bottom: 6 })
  }

  private confirmDelete(): void {
    this.getUIContext().showAlertDialog({ title: '删除模型服务？',
      message: '删除这份服务配置及其密钥，保留完整对话。使用它的会话需要重新选择模型。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: $r('app.color.danger'), action: async () => {
        if (await this.app.deleteProvider(this.editor.id)) { this.onSaved(); }
      } } });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          SectionHeader({ title: '连接' })
          Column({ space: Space.md }) {
            Column() {
              this.label('服务名称')
              TextInput({ text: this.editor.name, placeholder: '例如：我的 DeepSeek、公司代理' }).id('provider-name')
                .attributeModifier(Styles.input).maxLength(80).onChange((value: string) => { this.editor.name = value; })
            }
            Column() {
              this.label('协议')
              Select(this.protocolNames.map((name: string): SelectOption => { return { value: name }; })).id('provider-protocol')
                .selected(this.protocols.indexOf(this.editor.protocol)).value(this.protocolNames[this.protocols.indexOf(this.editor.protocol)])
                .width('100%').height(48).borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
                .font({ size: 15 }).fontColor($r('app.color.text_primary'))
                .onSelect((index: number) => { this.editor.protocol = this.protocols[index]; })
            }
            Column() {
              this.label('Base URL')
              TextInput({ text: this.editor.baseUrl, placeholder: 'https://api.example.com/v1' }).id('provider-url')
                .attributeModifier(Styles.input).type(InputType.URL).maxLength(1024)
                .onChange((value: string) => { this.editor.baseUrl = value; })
              if (this.editor.baseUrl.startsWith('http://')) {
                Text('HTTP 连接未加密，仅适用于可信网络中的本地模型。').fontSize(Font.caption).width('100%')
                  .fontColor($r('app.color.danger')).margin({ top: 6 })
              }
            }
          }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
          SectionHeader({ title: '认证' })
          GroupCard() {
            Column() {
              Column() {
                TextInput({ text: this.editor.apiKey,
                  placeholder: this.editor.noApiKey ? '无需 API Key' : this.editor.hasSavedKey ? '已保存，留空保留原密钥' : '填写 API Key' })
                  .id('provider-key').attributeModifier(Styles.input).type(InputType.Password).showPasswordIcon(false)
                  .copyOption(CopyOptions.None).maxLength(512).enabled(!this.editor.noApiKey)
                  .onChange((value: string) => { this.editor.apiKey = value; })
              }.padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
              RowDivider()
              SwitchRow({ title: '无需 API Key', subtitle: '适用于本地模型或内网代理', compId: 'provider-no-key',
                isOn: this.editor.noApiKey, onChange: (value: boolean) => { this.editor.noApiKey = value; } })
            }
          }
          SectionHeader({ title: '模型', caption: '每行一个模型 ID，或用逗号分隔。' })
          Column({ space: Space.md }) {
            TextArea({ text: this.editor.models, placeholder: 'deepseek-chat\ndeepseek-reasoner' }).id('provider-models')
              .attributeModifier(Styles.area).constraintSize({ minHeight: 96, maxHeight: 200 }).maxLength(10000)
              .onChange((value: string) => { this.editor.models = value; })
            Column() {
              this.label('上下文窗口（Token）')
              TextInput({ text: this.editor.contextWindow }).id('context-window').attributeModifier(Styles.input)
                .type(InputType.Number).maxLength(7).onChange((value: string) => { this.editor.contextWindow = value; })
              Text('使用此服务的模型共享该窗口预算，预留 4096 用于输出。').fontSize(Font.caption).lineHeight(18)
                .fontColor($r('app.color.text_tertiary')).width('100%').margin({ top: 6 })
            }
          }.padding(Space.lg).borderRadius(Radius.lg).backgroundColor($r('app.color.surface'))
          Column() {
            GroupCard() {
              SwitchRow({ title: '启用此服务', compId: 'provider-enabled', isOn: this.editor.enabled,
                onChange: (value: boolean) => { this.editor.enabled = value; } })
            }
          }.margin({ top: Space.lg })
          if (this.editor.id.length > 0) {
            Button('删除此服务').id('delete-provider-' + this.editor.id).attributeModifier(Btn.danger).width('100%')
              .margin({ top: Space.xl }).enabled(!this.app.busy).onClick(() => this.confirmDelete())
          }
        }.padding({ left: Space.page, right: Space.page, bottom: Space.xl }).width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top)
      BottomBar() {
        Column({ space: Space.sm }) {
          if (this.editor.error.length > 0) {
            Banner({ text: this.editor.error, compId: 'provider-error' })
          }
          Button(this.app.busy ? '正在保存…' : '保存').id('save-provider').attributeModifier(Btn.primary).width('100%')
            .enabled(!this.app.busy).onClick(async () => { if (await this.app.saveProvider()) { this.onSaved(); } })
        }
      }
    }.width('100%').height('100%')
  }
}
