import { common } from '@kit.AbilityKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';
import { t } from '../model/I18n';

// Inline onboarding fields share the normal provider editor and secure save path.
@Component
export struct OnboardingProviderForm {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink editor: ProviderEditorViewModel;
  @Prop locked: boolean = false;
  @Prop attempted: boolean = false;
  onKeyFocus: (focused: boolean) => void = () => {};
  onError: (message: string) => void = () => {};

  aboutToDisappear(): void { this.onKeyFocus(false); }

  private async openKeyPage(): Promise<void> {
    if (this.locked || !this.editor.apiKeyUrl) { return; }
    try {
      await (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .startAbility({ action: 'ohos.want.action.viewData', uri: this.editor.apiKeyUrl });
    } catch (error) { this.onError(t('无法打开系统浏览器。') + ' ' + (error as Error).message); }
  }

  @Builder
  fieldError(field: string) {
    if (this.attempted && this.editor.fieldError(field)) {
      Text(this.editor.fieldError(field)).fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18)
        .fontColor($r('app.color.danger')).width('100%')
    }
  }

  build() {
    Column({ space: 10 }) {
      Column({ space: 6 }) {
        Text(t('服务地址')).fontFamily(this.appearance.fontFamily).fontSize(12)
          .fontColor($r('app.color.text_secondary')).width('100%')
        TextInput({ text: this.editor.baseUrl,
          placeholder: this.editor.noApiKey ? 'http://192.168.1.100:11434/v1' : 'https://api.example.com/v1' })
          .id('onboarding-inline-url').fontFamily(this.appearance.fontFamily).fontSize(14).height(44)
          .type(InputType.URL).maxLength(1024).borderRadius(12)
          .backgroundColor($r('app.color.surface_variant')).fontColor($r('app.color.text_primary'))
          .onChange((value: string) => { this.editor.baseUrl = value; this.onError(''); })
        this.fieldError('url')
      }.width('100%')
      if (this.editor.noApiKey) {
        Text(t('此服务无需 API Key。')).fontFamily(this.appearance.fontFamily).fontSize(12)
          .fontColor($r('app.color.text_secondary')).width('100%')
        TextInput({ text: this.editor.models, placeholder: t('填写已安装的模型名称') })
          .id('onboarding-inline-models').fontFamily(this.appearance.fontFamily).fontSize(14).height(44)
          .maxLength(200).borderRadius(12).backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary')).accessibilityText(t('模型 ID'))
          .onChange((value: string) => { this.editor.models = value; this.onError(''); })
        this.fieldError('models')
      } else {
        Column({ space: 6 }) {
          Text('API Key').fontFamily(this.appearance.fontFamily).fontSize(12)
            .fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.editor.apiKey,
            placeholder: this.editor.canKeepKey ? t('留空保留原密钥') : t('填写 API Key') })
            .id('onboarding-inline-key').fontFamily(this.appearance.fontFamily).fontSize(14).height(44)
            .type(InputType.Password).showPasswordIcon(true).copyOption(CopyOptions.None).maxLength(512)
            .borderRadius(12).backgroundColor($r('app.color.surface_variant'))
            .fontColor($r('app.color.text_primary')).accessibilityText('API Key')
            .onFocus(() => this.onKeyFocus(true)).onBlur(() => this.onKeyFocus(false))
            .onEditChange((editing: boolean) => this.onKeyFocus(editing))
            .onChange((value: string) => { this.editor.apiKey = value; this.onError(''); })
          this.fieldError('key')
        }.width('100%')
        if (this.editor.apiKeyUrl) {
          Button(t('获取 API Key'), { type: ButtonType.Capsule, stateEffect: true })
            .id('onboarding-get-key').height(44).padding({ left: 8, right: 8 }).backgroundColor(Color.Transparent)
            .fontFamily(this.appearance.fontFamily).fontSize(13).fontColor(this.appearance.accent)
            .accessibilityText(t('获取 API Key，在浏览器中打开')).onClick(() => this.openKeyPage())
        }
        Text(t('可用模型：{0}', [this.editor.modelList.join('、')]))
          .fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18)
          .fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (this.editor.baseUrl.startsWith('http://')) {
        Text(t('HTTP 连接未加密，仅适用于可信网络中的本地模型。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).lineHeight(18)
          .fontColor($r('app.color.warning')).width('100%')
      }
    }.id('onboarding-provider-form').width('100%').padding(14)
      .backgroundColor($r('app.color.surface')).borderRadius(18)
      .border({ width: 1, color: this.appearance.accentOutline }).enabled(!this.locked)
  }
}
