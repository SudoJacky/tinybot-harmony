import { ChatViewModel, SettingsViewModel } from '../viewmodel/ChatViewModel';
import { ProviderInfo } from '../model/Provider';
import { ProviderProfile } from '../model/ProviderProfiles';

@Component
export struct SettingsPanel {
  @ObjectLink app: ChatViewModel;
  @ObjectLink settings: SettingsViewModel;
  onEditProvider: (id: string, preset: string) => void = () => {};

  @Builder
  profileCard(profile: ProviderProfile) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(profile.name).fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor($r('app.color.text_primary'))
        Text(profile.enabled ? '已启用' : '已停用').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.width('100%')
      Text(`${profile.protocol} · ${profile.models.length} 个模型`).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      Text(profile.baseUrl).fontSize(12).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor($r('app.color.text_secondary')).width('100%')
      Row({ space: 12 }) {
        Button('编辑').id('edit-provider-' + profile.id).fontSize(13).height(34).enabled(!this.app.busy)
          .onClick(() => this.onEditProvider(profile.id, ''))
        Button('删除').id('delete-provider-' + profile.id).fontSize(13).height(34)
          .backgroundColor(Color.Transparent).fontColor($r('app.color.danger')).enabled(!this.app.busy)
          .onClick(() => {
            this.getUIContext().showAlertDialog({ title: '删除模型服务？',
              message: '删除这份服务配置及其密钥，保留完整对话。使用它的会话需要重新选择模型。',
              primaryButton: { value: '取消', action: () => {} },
              secondaryButton: { value: '删除', action: () => { this.app.deleteProvider(profile.id); } } });
          })
      }.width('100%')
    }.padding(16).borderRadius(16).width('100%').backgroundColor($r('app.color.surface'))
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 8 }) {
          Text('模型服务').fontSize(24).fontWeight(FontWeight.Bold).layoutWeight(1).fontColor($r('app.color.text_primary'))
          Button('＋ 添加').id('add-provider').fontSize(14).height(40).enabled(!this.app.busy).onClick(() => this.onEditProvider('', ''))
        }.width('100%')
        Text('添加多个服务，在每段对话中选择服务与模型。密钥分别保存在系统安全存储中。')
          .fontSize(13).lineHeight(21).fontColor($r('app.color.text_secondary')).width('100%')
        ForEach(this.app.providerProfiles, (profile: ProviderProfile) => { this.profileCard(profile) },
          (profile: ProviderProfile) => JSON.stringify(profile))
        if (this.app.providerProfiles.length === 0) {
          Text('尚未添加服务，选择下方预设或点击添加。').fontSize(14).fontColor($r('app.color.text_secondary'))
        }
        Text('内置服务').fontSize(18).fontWeight(FontWeight.Medium).width('100%').fontColor($r('app.color.text_primary'))
        Grid() {
          ForEach(this.app.providerPresets, (preset: ProviderInfo) => {
            GridItem() {
              Button({ type: ButtonType.Normal }) {
                Column({ space: 6 }) {
                  Text(preset.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                  Text(preset.protocol).fontSize(10).fontColor($r('app.color.text_secondary'))
                }.padding(12).width('100%')
              }.id('preset-' + preset.id).width('100%').height(86).borderRadius(14)
                .backgroundColor($r('app.color.surface')).enabled(!this.app.busy).onClick(() => this.onEditProvider('', preset.id))
            }
          }, (preset: ProviderInfo) => preset.id)
        }.columnsTemplate('1fr 1fr').columnsGap(12).rowsGap(12).height(Math.ceil(this.app.providerPresets.length / 2) * 98).width('100%')
        Text('助手设置').fontSize(18).fontWeight(FontWeight.Medium).width('100%').fontColor($r('app.color.text_primary'))
        TextArea({ text: this.settings.systemPrompt, placeholder: '希望 Tinybot 如何回答？' }).id('system-prompt')
          .height(132).fontSize(14).maxLength(4000).backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary')).onChange((value: string) => { this.settings.systemPrompt = value; })
        Row({ space: 16 }) {
          Text('接近预算时自动压缩历史').fontSize(14).layoutWeight(1).fontColor($r('app.color.text_primary'))
          Toggle({ type: ToggleType.Switch, isOn: this.settings.autoCompact }).id('auto-compact')
            .selectedColor($r('app.color.accent')).onChange((value: boolean) => { this.settings.autoCompact = value; })
        }.width('100%')
        Text('压缩使用当前会话的模型，完整记录保留。').fontSize(12).width('100%').fontColor($r('app.color.text_secondary'))
        if (this.settings.error.length > 0) { Text(this.settings.error).id('settings-error').fontColor($r('app.color.danger')).width('100%') }
        if (this.app.error.length > 0) { Text(this.app.error).id('provider-list-error').fontColor($r('app.color.danger')).width('100%') }
        Button('保存助手设置').id('save-settings').width('100%').height(48).enabled(!this.app.busy).onClick(() => { this.app.saveSettings(); })
      }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
    }.height('100%').width('100%').scrollBar(BarState.Auto)
  }
}
