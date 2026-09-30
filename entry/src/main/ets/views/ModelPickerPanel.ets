import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { ModelChoice } from '../model/ProviderProfiles';

@Component
export struct ModelPickerPanel {
  @ObjectLink app: ChatViewModel;
  onSelected: () => void = () => {};
  onSettings: () => void = () => {};
  @State private query: string = '';

  private choices(): ModelChoice[] {
    const needle = this.query.trim().toLocaleLowerCase();
    return this.app.modelChoices.filter((choice: ModelChoice) => (choice.providerName + ' ' + choice.modelId).toLocaleLowerCase().includes(needle));
  }

  build() {
    Column({ space: 12 }) {
      Search({ value: this.query, placeholder: '搜索服务或模型' }).id('model-search').onChange((value: string) => { this.query = value; })
      Text('选择只影响当前对话；设为默认同时用于之后新建的对话。').fontSize(12).lineHeight(19)
        .fontColor($r('app.color.text_secondary')).width('100%')
      if (this.app.modelChoices.length === 0) {
        Text('尚无已启用的模型服务。').fontColor($r('app.color.text_secondary'))
        Button('添加模型服务').id('picker-add-provider').onClick(this.onSettings)
      }
      List({ space: 12 }) {
        ForEach(this.choices(), (choice: ModelChoice) => {
          ListItem() {
            Column({ space: 8 }) {
              Text(choice.providerName).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Text(choice.modelId).fontSize(17).fontWeight(FontWeight.Medium).width('100%').fontColor($r('app.color.text_primary'))
              if (this.app.active.modelRef?.providerId === choice.providerId && this.app.active.modelRef?.modelId === choice.modelId) {
                Text('当前对话使用').fontSize(12).width('100%').fontColor($r('app.color.accent'))
              }
              if (this.app.config.configured && this.app.config.providerId === choice.providerId && this.app.config.model === choice.modelId) {
                Text('新对话默认').fontSize(12).width('100%').fontColor($r('app.color.text_secondary'))
              }
              Row({ space: 12 }) {
                Button('选择').id('choose-model-' + choice.providerId + '-' + choice.modelId).fontSize(13).height(34).enabled(!this.app.busy)
                  .onClick(async () => { if (await this.app.selectModel(choice.providerId, choice.modelId)) { this.onSelected(); } })
                Button('设为默认').id('default-model-' + choice.providerId + '-' + choice.modelId).fontSize(13).height(34)
                  .backgroundColor(Color.Transparent).fontColor($r('app.color.accent')).enabled(!this.app.busy)
                  .onClick(async () => { if (await this.app.selectModel(choice.providerId, choice.modelId, true)) { this.onSelected(); } })
              }.width('100%')
            }.padding(16).borderRadius(16).width('100%').backgroundColor($r('app.color.surface'))
          }
        }, (choice: ModelChoice) => choice.providerId + '/' + choice.modelId)
      }.layoutWeight(1).width('100%')
      if (this.app.error.length > 0) { Text(this.app.error).id('model-picker-error').fontColor($r('app.color.danger')) }
    }.padding(20).width('100%').height('100%')
  }
}
