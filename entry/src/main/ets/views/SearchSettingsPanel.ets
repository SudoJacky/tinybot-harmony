import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SearchProviderId, defaultSearchConfig, deepSeekSearchProfiles } from '../model/WebSearch';
import { ProviderProfile } from '../model/ProviderProfiles';
import { Btn, Space } from '../common/Theme';
import { Banner, SwitchRow } from '../common/Widgets';

@Component
export struct SearchSettingsPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  @State private searchEnabled: boolean = false;
  @State private provider: SearchProviderId = 'deepseek';
  @State private sourceId: string = '';
  @State private baseUrl: string = '';
  @State private apiKey: string = '';
  @State private savedKey: boolean = false;
  @State private saving: boolean = false;
  @State private error: string = '';
  aboutToAppear(): void {
    const config = this.app.productivity.options?.search || defaultSearchConfig();
    this.searchEnabled = config.enabled; this.baseUrl = config.provider === 'tavily' ? config.baseUrl! : ''; this.savedKey = !!config.credentialAlias;
    this.provider = config.provider; this.sourceId = this.candidates().some((item) => item.id === config.modelProviderId) ? config.modelProviderId! : '';
  }
  private candidates(): ProviderProfile[] {
    return deepSeekSearchProfiles(this.app.providerProfiles);
  }
  private changeProvider(index: number): void {
    this.provider = index === 0 ? 'deepseek' : 'tavily';
    const saved = this.app.productivity.options?.search;
    const config = saved?.provider === this.provider ? saved : defaultSearchConfig(this.provider);
    this.baseUrl = config.provider === 'tavily' ? config.baseUrl! : ''; this.apiKey = ''; this.savedKey = !!config.credentialAlias; this.error = '';
    this.sourceId = this.candidates().some((item) => item.id === config.modelProviderId) ? config.modelProviderId! : '';
  }
  private async save(): Promise<void> {
    if (this.app.busy || this.saving) { return; }
    this.saving = true; this.error = '';
    try {
      const ok = await this.app.saveSearch({ provider: this.provider, enabled: this.searchEnabled, baseUrl: this.baseUrl,
        apiKey: this.apiKey, modelProviderId: this.provider === 'deepseek' && this.sourceId ? this.sourceId : undefined });
      this.error = this.app.error;
      if (ok) { this.apiKey = ''; this.aboutToAppear(); this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('搜索设置已保存') }); }
    } finally { this.saving = false; }
  }
  build() {
    Scroll() {
      Column({ space: Space.md }) {
        Text(t('搜索服务')).fontFamily(this.appearance.fontFamily).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Select([{ value: 'DeepSeek' }, { value: 'Tavily' }]).selected(this.provider === 'deepseek' ? 0 : 1)
          .value(this.provider === 'deepseek' ? 'DeepSeek' : 'Tavily').enabled(!this.saving).id('search-provider')
          .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_primary'))
          .systemMaterial(this.appearance.control).menuSystemMaterial(this.appearance.surface)
          .onSelect((index: number) => this.changeProvider(index))
        Text(t('搜索词会发送给所选服务，结果返回来源链接和摘录。')).fontFamily(this.appearance.fontFamily)
          .fontSize(14).fontColor($r('app.color.text_secondary'))
        SwitchRow({ title: t('启用联网搜索'), isOn: this.searchEnabled, disabled: this.saving || this.app.busy,
          onChange: (value: boolean) => { this.searchEnabled = value; } })
        if (this.provider === 'deepseek') {
          Text(t('使用 DeepSeek 官方搜索，自动复用已配置的 DeepSeek 服务密钥。搜索会产生额外的模型用量。')).fontFamily(this.appearance.fontFamily)
            .fontSize(14).fontColor($r('app.color.text_secondary'))
          if (this.candidates().length > 1) {
            Text(t('DeepSeek 服务')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
            Select(this.candidates().map((item: ProviderProfile): SelectOption => ({ value: item.name })))
              .selected(this.candidates().findIndex((item) => item.id === this.sourceId))
              .value(this.candidates().find((item) => item.id === this.sourceId)?.name || t('请选择用于联网搜索的 DeepSeek 服务。'))
              .enabled(!this.saving).id('search-credential-source')
              .backgroundColor(Color.Transparent).fontColor($r('sys.color.font_primary'))
              .systemMaterial(this.appearance.control).menuSystemMaterial(this.appearance.surface)
              .onSelect((index: number) => { this.sourceId = this.candidates()[index].id; })
          } else if (this.candidates().length === 1) {
            Text(t('将复用 {0} 的密钥，无需重复填写。', [this.candidates()[0].name])).fontFamily(this.appearance.fontFamily)
              .id('search-provider-key-ready').fontSize(13).fontColor($r('app.color.text_secondary'))
          } else {
            Text(t('请先在设置中添加并启用 DeepSeek 官方模型服务，配置 API Key。')).fontFamily(this.appearance.fontFamily)
              .id('search-provider-key-missing').fontSize(13).fontColor($r('app.color.text_secondary'))
          }
        } else {
          Text(t('搜索接口基础地址')).fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.baseUrl, placeholder: 'https://api.tavily.com' }).fontFamily(this.appearance.fontFamily).id('search-base-url')
            .enabled(!this.saving).onChange((value: string) => { this.baseUrl = value; })
          Text('API Key').fontFamily(this.appearance.fontFamily).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.apiKey, placeholder: this.savedKey ? t('留空保留已保存的搜索密钥') : 'API Key' }).fontFamily(this.appearance.fontFamily).type(InputType.Password)
            .id('search-api-key').enabled(!this.saving).onChange((value: string) => { this.apiKey = value; })
        }
        Text(t('密钥保存在系统安全存储，不随备份导出。关闭“允许网页读取与搜索”也会停用搜索。')).fontFamily(this.appearance.fontFamily)
          .fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.error) { Banner({ text: this.error, danger: true }) }
        Button(t('保存')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.primary).enabled(!this.saving && !this.app.busy && !this.app.saveError)
          .id('save-search-settings').onClick(() => this.save())
      }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor($r('app.color.page_background'))
  }
}
