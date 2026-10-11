import { t } from '../model/I18n';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { SearchConfig, SearchProviderId, defaultSearchConfig, reusableSearchProfiles } from '../model/WebSearch';
import { ProviderProfile } from '../model/ProviderProfiles';
import { Btn, Space } from '../common/Theme';
import { Banner, SwitchRow } from '../common/Widgets';

@Component
export struct SearchSettingsPanel {
  @ObjectLink app: ChatViewModel;
  @State private searchEnabled: boolean = false;
  @State private provider: SearchProviderId = 'deepseek';
  @State private sourceId: string = 'auto';
  @State private baseUrl: string = '';
  @State private model: string = '';
  @State private apiKey: string = '';
  @State private savedKey: boolean = false;
  @State private saving: boolean = false;
  @State private error: string = '';
  aboutToAppear(): void {
    const config = this.app.productivity.options?.search || defaultSearchConfig();
    this.searchEnabled = config.enabled; this.baseUrl = config.baseUrl; this.model = config.model; this.savedKey = !!config.credentialAlias;
    this.provider = config.provider; this.sourceId = config.modelProviderId || (config.credentialAlias || config.provider === 'tavily' ? 'custom' : 'auto');
  }
  private candidates(): ProviderProfile[] {
    const config: SearchConfig = { provider: this.provider, baseUrl: this.baseUrl, enabled: false, model: this.model, credentialAlias: '' };
    return reusableSearchProfiles(config, this.app.providerProfiles);
  }
  private sourceIds(): string[] { return ['auto'].concat(this.candidates().map((item) => item.id), ['custom']); }
  private sourceLabels(): string[] { return [t('自动复用已配置的模型密钥')].concat(this.candidates().map((item) => item.name), [t('独立搜索密钥')]); }
  private changeProvider(index: number): void {
    this.provider = index === 0 ? 'deepseek' : 'tavily';
    const saved = this.app.productivity.options?.search;
    const config = saved?.provider === this.provider ? saved : defaultSearchConfig(this.provider);
    this.baseUrl = config.baseUrl; this.model = config.model; this.apiKey = ''; this.savedKey = !!config.credentialAlias;
    this.sourceId = config.modelProviderId || (config.credentialAlias || this.provider === 'tavily' ? 'custom' : 'auto');
  }
  private async save(): Promise<void> {
    if (this.app.busy || this.saving) { return; }
    this.saving = true; this.error = '';
    try {
      const ok = await this.app.saveSearch({ provider: this.provider, enabled: this.searchEnabled, baseUrl: this.baseUrl,
        model: this.model, apiKey: this.apiKey, credentialSource: this.sourceId });
      this.error = this.app.error;
      if (ok) { this.apiKey = ''; this.aboutToAppear(); this.getUIContext().getPromptAction().showToast({ message: t('搜索设置已保存') }); }
    } finally { this.saving = false; }
  }
  build() {
    Scroll() {
      Column({ space: Space.md }) {
        Text(t('搜索服务')).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Select([{ value: 'DeepSeek' }, { value: 'Tavily' }]).selected(this.provider === 'deepseek' ? 0 : 1)
          .value(this.provider === 'deepseek' ? 'DeepSeek' : 'Tavily').enabled(!this.saving).id('search-provider')
          .onSelect((index: number) => this.changeProvider(index))
        Text(t('搜索词会发送给所选服务；结果统一返回来源链接和摘录。DeepSeek 需要支持原生搜索的接口与模型。'))
          .fontSize(14).fontColor($r('app.color.text_secondary'))
        SwitchRow({ title: t('启用联网搜索'), isOn: this.searchEnabled, disabled: this.saving || this.app.busy,
          onChange: (value: boolean) => { this.searchEnabled = value; } })
        Text(t('搜索接口基础地址')).fontColor($r('app.color.text_secondary'))
        TextInput({ text: this.baseUrl, placeholder: 'https://api.deepseek.com/anthropic/v1' }).id('search-base-url')
          .enabled(!this.saving).onChange((value: string) => { this.baseUrl = value; })
        if (this.provider === 'deepseek') {
          Text(t('模型')).fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.model, placeholder: 'deepseek-v4-flash' }).id('search-model')
            .enabled(!this.saving).onChange((value: string) => { this.model = value; })
          Text(t('密钥来源')).fontColor($r('app.color.text_secondary'))
          Select(this.sourceLabels().map((label: string): SelectOption => ({ value: label })))
            .selected(Math.max(0, this.sourceIds().indexOf(this.sourceId)))
            .value(this.sourceLabels()[Math.max(0, this.sourceIds().indexOf(this.sourceId))]).enabled(!this.saving)
            .id('search-credential-source').onSelect((index: number) => { this.sourceId = this.sourceIds()[index]; this.apiKey = ''; })
          if (this.sourceId === 'auto') {
            Text(this.candidates().length === 1 ? t('将复用 {0} 的密钥，无需重复填写。', [this.candidates()[0].name]) :
              this.candidates().length > 1 ? t('有多个匹配服务，请选择要复用的密钥。') : t('没有地址匹配的模型服务，可选择独立搜索密钥。'))
              .fontSize(13).fontColor($r('app.color.text_secondary'))
          }
        }
        if (this.sourceId === 'custom') {
          Text('API Key').fontColor($r('app.color.text_secondary'))
          TextInput({ text: this.apiKey, placeholder: this.savedKey ? t('留空保留已保存的搜索密钥') : 'API Key' }).type(InputType.Password)
            .id('search-api-key').enabled(!this.saving).onChange((value: string) => { this.apiKey = value; })
        }
        Text(t('密钥保存在系统安全存储，不随备份导出。关闭“允许联网”也会停用搜索。'))
          .fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.error) { Banner({ text: this.error, danger: true }) }
        Button(t('保存')).attributeModifier(Btn.primary).enabled(!this.saving && !this.app.busy && !this.app.saveError)
          .id('save-search-settings').onClick(() => this.save())
      }.width('100%').padding(Space.page).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
