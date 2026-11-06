import { AppearanceStyle } from '../common/AppearanceStyle';
import { menuMaterialAttribute, systemMaterialAttribute } from '../common/MaterialAttributes';
import { Btn, Styles } from '../common/Theme';
import { BALANCE_AUTH, BALANCE_MODES } from '../model/BalanceSettings';
import { t } from '../model/I18n';
import { ProviderEditorViewModel } from '../viewmodel/ProviderEditorViewModel';

@Component
export struct BalanceQuerySettings {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink editor: ProviderEditorViewModel;
  @Prop disabled: boolean = false;
  @State private moreFields: boolean = false;

  private labels(): string[] {
    return [t('自动（DeepSeek）'), t('关闭余额查询'), 'Sub2API', t('New API · Key 额度'), t('New API · 账户余额'), t('智谱余额（实验性）'), t('自定义查询')];
  }
  private authLabels(): string[] { return ['Bearer API Key', 'x-api-key', 'Authorization: API Key', t('不发送密钥')]; }

  @Builder
  field(label: string, value: string, placeholder: string, id: string, onChange: (value: string) => void) {
    Column({ space: 4 }) {
      Text(label).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      TextInput({ text: value, placeholder: placeholder }).fontFamily(this.appearance.fontFamily).attributeModifier(Styles.input)
        .id(id).maxLength(512).enabled(!this.disabled).onChange(onChange)
    }.width('100%')
  }

  build() {
    Column({ space: 10 }) {
      Select(this.labels().map((label: string): SelectOption => ({ value: label })))
        .selected(BALANCE_MODES.indexOf(this.editor.balanceMode)).value(this.labels()[BALANCE_MODES.indexOf(this.editor.balanceMode)])
        .id('balance-query-mode').enabled(!this.disabled).fontColor($r('sys.color.font_primary'))
        .backgroundColor(this.appearance.controlBackground)
        .attributeModifier(systemMaterialAttribute<SelectAttribute>(this.appearance.control))
        .attributeModifier(menuMaterialAttribute(this.appearance.menu))
        .onSelect((index: number) => { this.editor.balanceMode = BALANCE_MODES[index]; })
      if (['sub2api', 'newapi', 'newapi-account'].includes(this.editor.balanceMode)) {
        Text(t('服务地址填写站点地址或以 /v1 结尾的接口地址；子路径部署请保留站点前缀。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (this.editor.balanceMode === 'newapi-account') {
        Text(t('填写站点个人设置中的访问令牌和用户 ID，用于查询账户余额。模型调用仍使用原来的 API Key。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        this.field(t('New API 用户 ID'), this.editor.balanceUserId, '123', 'balance-user-id',
          (value: string) => { this.editor.balanceUserId = value; })
      }
      if (this.editor.balanceMode !== 'off' && !(this.editor.balanceMode === 'custom' && this.editor.balanceAuth === 'none')) {
        if (this.editor.balanceMode !== 'newapi-account') {
          Select([{ value: t('使用模型 API Key') }, { value: t('使用查询专用凭据') }])
            .selected(this.editor.balanceCredential === 'separate' ? 1 : 0)
            .value(this.editor.balanceCredential === 'separate' ? t('使用查询专用凭据') : t('使用模型 API Key'))
            .id('balance-credential-source').enabled(!this.disabled).fontColor($r('sys.color.font_primary'))
            .backgroundColor(this.appearance.controlBackground)
            .attributeModifier(systemMaterialAttribute<SelectAttribute>(this.appearance.control))
            .attributeModifier(menuMaterialAttribute(this.appearance.menu))
            .onSelect((index: number) => { this.editor.balanceCredential = index === 1 ? 'separate' : 'provider'; })
        }
        if (this.editor.balanceCredential === 'separate' || this.editor.balanceMode === 'newapi-account') {
          TextInput({ text: this.editor.balanceApiKey, placeholder: this.editor.canKeepBalanceKey ?
            t('已保存查询凭据，留空保持不变') : t('余额查询专用凭据') })
            .type(InputType.Password).fontFamily(this.appearance.fontFamily).attributeModifier(Styles.input)
            .id('balance-api-key').copyOption(CopyOptions.None).maxLength(512).enabled(!this.disabled)
            .onChange((value: string) => { this.editor.balanceApiKey = value; })
        }
      }
      if (this.editor.balanceMode === 'zhipu') {
        Text(t('仅支持智谱国内按量服务。此余额接口没有公开文档，可能变更；Coding Plan 额度不在此处查询。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      }
      if (this.editor.balanceMode === 'custom') {
        Text(t('向当前服务域名发送 GET 请求，按字段路径读取 JSON。金额除以换算除数后显示；不会执行脚本。'))
          .fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        this.field(t('查询路径（从域名根目录开始）'), this.editor.balancePath, '/user/balance', 'balance-path',
          (value: string) => { this.editor.balancePath = value; })
        this.field(t('剩余金额字段'), this.editor.balanceRemaining, 'data.balance', 'balance-remaining-field',
          (value: string) => { this.editor.balanceRemaining = value; })
        this.field(t('余额单位'), this.editor.balanceUnit, 'USD / CNY', 'balance-unit',
          (value: string) => { this.editor.balanceUnit = value; })
        this.field(t('换算除数'), this.editor.balanceDivisor, '1', 'balance-divisor',
          (value: string) => { this.editor.balanceDivisor = value; })
        Text(t('认证方式')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
        Select(this.authLabels().map((label: string): SelectOption => ({ value: label })))
          .selected(BALANCE_AUTH.indexOf(this.editor.balanceAuth)).value(this.authLabels()[BALANCE_AUTH.indexOf(this.editor.balanceAuth)])
          .id('balance-query-auth').enabled(!this.disabled).fontColor($r('sys.color.font_primary'))
          .backgroundColor(this.appearance.controlBackground)
          .attributeModifier(systemMaterialAttribute<SelectAttribute>(this.appearance.control))
          .attributeModifier(menuMaterialAttribute(this.appearance.menu))
          .onSelect((index: number) => { this.editor.balanceAuth = BALANCE_AUTH[index]; })
        Button(t('更多响应字段')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.text).id('balance-more-fields')
          .onClick(() => { this.moreFields = !this.moreFields; })
        if (this.moreFields || this.editor.balanceTotal || this.editor.balanceUsed || this.editor.balanceSuccess) {
          this.field(t('总额度字段（可选）'), this.editor.balanceTotal, 'data.total', 'balance-total-field',
            (value: string) => { this.editor.balanceTotal = value; })
          this.field(t('已用额度字段（可选）'), this.editor.balanceUsed, 'data.used', 'balance-used-field',
            (value: string) => { this.editor.balanceUsed = value; })
          this.field(t('成功标记字段（可选，必须为 true）'), this.editor.balanceSuccess, 'success', 'balance-success-field',
            (value: string) => { this.editor.balanceSuccess = value; })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
